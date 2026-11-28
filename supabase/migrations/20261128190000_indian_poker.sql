-- 인디언 포커 (ADR-0023, docs/chip-economy.md)
--
-- 룰: 카드 1~10 한 벌(A=1)을 매 판 섞어 한 장씩. 내 카드는 판이 끝날 때까지 나만 못 본다(상대 카드만 보임).
--     앤티 10칩 자동 → 한 바퀴 순차 베팅(체크·베팅·콜·레이즈·폴드) → 높은 숫자 승, 동점이면 나눔.
--     체크는 아무도 베팅 안 했을 때만. 레이즈는 직전에 올린 폭 이상, 횟수 제한 없음. 잔액이 모자라면 올인.
--     올인은 사이드팟: 올인한 사람은 자기가 낸 만큼만 각자에게서 딴다.
-- 좌석: 사람 + 컴퓨터 2~4석(테이블 만들 때 컴퓨터 1~3명). 사람이 들어오면 다음 판부터 컴퓨터 자리를 차지한다.
--       사람이 모두 나가면 진행 중 판이 끝나는 대로 닫힌다. 첫 행동 자리는 판마다 한 칸씩 돈다.
-- 시간: 사람 차례 11초(서버 기준), 넘기면 자동 폴드. 컴퓨터는 1~5초 뒤 행동. 결과 5초 뒤 다음 판.
--       이탈·끊김은 차례 타이머로만 처리한다: 연속 2판 시간 초과로 폴드되면 그 판이 끝날 때 자리에서 뺀다.
-- 기준 시각: RPC는 테이블 잠금을 잡은 뒤의 clock_timestamp()로 마감을 판단한다 (트랜잭션 시작 시각 now()가 아니라).
-- 지연 정산(ADR-0003, ADR-0014와 같음): 상주 프로세스가 없다. 앉은 클라이언트가 ip_tick을 부르면 마감이 지난
--   차례(시간 초과 폴드, 컴퓨터 행동, 다음 판 시작)를 순서대로 처리한다. 다음 마감은 직전 마감에서 이어 계산해서,
--   아무도 tick을 안 부른 사이의 일도 다음 tick 때 같은 결과로 따라잡는다.
-- 컴퓨터: 칩이 무한. 사람과 같은 규칙으로 판돈에 칩을 넣고 따며, 그 결과는 실제 사람 칩 증감이 된다.
-- 카드는 ip_cards에만 있다. 이 테이블은 읽기 정책이 없어 클라이언트가 못 읽고, 조회 RPC(ip_state)가
--   부른 사람 자리의 카드를 빼고 돌려준다.

-- ============================================================
-- 테이블
-- ============================================================
create table public.ip_tables (
  id         bigint generated always as identity primary key,
  capacity   smallint not null check (capacity between 2 and 4), -- 사람 + 컴퓨터 자리 수 (만든 사람 1 + 컴퓨터 1~3)
  bot_names  text[] not null,                                    -- 자리별 컴퓨터 이름 (bot_names[seat])
  status     text not null default 'open' check (status in ('open', 'closed')),
  created_by uuid references public.players (id) on delete set null,
  created_at timestamptz not null default now(),
  closed_at  timestamptz
);
create index ip_tables_open_idx on public.ip_tables (id) where status = 'open';

-- 테이블에 앉은 사람. 자리(seat)는 들어올 때 정하고, 그 자리의 컴퓨터는 다음 판부터 빠진다
create table public.ip_members (
  id          bigint generated always as identity primary key,
  table_id    bigint not null references public.ip_tables (id) on delete cascade,
  player_id   uuid not null references public.players (id) on delete cascade,
  seat        smallint not null check (seat between 1 and 4),
  joined_at   timestamptz not null default now(),
  timeouts    int not null default 0,             -- 연속 시간 초과 폴드 수. 직접 행동하면 0, 2가 되면 그 판 끝에 뺀다
  left_at     timestamptz,
  left_reason text check (left_reason in ('leave', 'away', 'broke')) -- away = 연속 2판 시간 초과
);
create unique index ip_members_seat_uq on public.ip_members (table_id, seat) where left_at is null;
create unique index ip_members_player_uq on public.ip_members (player_id) where left_at is null; -- 한 번에 한 테이블
create index ip_members_table_idx on public.ip_members (table_id);

