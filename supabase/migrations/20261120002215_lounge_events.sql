-- 429 Lounge: 라운지 전광판 이벤트 (DESIGN.md §9 전광판, ADR-0008)
--
-- 전광판은 평소엔 숨어 있다가 특별한 일이 생기면 몇 분 동안 나타난다.
-- 이벤트는 정산하는 쪽(서버)에서만 기록한다. 클라이언트가 "잭팟 터졌다"고 보내는 방식은 조작될 수 있어서.
--   jackpot  슬롯 429 ×3
--   bigwin   슬롯 ×10 이상이면서 지급 500칩 이상 / 홀짝 지급 1,000칩 이상
--            (1칩 걸고 ×10 같은 작은 판은 전광판에 올리지 않는다)
-- 기존 게임 함수는 건드리지 않고 트리거로 붙인다.

create table public.lounge_events (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('jackpot', 'bigwin')),
  game       text not null check (game in ('slot', 'oddeven')),
  player_id  uuid not null references public.players (id) on delete cascade,
  name       text not null, -- 그 순간의 닉네임 (나중에 이름을 바꿔도 전광판 기록은 그대로)
  amount     bigint not null,
  created_at timestamptz not null default now()
);
create index lounge_events_recent_idx on public.lounge_events (created_at desc);

alter table public.lounge_events enable row level security;
create policy "read events" on public.lounge_events for select to authenticated using (true);

-- 슬롯: 잭팟은 항상, 빅 윈은 ×10 이상 + 500칩 이상
create function public.slot_spin_event()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.multiplier >= 429 or (new.multiplier >= 10 and new.payout >= 500) then
    insert into lounge_events (kind, game, player_id, name, amount)
    select case when new.multiplier >= 429 then 'jackpot' else 'bigwin' end, 'slot', p.id, p.name, new.payout
    from players p where p.id = new.player_id;
  end if;
  return new;
end $$;

create trigger slot_spin_event after insert on public.slot_spins
for each row execute function public.slot_spin_event();

-- 홀짝: 정산 때 지급액이 채워지는 순간 1,000칩 이상이면
create function public.oddeven_bet_event()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.payout >= 1000 and old.payout is null then
    insert into lounge_events (kind, game, player_id, name, amount)
    select 'bigwin', 'oddeven', p.id, p.name, new.payout
    from players p where p.id = new.player_id;
  end if;
  return new;
end $$;

create trigger oddeven_bet_event after update of payout on public.oddeven_bets
for each row execute function public.oddeven_bet_event();

revoke execute on function public.slot_spin_event()   from public, anon, authenticated;
revoke execute on function public.oddeven_bet_event() from public, anon, authenticated;

alter publication supabase_realtime add table public.lounge_events;
