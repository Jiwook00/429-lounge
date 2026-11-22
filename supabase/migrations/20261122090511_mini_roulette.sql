-- 미니 룰렛: 0~12, 13칸 (ADR-0015, docs/chip-economy.md)
--
-- 룰: 빨강 1 4 5 8 9 12, 나머지 1~12는 검정, 0은 초록.
--     숫자 하나 ×12, 빨강·검정 / 홀·짝 / 1–6·7–12 ×2 (지급액은 건 칩 포함).
--     0이 나오면 무효 판: 건 칩을 모두 돌려준다. 그래서 환수율은 모든 베팅이 100% (하우스 몫 없음).
--     황금 칩(공짜 100)은 ×2 칸에만. 이기면 200, 지면 0, 0이면 황금 칩을 돌려준다(아직 유효할 때).
--     판당 금액 상한은 없다. 실제 플레이를 보고 조정한다.
-- 진행: 첫 베팅이 12초 베팅 창을 연다(혼자면 roulette_spin으로 바로) → 마감 → 회전 6초 → 결과 4초.
--       칸을 누를 때마다 바로 걸린다. 같은 칸에 또 걸면 금액이 더해진다. 건 칩은 취소할 수 없다.
--       마감부터 결과 연출이 끝날 때까지(10초) 온 베팅은 betting_closed로 거절하고 칩은 그대로.
-- 지연 정산(ADR-0003): 앉은 클라이언트가 마감 시각에 roulette_tick()을 부르면 그때 결과를 뽑고 정산한다.
--
-- 홀짝은 은퇴한다. 룰렛의 홀·짝 칸이 같은 게임이라서. 테이블과 지난 기록(이번 주 큰손 포함)은 남기고
-- 새 베팅만 막는다. 옛 앱은 홀짝밖에 모르니 min_version을 올린다 (ADR-0010).

-- ============================================================
-- 테이블
-- ============================================================
create table public.roulette_rounds (
  id            bigint generated always as identity primary key,
  room_code     text not null references public.rooms (code) on delete cascade,
  bet_closes_at timestamptz not null,
  result        smallint check (result between 0 and 12), -- 정산 전엔 null
  settled_at    timestamptz,
  next_at       timestamptz not null,                      -- 결과 연출이 끝나는 시각 (= 마감 + 10초)
  created_at    timestamptz not null default now()
);
create index roulette_rounds_room_idx on public.roulette_rounds (room_code, id desc);

create table public.roulette_bets (
  id         bigint generated always as identity primary key,
  round_id   bigint not null references public.roulette_rounds (id) on delete cascade,
  room_code  text not null, -- Realtime 필터용 비정규화
  player_id  uuid not null references public.players (id) on delete cascade,
  spot       text not null check (spot ~ '^(n([1-9]|1[0-2])|red|black|odd|even|low|high)$'),
  amount     bigint not null check (amount > 0),
  golden     boolean not null default false, -- 황금 칩이면 amount = 100 × 개수
  payout     bigint,                         -- 정산 후 채워짐 (0 = 짐)
  created_at timestamptz not null default now(),
  unique (round_id, player_id, spot, golden),
  check (not golden or spot in ('red', 'black', 'odd', 'even', 'low', 'high'))
);
create index roulette_bets_room_idx on public.roulette_bets (room_code);
create index roulette_bets_created_idx on public.roulette_bets (created_at);

alter table public.roulette_rounds enable row level security;
alter table public.roulette_bets   enable row level security;
create policy "read roulette rounds" on public.roulette_rounds for select to authenticated using (true);
create policy "read roulette bets"   on public.roulette_bets   for select to authenticated using (true);

-- ============================================================
-- 배당 (내부용)
-- ============================================================

-- 지급 배수 (건 칩 포함). 0은 무효 판이라 모든 칸이 ×1
create function public.roulette_multiplier(p_spot text, p_result smallint)
returns int
language sql immutable set search_path = public as $$
  select case
    when p_result = 0 then 1
    when p_spot = 'n' || p_result then 12
    when p_spot = 'red'   then case when p_result in (1, 4, 5, 8, 9, 12) then 2 else 0 end
    when p_spot = 'black' then case when p_result in (1, 4, 5, 8, 9, 12) then 0 else 2 end
    when p_spot = 'odd'   then case when p_result % 2 = 1 then 2 else 0 end
    when p_spot = 'even'  then case when p_result % 2 = 0 then 2 else 0 end
    when p_spot = 'low'   then case when p_result <= 6 then 2 else 0 end
    when p_spot = 'high'  then case when p_result >= 7 then 2 else 0 end
    else 0 end