create table public.ip_hands (
  id              bigint generated always as identity primary key,
  table_id        bigint not null references public.ip_tables (id) on delete cascade,
  hand_no         int not null,
  phase           text not null default 'betting' check (phase in ('betting', 'done')),
  first_seat      smallint not null,     -- 이번 판 첫 행동 자리 (판마다 한 칸씩)
  turn_seat       smallint,              -- null = 끝
  turn_no         int not null default 0, -- 차례가 바뀔 때마다 +1. ip_action이 이 값으로 지연·재시도 행동을 걸러낸다
  turn_started_at timestamptz,
  turn_deadline   timestamptz,           -- 사람은 시작 + 11초, 컴퓨터는 1~5초 뒤 행동
  current_bet     bigint not null default 0, -- 이번 판 가장 높은 베팅 (앤티 제외)
  min_raise       bigint not null default 10, -- 직전에 올린 폭. 첫 베팅 최소 = 앤티
  raises          int not null default 0,     -- 베팅·레이즈 횟수 (컴퓨터는 3번째부터 안 올린다)
  started_at      timestamptz not null,
  settled_at      timestamptz,
  next_at         timestamptz,           -- 결과 5초가 끝나는 시각 = 다음 판 시작
  created_at      timestamptz not null default now(),
  unique (table_id, hand_no)
);
create index ip_hands_table_idx on public.ip_hands (table_id, hand_no desc);

-- 판 결과 기록: 참가자, 낸 칩, 지급, 컴퓨터 여부(player_id null). 카드는 여기 없다
create table public.ip_hand_seats (
  hand_id     bigint not null references public.ip_hands (id) on delete cascade,
  table_id    bigint not null, -- Realtime 필터용 비정규화
  seat        smallint not null check (seat between 1 and 4),
  player_id   uuid references public.players (id) on delete cascade, -- null = 컴퓨터
  bot_name    text,
  put         bigint not null default 0 check (put >= 0), -- 이번 판에 낸 칩 전부 (앤티 포함)
  bet         bigint not null default 0 check (bet >= 0), -- 베팅 라운드에서 낸 칩 (앤티 제외)
  folded      boolean not null default false,
  all_in      boolean not null default false,
  acted       boolean not null default false,  -- 마지막 베팅·레이즈 이후 행동했는지
  last_action text check (last_action in ('check', 'bet', 'call', 'raise', 'fold', 'timeout', 'leave')),
  last_amount bigint,                           -- 그 행동으로 낸 칩
  payout      bigint,                           -- 정산 후 채워짐 (낸 칩 포함, 0 = 잃음)
  created_at  timestamptz not null default now(),
  primary key (hand_id, seat),
  unique (hand_id, player_id),
  check ((player_id is null) = (bot_name is not null))
);
create index ip_hand_seats_table_idx on public.ip_hand_seats (table_id);
create index ip_hand_seats_player_idx on public.ip_hand_seats (player_id) where player_id is not null;

-- 카드. 읽기 정책 없음 = 클라이언트는 직접 못 읽는다
create table public.ip_cards (
  hand_id bigint not null,
  seat    smallint not null,
  card    smallint not null check (card between 1 and 10),
  primary key (hand_id, seat),
  foreign key (hand_id, seat) references public.ip_hand_seats (hand_id, seat) on delete cascade
);

alter table public.ip_tables     enable row level security;
alter table public.ip_members    enable row level security;
alter table public.ip_hands      enable row level security;
alter table public.ip_hand_seats enable row level security;
alter table public.ip_cards      enable row level security;
create policy "read ip tables"  on public.ip_tables     for select to authenticated using (true);
create policy "read ip members" on public.ip_members    for select to authenticated using (true);
create policy "read ip hands"   on public.ip_hands      for select to authenticated using (true);
create policy "read ip seats"   on public.ip_hand_seats for select to authenticated using (true);
revoke all on public.ip_cards from public, anon, authenticated;

-- ============================================================
-- 진행 (내부용). p_base = 이 일이 일어난 시각 (마감에서 이어 계산)
-- ============================================================

-- 판 정산. 사이드팟: 접지 않은 사람들이 낸 금액 단계마다 팟을 나눠, 그 단계까지 낸 사람 중 높은 카드가 가져간다.
-- 접은 사람이 낸 칩은 판돈에 남는다. 단 이탈로 접은 사람이 접지 않은 누구보다 많이 냈으면(정상 진행에선 안 생김),
-- 남은 누구도 콜하지 못한 그 초과분은 낸 사람에게 돌려준다 (올인 상한이 우선: 올인한 사람은 낸 만큼만 딴다).
-- 동점이면 나누고, 나눠 떨어지지 않는 칩은 첫 행동 자리부터 한 칩씩.
create function public.ip_settle(p_hand bigint, p_base timestamptz)
returns void
language plpgsql security definer set search_path = public as $$
declare
  h ip_hands;
  cap smallint;
  lmax bigint;
  lv bigint;
  prev bigint := 0;
  slice bigint;
  best smallint;
  winners smallint[];
  n int;
