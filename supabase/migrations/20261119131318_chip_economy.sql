-- 429 Lounge: 칩 경제 v1 (docs/chip-economy.md)
--
--  - 토큰 환전: 새로 쓴 토큰 1,000개 = 1칩. 날짜별 누적값을 받아서 "이미 준 만큼"을 뺀 차액만 지급 (멱등)
--  - 출근 도장: KST 기준 하루 한 번 +100, 잔액 100 미만이면 +300 (파산 구제)
--  - 황금 칩: 429 한 건(resets_at)당 한 번. five_hour=3개, 그 외=10개. 리셋 시각에 소멸
--  - 황금 칩 베팅: 1개 = 100칩짜리 공짜 베팅 (이기면 200, 지면 0)
--
-- 토큰/429 수치는 클라이언트가 로컬 로그에서 읽어 보낸다. 친구끼리 쓰는 앱이라 신뢰하되,
-- 날짜 범위·상한·리셋 시각 같은 기본적인 말이 되는지만 서버에서 검사한다.

alter table public.players
  add column golden_chips int not null default 0 check (golden_chips >= 0),
  add column golden_until timestamptz,
  add column last_daily   date;

alter table public.oddeven_bets
  add column golden boolean not null default false;

create table public.token_claims (
  player_id    uuid not null references public.players (id) on delete cascade,
  day          date not null,          -- 클라이언트 로컬 날짜
  fresh_tokens bigint not null default 0,
  chips        bigint not null default 0, -- 이 날짜로 지금까지 지급한 칩
  updated_at   timestamptz not null default now(),
  primary key (player_id, day)
);

create table public.golden_grants (
  player_id  uuid not null references public.players (id) on delete cascade,
  resets_at  timestamptz not null,
  limit_type text not null,
  amount     int not null,
  created_at timestamptz not null default now(),
  primary key (player_id, resets_at)
);

alter table public.token_claims  enable row level security;
alter table public.golden_grants enable row level security;
create policy "read own claims" on public.token_claims  for select to authenticated using (player_id = auth.uid());
create policy "read own grants" on public.golden_grants for select to authenticated using (player_id = auth.uid());

create function public.lounge_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Seoul')::date $$;

-- 결과: { "granted": 지급량, "player": 갱신된 내 지갑 }
create function public.grant_result(p_granted bigint)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('granted', p_granted, 'player', to_jsonb(p))
  from players p where p.id = auth.uid()
$$;

-- ============================================================
-- 토큰 → 칩
-- ============================================================
create function public.claim_tokens(p_day date, p_fresh bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  target  bigint;
  paid    bigint;
  granted bigint := 0;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_day not between lounge_today() - 1 and lounge_today() + 1 then raise exception 'invalid_day'; end if;
  if p_fresh is null or p_fresh < 0 or p_fresh > 50000000 then raise exception 'invalid_tokens'; end if;

  target := p_fresh / 1000;

  insert into token_claims (player_id, day) values (auth.uid(), p_day) on conflict do nothing;
  select chips into paid from token_claims where player_id = auth.uid() and day = p_day for update;

  if target > paid then
    granted := target - paid;
    update token_claims set fresh_tokens = p_fresh, chips = target, updated_at = now()
    where player_id = auth.uid() and day = p_day;
    update players set chips = chips + granted where id = auth.uid();
  end if;

  return grant_result(granted);
end $$;

-- ============================================================
-- 출근 도장 / 파산 구제
-- ============================================================
create function public.daily_bonus()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me      players;
  granted bigint := 0;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into me from players where id = auth.uid() for update;
  if not found then raise exception 'no_player'; end if;

  if me.last_daily is null or me.last_daily < lounge_today() then
    granted := case when me.chips < 100 then 300 else 100 end;
    update players set chips = chips + granted, last_daily = lounge_today() where id = auth.uid();
  end if;

  return grant_result(granted);
end $$;

-- ============================================================
-- 429 → 황금 칩
-- ============================================================
create function public.claim_golden(p_resets_at timestamptz, p_type text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  amount int := case when p_type = 'five_hour' then 3 else 10 end;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  -- 아직 안 풀린 리밋이어야 하고, 리셋이 말도 안 되게 먼 미래면 거절
  if p_resets_at <= now() or p_resets_at > now() + interval '8 days' then raise exception 'invalid_lock'; end if;

  insert into golden_grants (player_id, resets_at, limit_type, amount)
  values (auth.uid(), p_resets_at, coalesce(p_type, 'unknown'), amount)
  on conflict do nothing;
  if not found then return grant_result(0); end if;

  update players set
    -- 이전 황금 칩이 이미 만료됐으면 버리고 새로 시작
    golden_chips = case when golden_until > now() then golden_chips else 0 end + amount,
    golden_until = greatest(coalesce(golden_until, p_resets_at), p_resets_at)
  where id = auth.uid();

  return grant_result(amount);
end $$;

-- ============================================================
-- 홀짝 베팅: 황금 칩 지원 (기존 함수 교체)
-- ============================================================
drop function public.oddeven_bet(text, text, bigint);

create function public.oddeven_bet(p_room text, p_side text, p_amount bigint, p_golden boolean default false)
returns public.oddeven_bets
language plpgsql security definer set search_path = public as $$
declare
  r public.oddeven_rounds;
  bet public.oddeven_bets;
  amount bigint := case when p_golden then 100 else p_amount end;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if amount is null or amount <= 0 then raise exception 'invalid_amount'; end if;

  r := oddeven_tick(p_room);
  if now() < r.opens_at or now() >= r.closes_at then
    raise exception 'betting_closed';
  end if;

  if p_golden then
    update players set golden_chips = golden_chips - 1
    where id = auth.uid() and golden_chips > 0 and golden_until > now();
    if not found then raise exception 'no_golden'; end if;
  else
    update players set chips = chips - amount
    where id = auth.uid() and chips >= amount;
    if not found then raise exception 'insufficient_chips'; end if;
  end if;

  insert into oddeven_bets (round_id, room_code, player_id, side, amount, golden)
  values (r.id, p_room, auth.uid(), p_side, amount, p_golden)
  returning * into bet;
  return bet;
exception
  when unique_violation then raise exception 'already_bet';
end $$;

-- ============================================================
-- 권한
-- ============================================================
revoke execute on function public.grant_result(bigint)                      from public, anon, authenticated;
revoke execute on function public.claim_tokens(date, bigint)                from public, anon;
revoke execute on function public.daily_bonus()                             from public, anon;
revoke execute on function public.claim_golden(timestamptz, text)           from public, anon;
revoke execute on function public.oddeven_bet(text, text, bigint, boolean)  from public, anon;
grant  execute on function public.claim_tokens(date, bigint)                to authenticated;
grant  execute on function public.daily_bonus()                             to authenticated;
grant  execute on function public.claim_golden(timestamptz, text)           to authenticated;
grant  execute on function public.oddeven_bet(text, text, bigint, boolean)  to authenticated;