$$;

-- 결과를 뽑고 정산한다
create function public.roulette_settle(p_round bigint)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r roulette_rounds;
begin
  update roulette_rounds set result = floor(random() * 13)::smallint, settled_at = now()
  where id = p_round and settled_at is null
  returning * into r;
  if not found then return; end if;

  -- 황금 칩은 0이면 칩 대신 황금 칩을 돌려받으니 지급 0
  update roulette_bets b
  set payout = case when b.golden and r.result = 0 then 0 else b.amount * roulette_multiplier(b.spot, r.result) end
  where b.round_id = r.id;

  update players p set chips = p.chips + t.payout
  from (select player_id, sum(payout) as payout from roulette_bets where round_id = r.id group by player_id) t
  where p.id = t.player_id and t.payout > 0;

  if r.result = 0 then
    update players p set golden_chips = p.golden_chips + t.n
    from (select player_id, sum(amount / 100)::int as n from roulette_bets
          where round_id = r.id and golden group by player_id) t
    where p.id = t.player_id and p.golden_until > now();
  end if;

  -- 전광판: 한 판 지급 합계 1,000칩 이상이면서 이득 본 회원 (홀짝·블랙잭과 같은 기준)
  insert into lounge_events (kind, game, player_id, name, amount)
  select 'bigwin', 'roulette', p.id, p.name, t.payout
  from (select player_id, sum(payout) as payout, sum(case when golden then 0 else amount end) as staked
        from roulette_bets where round_id = r.id group by player_id) t
  join players p on p.id = t.player_id
  where t.payout >= 1000 and t.payout > t.staked;
end $$;