begin
  select * into h from ip_hands where id = p_hand for update;
  if h.phase = 'done' then return; end if;
  select capacity into cap from ip_tables where id = h.table_id;

  select max(put) into lmax from ip_hand_seats where hand_id = p_hand and not folded;
  update ip_hand_seats set payout = put - least(put, lmax) where hand_id = p_hand; -- 아무도 못 받은 초과분 환불

  for lv in select distinct put from ip_hand_seats where hand_id = p_hand and not folded order by put loop
    select sum(least(put, lv) - least(put, prev)) into slice from ip_hand_seats where hand_id = p_hand;
    select max(c.card) into best
    from ip_hand_seats s join ip_cards c on c.hand_id = s.hand_id and c.seat = s.seat
    where s.hand_id = p_hand and not s.folded and s.put >= lv;
    select array_agg(s.seat order by ((s.seat - h.first_seat) % cap + cap) % cap) into winners
    from ip_hand_seats s join ip_cards c on c.hand_id = s.hand_id and c.seat = s.seat
    where s.hand_id = p_hand and not s.folded and s.put >= lv and c.card = best;
    n := cardinality(winners);
    update ip_hand_seats
    set payout = payout + slice / n + case when array_position(winners, seat) <= slice % n then 1 else 0 end
    where hand_id = p_hand and seat = any(winners);
    prev := lv;
  end loop;

  update players p set chips = p.chips + s.payout
  from ip_hand_seats s
  where s.hand_id = p_hand and s.player_id = p.id and s.payout > 0;

  update ip_hands
  set phase = 'done', turn_seat = null, turn_started_at = null, turn_deadline = null, turn_no = turn_no + 1,
      settled_at = p_base, next_at = p_base + interval '5 seconds'
  where id = p_hand;

  -- 연속 2판 시간 초과로 폴드된 사람은 이 판이 끝나며 자리에서 뺀다 (이탈·끊김은 차례 타이머로만 판단)
  update ip_members set left_at = p_base, left_reason = 'away'
  where table_id = h.table_id and left_at is null and timeouts >= 2;
end $$;

-- 더 행동할 사람이 없어 바로 공개·정산해야 하는지 (ip_next_turn, 차례 밖 이탈이 같이 쓴다)
--  - 접지 않은 자리가 하나뿐 / 접지 않은 사람이 없음(컴퓨터끼리 남음)
--  - 행동할 수 있는 자리(접지 않음·올인 아님)가 없거나, 하나뿐인데 이미 가장 높은 베팅을 맞췄음
create function public.ip_should_end(p_hand bigint)
returns boolean
language sql stable security definer set search_path = public as $$
  select x.live <= 1 or x.live_humans = 0 or x.active = 0
      or (x.active = 1 and x.active_bet >= x.maxbet)
  from (
    select count(*) filter (where not folded) as live,
           count(*) filter (where not folded and player_id is not null) as live_humans,
           count(*) filter (where not folded and not all_in) as active,
           max(bet) filter (where not folded and not all_in) as active_bet,
           max(bet) filter (where not folded) as maxbet
    from ip_hand_seats where hand_id = p_hand) x
$$;

-- 다음 차례를 정한다. 더 할 사람이 없으면(ip_should_end) 정산.
-- 아니면 지금 차례 다음 자리부터 돌며, 아직 행동 안 했거나 베팅이 모자란 첫 자리
create function public.ip_next_turn(p_hand bigint, p_base timestamptz)
returns void
language plpgsql security definer set search_path = public as $$
declare
  h ip_hands;
  cap smallint;
  start smallint;
  nxt ip_hand_seats;
begin
  select * into h from ip_hands where id = p_hand for update;
  if h.phase <> 'betting' then return; end if;
  select capacity into cap from ip_tables where id = h.table_id;

  if ip_should_end(p_hand) then
    perform ip_settle(p_hand, p_base);
    return;
  end if;

  start := case when h.turn_seat is null then h.first_seat else h.turn_seat % cap + 1 end;
  select * into nxt from ip_hand_seats
  where hand_id = p_hand and not folded and not all_in and (not acted or bet < h.current_bet)
  order by ((seat - start) % cap + cap) % cap
  limit 1;

  if not found then
    perform ip_settle(p_hand, p_base);
    return;
  end if;

  update ip_hands
  set turn_seat = nxt.seat, turn_started_at = p_base, turn_no = turn_no + 1,
      turn_deadline = p_base + case when nxt.player_id is null
                                    then (1 + random() * 4) * interval '1 second'
                                    else interval '11 seconds' end
  where id = p_hand;
end $$;

