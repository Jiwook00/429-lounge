-- 릴리스 전후·리텐션 비교용 기록 (ADR-0020)
--  - players.app_version: 마지막으로 접속한 앱 버전
--  - player_daily_seen: 회원 × 날짜(KST) 1행. touch_seen이 올린다

alter table public.players add column app_version text;

create table public.player_daily_seen (
  player_id     uuid not null references public.players (id) on delete cascade,
  day           date not null,                       -- KST 날짜
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  app_version   text,                                -- 그날 마지막으로 본 앱 버전
  seen_count    integer not null default 1,          -- touch_seen 성공 횟수 (앱 켜짐 시간의 대용치, 약 2분 단위)
  primary key (player_id, day)
);

-- 쓰기는 touch_seen(security definer)만. 읽기 정책도 없어서 클라이언트는 못 본다
alter table public.player_daily_seen enable row level security;

-- 인자 추가: 시그니처가 바뀌므로 지우고 다시 만든다. 인자 없는 호출(옛 앱)은 기본값 null로 그대로 동작
drop function public.touch_seen();

create function public.touch_seen(p_app_version text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v text := nullif(left(btrim(p_app_version), 32), '');
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  -- 마지막으로 본 시각은 1분 안의 중복을 쓰지 않는다. 버전이 바뀌었으면 바로 쓴다
  update players
  set last_seen_at = now(), app_version = coalesce(v, app_version)
  where id = auth.uid()
    and (last_seen_at is null or last_seen_at < now() - interval '1 minute'
         or (v is not null and app_version is distinct from v));

  insert into player_daily_seen (player_id, day, app_version)
  values (auth.uid(), (now() at time zone 'Asia/Seoul')::date, v)
  on conflict (player_id, day) do update
  set last_seen_at = now(),
      app_version  = coalesce(excluded.app_version, player_daily_seen.app_version),
      seen_count   = player_daily_seen.seen_count + 1;
end $$;

revoke execute on function public.touch_seen(text) from public, anon;
grant  execute on function public.touch_seen(text) to authenticated;
