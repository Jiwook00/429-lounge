-- 회원 명부: 라운지에 접속 중이 아닌 회원도 "오프라인 · 3시간 전"으로 보여주기 (ADR-0011)
--  - 마지막으로 본 시각은 앱이 켜져 있는 동안 touch_seen()으로 갱신한다 (몇 분 간격)
--  - 이 기능이 없는 옛 앱은 갱신하지 않는다 → 토큰 환전 기록으로 채워 두고, 옛 앱도 칩을 받으면 갱신

alter table public.players add column last_seen_at timestamptz;

update public.players p
set last_seen_at = greatest(
  p.created_at,
  (select max(c.updated_at) from public.token_claims c where c.player_id = p.id)
);

-- 옛 앱(touch_seen 없음)도 토큰 환전할 때 같이 갱신되게
create function public.players_touch_on_claim()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update players set last_seen_at = now()
  where id = new.player_id and (last_seen_at is null or last_seen_at < now() - interval '1 minute');
  return new;
end $$;

create trigger token_claims_touch_seen
after insert or update on public.token_claims
for each row execute function public.players_touch_on_claim();

revoke execute on function public.players_touch_on_claim() from public, anon, authenticated;

-- 앱이 켜져 있다고 알린다. 1분 안에 다시 부르면 쓰지 않는다
create function public.touch_seen()
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update players set last_seen_at = now()
  where id = auth.uid() and (last_seen_at is null or last_seen_at < now() - interval '1 minute');
end $$;

revoke execute on function public.touch_seen() from public, anon;
grant  execute on function public.touch_seen() to authenticated;