-- 차례인 자리의 행동 하나. 검사에 걸리면 예외 (호출한 트랜잭션이 통째로 취소된다)
--  check: 아무도 베팅 안 했을 때만 / bet: 첫 베팅, 최소 min_raise / call: 낼 칩이 있을 때
--  raise: p_amount = 지금 베팅 위로 더 올리는 폭, 최소 min_raise / fold, timeout(시간 초과 = 폴드)
--  잔액이 모자라면(bet·raise·call) 가진 칩 전부 = 올인. 올인은 최소 폭보다 작아도 된다
create function public.ip_apply(p_hand bigint, p_seat smallint, p_action text, p_amount bigint, p_base timestamptz)
returns void
language plpgsql security definer set search_path = public as $$
declare
  h ip_hands;
  s ip_hand_seats;
  stack bigint;
  to_call bigint;
  pay bigint := 0;
  newbet bigint;
begin
  select * into h from ip_hands where id = p_hand for update;
  if h.phase <> 'betting' or h.turn_seat is distinct from p_seat then raise exception 'not_your_turn'; end if;
  select * into s from ip_hand_seats where hand_id = p_hand and seat = p_seat for update;
  to_call := h.current_bet - s.bet;
  if s.player_id is null then
    stack := 1000000000000; -- 컴퓨터는 칩이 무한
  else
    select chips into stack from players where id = s.player_id for update;
  end if;

  -- 연속 시간 초과 수: 시간 초과면 +1, 직접 행동하면 0
  if s.player_id is not null then
    update ip_members set timeouts = case when p_action = 'timeout' then timeouts + 1 else 0 end
    where table_id = h.table_id and player_id = s.player_id and left_at is null;
  end if;

  if p_action in ('fold', 'timeout') then
    update ip_hand_seats set folded = true, acted = true, last_action = p_action, last_amount = 0
    where hand_id = p_hand and seat = p_seat;
    perform ip_next_turn(p_hand, p_base);
    return;
  elsif p_action = 'check' then
    if to_call <> 0 then raise exception 'cannot_check'; end if;
  elsif p_action = 'call' then
    if to_call <= 0 then raise exception 'nothing_to_call'; end if;
    pay := least(to_call, stack);
  elsif p_action in ('bet', 'raise') then
    if p_action = 'bet' and h.current_bet <> 0 then raise exception 'cannot_bet'; end if;
    if p_action = 'raise' and h.current_bet = 0 then raise exception 'cannot_raise'; end if;
    if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;
    pay := to_call + p_amount;
    if pay >= stack then
      pay := stack; -- 올인
    elsif p_amount < h.min_raise then
      raise exception 'raise_too_small';
    end if;
  else
    raise exception 'invalid_action';
  end if;

  if pay > 0 and s.player_id is not null then
    update players set chips = chips - pay where id = s.player_id and chips >= pay;
    if not found then raise exception 'insufficient_chips'; end if;
  end if;

  newbet := s.bet + pay;
  update ip_hand_seats
  set bet = newbet, put = put + pay, acted = true, last_action = p_action, last_amount = pay,
      all_in = all_in or (player_id is not null and pay > 0 and pay = stack)
  where hand_id = p_hand and seat = p_seat;

  if newbet > h.current_bet then
    -- 올린 폭이 직전 폭보다 작은 올인이면 최소 폭은 그대로. 올렸으면 다른 자리는 다시 행동해야 한다
    update ip_hands
    set current_bet = newbet, min_raise = greatest(min_raise, newbet - h.current_bet), raises = raises + 1
    where id = p_hand;
    update ip_hand_seats set acted = false
    where hand_id = p_hand and seat <> p_seat and not folded and not all_in;
  end if;

  perform ip_next_turn(p_hand, p_base);
end $$;

-- 컴퓨터(또는 시뮬레이션의 대역)의 판단. 자기 카드는 모르고 상대 카드만 본다.
-- 승률 p = 남은 카드(1~10에서 다른 자리 카드를 뺀 것) 중 접지 않은 상대 최고 카드를 이기는 비율(비기면 절반).
-- 아무도 안 걸었으면: p ≥ 0.7이면 대개 베팅, 약하면 가끔 허세 베팅, 아니면 체크.
-- 걸려 있으면: 아주 강하면 가끔 레이즈(판당 3번째 레이즈부터는 안 함), 판돈 대비 콜 값이 맞으면 콜(애매하면 가끔 폴드),
--   가끔 허세 레이즈·콜, 아니면 폴드. 베팅 크기는 판돈의 절반~전부를 10칩 단위로, 200칩까지(최소 폭이 더 크면 최소 폭).
create function public.ip_decide(p_hand bigint, p_seat smallint, out action text, out amount bigint)
language plpgsql volatile security definer set search_path = public as $$
declare
  h ip_hands;
  s ip_hand_seats;
  top smallint;
  win numeric;
  tie numeric;
  total numeric;
  p numeric;
  to_call bigint;
  pot bigint;
  need numeric;
  r float8 := random();
  size bigint;