-- 화면에 필요한 전부: 지금 판 + 베팅(이름 포함) + 직전 결과
create function public.roulette_state(p_room text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r roulette_rounds;
  last smallint;
begin
  select * into r from roulette_rounds where room_code = p_room order by id desc limit 1;
  -- 지금 판 바로 앞 판의 결과 ("직전 판 · 9 빨강")
  select x.result into last from roulette_rounds x
  where x.room_code = p_room and x.settled_at is not null and x.id < coalesce(r.id, 0)
  order by x.id desc limit 1;
  if r.id is null then
    return jsonb_build_object('now', now(), 'round', null, 'bets', '[]'::jsonb, 'last_result', last);
  end if;
  return jsonb_build_object(
    'now', now(),
    'round', to_jsonb(r),
    'last_result', last,
    'bets', coalesce((
      select jsonb_agg(jsonb_build_object(
          'player_id', b.player_id, 'name', p.name, 'spot', b.spot, 'amount', b.amount,
          'golden', b.golden, 'payout', b.payout)
        order by b.id)
      from roulette_bets b join players p on p.id = b.player_id
      where b.round_id = r.id), '[]'::jsonb));
end $$;

-- ============================================================
-- RPC
-- ============================================================

-- 마감이 지난 판을 정산하고 지금 상태를 돌려준다
create function public.roulette_tick(p_room text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r roulette_rounds;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(hashtext('roulette:' || p_room));
  select * into r from roulette_rounds where room_code = p_room order by id desc limit 1;
  if found and r.settled_at is null and now() >= r.bet_closes_at then
    perform roulette_settle(r.id);
  end if;
  return roulette_state(p_room);
end $$;

-- 칸에 칩을 놓는다 (바로 걸림). 판이 없거나 지난 판 연출이 끝났으면 12초 베팅 창을 연다
create function public.roulette_bet(p_room text, p_spot text, p_amount bigint, p_golden boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r roulette_rounds;
  amount bigint := case when p_golden then 100 else p_amount end;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if amount is null or amount <= 0 then raise exception 'invalid_amount'; end if;
  if p_spot is null or p_spot !~ '^(n([1-9]|1[0-2])|red|black|odd|even|low|high)$' then raise exception 'invalid_spot'; end if;
  if p_golden and p_spot not in ('red', 'black', 'odd', 'even', 'low', 'high') then raise exception 'golden_outside_only'; end if;
  if not exists (select 1 from players where id = me and named) then raise exception 'not_named'; end if;

  perform roulette_tick(p_room);
  select * into r from roulette_rounds where room_code = p_room order by id desc limit 1;

  if not found or (r.settled_at is not null and now() >= r.next_at) then
    insert into rooms (code) values (p_room) on conflict do nothing;
    insert into roulette_rounds (room_code, bet_closes_at, next_at)
    values (p_room, now() + interval '12 seconds', now() + interval '22 seconds')
    returning * into r;
  elsif r.settled_at is not null or now() >= r.bet_closes_at then
    raise exception 'betting_closed';
  end if;

  if p_golden then
    update players set golden_chips = golden_chips - 1
    where id = me and golden_chips > 0 and golden_until > now();
    if not found then raise exception 'no_golden'; end if;
  else
    update players set chips = chips - amount where id = me and chips >= amount;
    if not found then raise exception 'insufficient_chips'; end if;
  end if;

  insert into roulette_bets (round_id, room_code, player_id, spot, amount, golden)
  values (r.id, p_room, me, p_spot, amount, p_golden)
  on conflict (round_id, player_id, spot, golden) do update set amount = roulette_bets.amount + excluded.amount;
  return roulette_state(p_room);
end $$;

-- 혼자 걸었으면 베팅 창을 기다리지 않고 바로 돌린다
create function public.roulette_spin(p_room text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r roulette_rounds;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  perform roulette_tick(p_room);
  select * into r from roulette_rounds where room_code = p_room order by id desc limit 1;
  if not found or r.settled_at is not null or now() >= r.bet_closes_at then raise exception 'betting_closed'; end if;
  if not exists (select 1 from roulette_bets where round_id = r.id and player_id = me) then raise exception 'not_seated'; end if;
  if exists (select 1 from roulette_bets where round_id = r.id and player_id <> me) then raise exception 'not_alone'; end if;

  update roulette_rounds set bet_closes_at = now(), next_at = now() + interval '10 seconds' where id = r.id;
  return roulette_tick(p_room);
end $$;

-- ============================================================
-- 홀짝 은퇴: 새 베팅만 막는다
-- ============================================================
create or replace function public.oddeven_bet(p_room text, p_side text, p_amount bigint, p_golden boolean default false)
returns public.oddeven_bets
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'game_retired';
end $$;

update public.client_policy set min_version = '0.10.0';

-- ============================================================
-- 전광판에 룰렛도
-- ============================================================
alter table public.lounge_events drop constraint lounge_events_game_check;
alter table public.lounge_events add constraint lounge_events_game_check
  check (game in ('slot', 'oddeven', 'blackjack', 'roulette'));

-- ============================================================
-- 이번 주 큰손에 룰렛도 (ADR-0012). 베팅 한 줄이 한 판의 한 칸. 황금 칩은 건 칩 0
-- ============================================================
create or replace view public.game_results as
  select player_id, 'slot'::text as game,
         payout - case when golden then 0 else amount end as net,
         created_at as played_at
  from public.slot_spins
  union all
  select player_id, 'oddeven', payout - case when golden then 0 else amount end, created_at
  from public.oddeven_bets
  where payout is not null
  union all
  select player_id, 'minority', payout - amount, created_at
  from public.minority_picks
  where payout is not null
  union all
  select player_id, 'blackjack',
         payout - case when golden then 0 else amount * (case when doubled then 2 else 1 end) end, created_at
  from public.bj_seats
  where player_id is not null and payout is not null
  union all
  select player_id, 'roulette', payout - case when golden then 0 else amount end, created_at
  from public.roulette_bets
  where payout is not null;

revoke all on public.game_results from public, anon, authenticated;

-- ============================================================
-- 권한
-- ============================================================
revoke execute on function public.roulette_multiplier(text, smallint)           from public, anon;
revoke execute on function public.roulette_settle(bigint)                      from public, anon, authenticated;
revoke execute on function public.roulette_state(text)                         from public, anon, authenticated;
revoke execute on function public.roulette_tick(text)                          from public, anon;
revoke execute on function public.roulette_bet(text, text, bigint, boolean)    from public, anon;
revoke execute on function public.roulette_spin(text)                          from public, anon;
grant  execute on function public.roulette_multiplier(text, smallint)          to authenticated;
grant  execute on function public.roulette_tick(text)                          to authenticated;
grant  execute on function public.roulette_bet(text, text, bigint, boolean)    to authenticated;
grant  execute on function public.roulette_spin(text)                          to authenticated;

alter publication supabase_realtime add table public.roulette_rounds, public.roulette_bets;