begin
  select * into h from ip_hands where id = p_hand;
  select * into s from ip_hand_seats where hand_id = p_hand and seat = p_seat;

  select max(c.card) into top
  from ip_hand_seats o join ip_cards c on c.hand_id = o.hand_id and c.seat = o.seat
  where o.hand_id = p_hand and o.seat <> p_seat and not o.folded;

  select count(*) filter (where u > top), count(*) filter (where u = top), count(*)
    into win, tie, total
  from generate_series(1, 10) u
  where u not in (select card from ip_cards where hand_id = p_hand and seat <> p_seat);
  p := case when total = 0 then 0.5 else (win + tie / 2) / total end;

  to_call := h.current_bet - s.bet;
  select sum(put) into pot from ip_hand_seats where hand_id = p_hand;
  size := greatest(h.min_raise, least(200, round(pot * (0.5 + random() * 0.5) / 10) * 10));

  if to_call = 0 then
    if (p >= 0.7 and r < 0.75) or (p < 0.3 and r < 0.12) then
      action := 'bet'; amount := size;
    else
      action := 'check';
    end if;
    return;
  end if;

  need := to_call::numeric / (pot + to_call);
  if h.raises < 3 and ((p >= 0.8 and r < 0.5) or (p < 0.3 and r < 0.05)) then
    action := 'raise'; amount := size;
  elsif p >= need + 0.05 and not (p < 0.6 and r < 0.08) then
    action := 'call';
  elsif r < 0.05 then
    action := 'call';
  else
    action := 'fold';
  end if;
end $$;

-- 새 판. 앤티가 없는 사람은 자리에서 뺀다. 사람이 아무도 없으면 테이블을 닫고 false
create function public.ip_start_hand(p_table bigint, p_base timestamptz)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  t ip_tables;
  h ip_hands;
  n int;
  deck smallint[];
  i int;
  m ip_members;
  left_chips bigint;
begin
  select * into t from ip_tables where id = p_table for update;
  if t.status <> 'open' then return false; end if;

  update ip_members mm set left_at = p_base, left_reason = 'broke'
  from players p
  where p.id = mm.player_id and mm.table_id = p_table and mm.left_at is null and p.chips < 10;

  if not exists (select 1 from ip_members where table_id = p_table and left_at is null) then
    update ip_tables set status = 'closed', closed_at = p_base where id = p_table;
    return false;
  end if;

  select coalesce(max(hand_no), 0) + 1 into n from ip_hands where table_id = p_table;
  insert into ip_hands (table_id, hand_no, first_seat, started_at)
  values (p_table, n, ((n - 1) % t.capacity) + 1, p_base)
  returning * into h;

  select array_agg(c::smallint order by random()) into deck from generate_series(1, 10) c;
  for i in 1..t.capacity loop
    select * into m from ip_members where table_id = p_table and seat = i and left_at is null;
    left_chips := null;
    if m.id is not null then
      update players set chips = chips - 10 where id = m.player_id and chips >= 10 returning chips into left_chips;
      if left_chips is null then
        update ip_members set left_at = p_base, left_reason = 'broke' where id = m.id;
      end if;
    end if;
    if left_chips is not null then
      insert into ip_hand_seats (hand_id, table_id, seat, player_id, put, all_in)
      values (h.id, p_table, i, m.player_id, 10, left_chips = 0);
    else
      insert into ip_hand_seats (hand_id, table_id, seat, bot_name, put)
      values (h.id, p_table, i, t.bot_names[i], 10);
    end if;
    insert into ip_cards (hand_id, seat, card) values (h.id, i, deck[i]);
    m := null;
  end loop;

  -- 카드를 나눠 주는 연출 2초 뒤 첫 차례 (그 전엔 ip_action이 not_started로 거절)
  perform ip_next_turn(h.id, p_base + interval '2 seconds');
  return true;
end $$;

-- 마감이 지난 일을 순서대로 처리한다: 시간 초과 폴드, 컴퓨터 행동, 다음 판. 밀려 있으면 끝까지 따라잡는다
create function public.ip_advance(p_table bigint, p_now timestamptz)
returns void
language plpgsql security definer set search_path = public as $$
declare
  st text;
  h ip_hands;
  s ip_hand_seats;
  d record;
  steps int := 0;
begin
  loop
    exit when steps >= 200;
    steps := steps + 1;
    select status into st from ip_tables where id = p_table;
    exit when st is distinct from 'open';
    select * into h from ip_hands where table_id = p_table order by hand_no desc limit 1;

    if not found then
      exit when not ip_start_hand(p_table, p_now);
    elsif h.phase = 'done' then
      exit when p_now < h.next_at;
      exit when not ip_start_hand(p_table, h.next_at);
    elsif p_now >= h.turn_deadline then
      select * into s from ip_hand_seats where hand_id = h.id and seat = h.turn_seat;
      if s.player_id is null then
        select * into d from ip_decide(h.id, h.turn_seat);
        perform ip_apply(h.id, h.turn_seat, d.action, d.amount, h.turn_deadline);
      else
        perform ip_apply(h.id, h.turn_seat, 'timeout', null, h.turn_deadline);
      end if;
    else
      exit;
    end if;
  end loop;
end $$;

-- 화면에 필요한 전부. 판이 끝나기 전엔 카드를 가린다:
--   부른 사람이 이 판에 앉은 자리 = 늘 가림, 테이블에 앉지 않은 사람 = 전부 가림, 끝난 판 = 전부 공개
create function public.ip_state(p_table bigint, p_me uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  t ip_tables;
  mm ip_members;
  member boolean;
  h ip_hands;
  my_seat smallint;
begin
  select * into t from ip_tables where id = p_table;
  if not found then raise exception 'no_table'; end if;
  select * into mm from ip_members where table_id = p_table and player_id = p_me order by id desc limit 1;
  member := mm.id is not null and mm.left_at is null;
  select * into h from ip_hands where table_id = p_table order by hand_no desc limit 1;
  if h.id is not null then
    select seat into my_seat from ip_hand_seats where hand_id = h.id and player_id = p_me;
  end if;

  return jsonb_build_object(
    'now', clock_timestamp(),
    'table', jsonb_build_object('id', t.id, 'capacity', t.capacity, 'status', t.status, 'closed_at', t.closed_at),
    'me', jsonb_build_object(
      'member', member,
      'seat', case when member then mm.seat end,
      'hand_seat', my_seat,
      'left_reason', case when member then null else mm.left_reason end),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object('seat', x.seat, 'player_id', x.player_id, 'name', p.name) order by x.seat)
      from ip_members x join players p on p.id = x.player_id
      where x.table_id = p_table and x.left_at is null), '[]'::jsonb),
    'hand', case when h.id is null then null else jsonb_build_object(
      'id', h.id, 'hand_no', h.hand_no, 'phase', h.phase, 'first_seat', h.first_seat,
      'turn_seat', h.turn_seat, 'turn_no', h.turn_no, 'turn_started_at', h.turn_started_at, 'turn_deadline', h.turn_deadline,
      'current_bet', h.current_bet, 'min_raise', h.min_raise,
      'pot', (select sum(put) from ip_hand_seats where hand_id = h.id),
      'started_at', h.started_at, 'settled_at', h.settled_at, 'next_at', h.next_at) end,
    'seats', coalesce((
      select jsonb_agg(jsonb_build_object(
          'seat', s.seat, 'player_id', s.player_id, 'name', coalesce(p.name, s.bot_name), 'bot', s.player_id is null,
          'chips', p.chips, 'put', s.put, 'bet', s.bet, 'folded', s.folded, 'all_in', s.all_in,
          'last_action', s.last_action, 'last_amount', s.last_amount,
          'card', case when h.phase = 'done' or (member and s.seat is distinct from my_seat) then c.card end,
          'payout', s.payout, 'net', s.payout - s.put)
        order by s.seat)
      from ip_hand_seats s
      left join players p on p.id = s.player_id
      left join ip_cards c on c.hand_id = s.hand_id and c.seat = s.seat
      where s.hand_id = h.id), '[]'::jsonb));
end $$;

-- ============================================================
-- RPC
-- ============================================================

-- 로비: 열린 테이블 목록 (사람만 센다, 컴퓨터는 숨김) + 내가 앉은 테이블.
-- 아무도 tick을 안 부르는 테이블도 여기서 따라잡아, 사람이 다 떠난 테이블은 목록에서 빠진다
create function public.ip_lobby()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  tid bigint;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  for tid in select id from ip_tables where status = 'open' order by id loop
    perform pg_advisory_xact_lock(hashtext('ip:' || tid));
    perform ip_advance(tid, clock_timestamp());
  end loop;

  return jsonb_build_object(
    'now', clock_timestamp(),
    'my_table', (select table_id from ip_members where player_id = me and left_at is null),
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', t.id, 'capacity', t.capacity, 'humans', x.humans, 'names', x.names,
          'hand_no', (select max(hand_no) from ip_hands where table_id = t.id))
        order by (x.humans >= t.capacity), t.id)
      from ip_tables t
      cross join lateral (
        select count(*)::int as humans, coalesce(jsonb_agg(p.name order by m.seat), '[]'::jsonb) as names
        from ip_members m join players p on p.id = m.player_id
        where m.table_id = t.id and m.left_at is null) x
      where t.status = 'open'), '[]'::jsonb));
end $$;

-- 테이블 만들기: 나 + 컴퓨터 1~3명. 바로 첫 판
create function public.ip_create(p_bots int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  names text[];
  tid bigint;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if p_bots is null or p_bots not between 1 and 3 then raise exception 'invalid_bots'; end if;
  if not exists (select 1 from players where id = me and named) then raise exception 'not_named'; end if;
  if (select chips from players where id = me) < 10 then raise exception 'insufficient_chips'; end if;
  if exists (select 1 from ip_members where player_id = me and left_at is null) then raise exception 'already_at_table'; end if;

  select array_agg(x order by random()) into names
  from unnest(array['빌드봇', '린트봇', '캐시봇', '커밋봇', '핫픽스봇', '디버그봇']) x;

  insert into ip_tables (capacity, bot_names, created_by) values (p_bots + 1, names[1:4], me) returning id into tid;
  perform pg_advisory_xact_lock(hashtext('ip:' || tid));
  insert into ip_members (table_id, player_id, seat) values (tid, me, 1);
  perform ip_start_hand(tid, clock_timestamp());
  return ip_state(tid, me);
exception
  when unique_violation then raise exception 'already_at_table';
end $$;

-- 열린 테이블에 앉는다. 다음 판부터 빈 컴퓨터 자리를 차지한다. 이미 앉아 있으면 그대로
create function public.ip_join(p_table bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t ip_tables;
  free int;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(hashtext('ip:' || p_table));
  perform ip_advance(p_table, clock_timestamp());
  select * into t from ip_tables where id = p_table;
  if not found then raise exception 'no_table'; end if;
  if t.status <> 'open' then raise exception 'table_closed'; end if;

  if exists (select 1 from ip_members where table_id = p_table and player_id = me and left_at is null) then
    return ip_state(p_table, me);
  end if;
  if exists (select 1 from ip_members where player_id = me and left_at is null) then raise exception 'already_at_table'; end if;
  if not exists (select 1 from players where id = me and named) then raise exception 'not_named'; end if;
  if (select chips from players where id = me) < 10 then raise exception 'insufficient_chips'; end if;

  select min(i) into free from generate_series(1, t.capacity) i
  where not exists (select 1 from ip_members where table_id = p_table and seat = i and left_at is null);
  if free is null then raise exception 'table_full'; end if;

  insert into ip_members (table_id, player_id, seat, joined_at) values (p_table, me, free, clock_timestamp());
  return ip_state(p_table, me);
exception
  when unique_violation then raise exception 'already_at_table';
end $$;

-- 일어나기. 진행 중인 판이면 그 자리는 폴드(낸 칩은 판돈에 남음). 사람이 다 나가면 판이 끝나는 대로 닫힌다
create function public.ip_leave(p_table bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t_now timestamptz;
  h ip_hands;
  s ip_hand_seats;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(hashtext('ip:' || p_table));
  t_now := clock_timestamp();
  perform ip_advance(p_table, t_now);

  update ip_members set left_at = t_now, left_reason = 'leave'
  where table_id = p_table and player_id = me and left_at is null;
  if not found then return ip_state(p_table, me); end if;

  select * into h from ip_hands where table_id = p_table order by hand_no desc limit 1;
  if h.phase = 'betting' then
    select * into s from ip_hand_seats where hand_id = h.id and player_id = me;
    if found and not s.folded then
      update ip_hand_seats set folded = true, acted = true, last_action = 'leave', last_amount = 0
      where hand_id = h.id and seat = s.seat;
      if h.turn_seat = s.seat then
        perform ip_next_turn(h.id, t_now);
      elsif ip_should_end(h.id) then
        -- 차례 밖 이탈도 다음 차례와 같은 판정: 더 행동할 사람이 없으면 바로 공개
        perform ip_settle(h.id, t_now);
      end if;
    end if;
  end if;

  -- 사람이 아무도 없고 진행 중인 판도 없으면 바로 닫는다
  if not exists (select 1 from ip_members where table_id = p_table and left_at is null)
     and not exists (select 1 from ip_hands where table_id = p_table and phase = 'betting') then
    update ip_tables set status = 'closed', closed_at = t_now where id = p_table and status = 'open';
  end if;
  return ip_state(p_table, me);
end $$;

-- 마감이 지난 일을 처리하고 지금 테이블 전부를 받는다
create function public.ip_tick(p_table bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(hashtext('ip:' || p_table));
  perform ip_advance(p_table, clock_timestamp());
  return ip_state(p_table, me);
end $$;

-- 내 차례 행동: check | bet | call | raise | fold. bet·raise의 p_amount는 지금 베팅 위로 올리는 칩.
-- p_hand·p_turn은 행동하려는 판 ID와 차례 번호(ip_state의 hand.id, hand.turn_no). 다르면 지연·재시도된 요청이라 거절.
-- 마감 판단은 잠금을 잡은 뒤의 clock_timestamp(). 먼저 밀린 일(시간 초과 폴드 등)을 정산하고,
-- 행동이 안 되면 예외 대신 그 상태에 rejected 코드를 붙여 돌려준다 → 정산은 커밋되고 앱은 바로 새 상태를 그린다.
--   rejected: stale_turn(지난 판·차례) / not_your_turn / not_started(딜 연출 2초 중) / ip_apply의 규칙 코드
create function public.ip_action(p_table bigint, p_hand bigint, p_turn int, p_action text, p_amount bigint default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t_now timestamptz;
  h ip_hands;
  my_seat smallint;
  code text;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if p_action is null or p_action not in ('check', 'bet', 'call', 'raise', 'fold') then raise exception 'invalid_action'; end if;
  perform pg_advisory_xact_lock(hashtext('ip:' || p_table));
  t_now := clock_timestamp();
  perform ip_advance(p_table, t_now);

  select * into h from ip_hands where table_id = p_table order by hand_no desc limit 1;
  if h.id is not null then
    select seat into my_seat from ip_hand_seats where hand_id = h.id and player_id = me;
  end if;

  if h.id is null or h.id is distinct from p_hand or h.turn_no is distinct from p_turn or h.phase <> 'betting' then
    code := 'stale_turn';
  elsif my_seat is null or h.turn_seat is distinct from my_seat then
    code := 'not_your_turn';
  elsif t_now < h.turn_started_at then
    code := 'not_started';
  else
    begin
      perform ip_apply(h.id, my_seat, p_action, p_amount, t_now);
    exception when raise_exception then
      code := sqlerrm;
    end;
  end if;

  return ip_state(p_table, me) || jsonb_build_object('rejected', code);
end $$;

-- ============================================================
-- 이번 주 큰손에 인디언 포커도 (ADR-0012). 한 판 = 지급 − 낸 칩(앤티 포함). 컴퓨터 자리는 빼고
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
  where payout is not null
  union all
  select player_id, 'plinko', payout - case when golden then 0 else amount end, created_at
  from public.plinko_drops
  union all
  select player_id, 'indian_poker', payout - put, created_at
  from public.ip_hand_seats
  where player_id is not null and payout is not null;

revoke all on public.game_results from public, anon, authenticated;

-- ============================================================
-- 권한: 클라이언트는 ip_lobby · ip_create · ip_join · ip_leave · ip_tick · ip_action만
-- ============================================================
revoke execute on function public.ip_settle(bigint, timestamptz)                        from public, anon, authenticated;
revoke execute on function public.ip_next_turn(bigint, timestamptz)                     from public, anon, authenticated;
revoke execute on function public.ip_apply(bigint, smallint, text, bigint, timestamptz) from public, anon, authenticated;
revoke execute on function public.ip_decide(bigint, smallint)                           from public, anon, authenticated;
revoke execute on function public.ip_start_hand(bigint, timestamptz)                    from public, anon, authenticated;
revoke execute on function public.ip_advance(bigint, timestamptz)                       from public, anon, authenticated;
revoke execute on function public.ip_state(bigint, uuid)                                from public, anon, authenticated;
revoke execute on function public.ip_lobby()                                            from public, anon;
revoke execute on function public.ip_create(int)                                        from public, anon;
revoke execute on function public.ip_join(bigint)                                       from public, anon;
revoke execute on function public.ip_leave(bigint)                                      from public, anon;
revoke execute on function public.ip_tick(bigint)                                       from public, anon;
revoke execute on function public.ip_should_end(bigint)                                 from public, anon, authenticated;
revoke execute on function public.ip_action(bigint, bigint, int, text, bigint)          from public, anon;
grant  execute on function public.ip_lobby()                                            to authenticated;
grant  execute on function public.ip_create(int)                                        to authenticated;
grant  execute on function public.ip_join(bigint)                                       to authenticated;
grant  execute on function public.ip_leave(bigint)                                      to authenticated;
grant  execute on function public.ip_tick(bigint)                                       to authenticated;
grant  execute on function public.ip_action(bigint, bigint, int, text, bigint)          to authenticated;

alter publication supabase_realtime add table public.ip_tables, public.ip_members, public.ip_hands, public.ip_hand_seats;
