-- 블랙잭: 딜러 1 + 좌석 4, 좌석별 순차 턴 (ADR-0014, docs/chip-economy.md)
--
-- 룰: 히트 / 스탠드 / 더블다운(첫 두 장)만. 블랙잭 3:2, 딜러는 17 이상이면 멈춤(소프트 17 포함),
--     무한 덱(매 장 무작위), 스플릿·인슈어런스 없음.
--     딜러 홀 카드 없음: 처음엔 한 장만, 두 번째 장은 딜러 차례에 뽑는다. 아직 안 뽑은 카드는
--     어디에도 없으니 읽기 전용 테이블에서 결과가 새지 않는다. 딜러가 블랙잭이면 더블한 칩도 진다.
-- 진행: 첫 베팅 → 10초 베팅 창(혼자면 bj_deal로 바로) → 빈 자리는 AI 봇 → 1번 자리부터 순서대로
--       사람 11초(행동마다 다시 11초, 시간 초과 = 스탠드), 봇은 연출 시간만 → 딜러 → 정산 → 결과 5초.
-- AI 봇은 칩이 없다. 결과(result)는 화면용으로만 남고 payout은 null (순위표에 안 들어감).
-- 지연 정산(ADR-0003): 앉은 클라이언트가 마감 시각마다 bj_tick()을 부른다. 다음 마감은 직전 마감에서
--   이어서 계산해서, 아무도 없던 판은 다음에 누가 tick을 부를 때 한 번에 끝까지 따라잡는다.
-- 카드: 0~51 정수. 무늬 = c / 13 (0 스페이드, 1 하트, 2 다이아, 3 클럽), 숫자 = c % 13 (0 = A, 9~12 = 10 J Q K)

-- ============================================================
-- 테이블
-- ============================================================
create table public.bj_rounds (
  id            bigint generated always as identity primary key,
  room_code     text not null references public.rooms (code) on delete cascade,
  phase         text not null default 'betting' check (phase in ('betting', 'playing', 'dealer', 'done')),
  bet_closes_at timestamptz not null,
  turn_seat     smallint check (turn_seat between 1 and 4), -- null = 딜 연출 중 / 딜러 / 끝
  turn_deadline timestamptz,                                -- playing·dealer 단계의 다음 진행 시각
  dealer_cards  smallint[] not null default '{}',
  settled_at    timestamptz,
  next_at       timestamptz,                                -- 결과 연출이 끝나는 시각
  created_at    timestamptz not null default now()
);
create index bj_rounds_room_idx on public.bj_rounds (room_code, id desc);

create table public.bj_seats (
  round_id    bigint not null references public.bj_rounds (id) on delete cascade,
  room_code   text not null, -- Realtime 필터용 비정규화
  seat        smallint not null check (seat between 1 and 4),
  player_id   uuid references public.players (id) on delete cascade, -- null = AI 봇
  bot_name    text,
  amount      bigint not null default 0 check (amount >= 0),
  golden      boolean not null default false,
  doubled     boolean not null default false,
  cards       smallint[] not null default '{}',
  state       text not null default 'waiting' check (state in ('waiting', 'playing', 'stood', 'bust', 'blackjack')),
  last_action text check (last_action in ('hit', 'stand', 'double', 'timeout')),
  result      text check (result in ('win', 'lose', 'push', 'blackjack')),
  payout      bigint, -- 정산 후 채워짐. 봇은 늘 null
  created_at  timestamptz not null default now(),
  primary key (round_id, seat),
  unique (round_id, player_id),
  check ((player_id is null) = (bot_name is not null))
);
create index bj_seats_room_idx on public.bj_seats (room_code);
create index bj_seats_created_idx on public.bj_seats (created_at);

alter table public.bj_rounds enable row level security;
alter table public.bj_seats  enable row level security;
create policy "read bj rounds" on public.bj_rounds for select to authenticated using (true);
create policy "read bj seats"  on public.bj_seats  for select to authenticated using (true);

-- ============================================================
-- 카드 계산
-- ============================================================
create function public.bj_total(cards smallint[])
returns int
language plpgsql immutable set search_path = public as $$
declare
  t int := 0;
  aces int := 0;
  c smallint;
  r int;
begin
  foreach c in array coalesce(cards, '{}'::smallint[]) loop
    r := c % 13;
    t := t + case when r = 0 then 11 when r >= 9 then 10 else r + 1 end;
    if r = 0 then aces := aces + 1; end if;
  end loop;
  while t > 21 and aces > 0 loop t := t - 10; aces := aces - 1; end loop;
  return t;
end $$;

create function public.bj_draw()
returns smallint
language sql volatile as $$ select floor(random() * 52)::smallint $$;

-- ============================================================
-- 진행 (내부용)
-- ============================================================

-- 베팅 마감: 빈 자리에 봇을 앉히고 두 장씩, 딜러는 한 장
create function public.bj_start(p_round bigint, p_base timestamptz)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r bj_rounds;
  names text[] := array['빌드봇', '린트봇', '캐시봇', '커밋봇', '핫픽스봇', '디버그봇'];
  picked text[] := '{}';
  n text;
  i int;
begin
  select * into r from bj_rounds where id = p_round for update;
  for i in 1..4 loop
    if not exists (select 1 from bj_seats where round_id = r.id and seat = i) then
      select x into n from unnest(names) x where not (x = any(picked)) order by random() limit 1;
      picked := picked || n;
      insert into bj_seats (round_id, room_code, seat, bot_name) values (r.id, r.room_code, i, n);
    end if;
  end loop;

  update bj_seats set cards = array[bj_draw(), bj_draw()] where round_id = r.id;
  update bj_seats set state = case when bj_total(cards) = 21 then 'blackjack' else 'playing' end where round_id = r.id;

  -- 딜 연출(카드 9장) 시간 뒤에 첫 차례
  update bj_rounds
  set phase = 'playing', dealer_cards = array[bj_draw()], turn_seat = null,
      turn_deadline = p_base + interval '3 seconds'
  where id = r.id;
end $$;

-- 다음 차례로. 봇은 그 자리에서 다 치고 연출 시간만 준다. 남은 자리가 없으면 딜러
create function public.bj_advance(p_round bigint, p_base timestamptz)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r bj_rounds;
  s bj_seats;
  dc smallint[];
  draws int := 0;
begin
  select * into r from bj_rounds where id = p_round for update;
  select * into s from bj_seats
  where round_id = r.id and seat > coalesce(r.turn_seat, 0) and state = 'playing'
  order by seat limit 1;

  if found then
    if s.player_id is null then
      dc := s.cards;
      while bj_total(dc) < 17 loop dc := dc || bj_draw(); draws := draws + 1; end loop;
      update bj_seats
      set cards = dc, state = case when bj_total(dc) > 21 then 'bust' else 'stood' end,
          last_action = case when draws > 0 then 'hit' else 'stand' end
      where round_id = r.id and seat = s.seat;
      update bj_rounds
      set turn_seat = s.seat, turn_deadline = p_base + interval '0.9 seconds' + draws * interval '0.6 seconds'
      where id = r.id;
    else
      update bj_rounds set turn_seat = s.seat, turn_deadline = p_base + interval '11 seconds' where id = r.id;
    end if;
    return;
  end if;

  -- 딜러: 두 번째 장부터 17 이상이 될 때까지
  dc := r.dealer_cards;
  while bj_total(dc) < 17 loop dc := dc || bj_draw(); draws := draws + 1; end loop;
  update bj_rounds
  set phase = 'dealer', turn_seat = null, dealer_cards = dc,
      turn_deadline = p_base + interval '1 second' + draws * interval '0.6 seconds'
  where id = r.id;
end $$;

-- 정산. 지급액은 건 칩 포함 (홀짝·슬롯과 같음)
create function public.bj_settle(p_round bigint, p_base timestamptz)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r bj_rounds;
  dt int;
  dbj boolean;
begin
  select * into r from bj_rounds where id = p_round for update;
  dt := bj_total(r.dealer_cards);
  dbj := dt = 21 and cardinality(r.dealer_cards) = 2;

  update bj_seats s set result = case
      when s.state = 'bust' then 'lose'
      when s.state = 'blackjack' then case when dbj then 'push' else 'blackjack' end
      when dbj then 'lose'
      when dt > 21 or bj_total(s.cards) > dt then 'win'
      when bj_total(s.cards) = dt then 'push'
      else 'lose' end
  where s.round_id = r.id;

  update bj_seats s set payout = case s.result
      when 'blackjack' then s.amount + s.amount * 3 / 2
      when 'win' then s.amount * (case when s.doubled then 2 else 1 end) * 2
      when 'push' then case when s.golden then 0 else s.amount * (case when s.doubled then 2 else 1 end) end
      else 0 end
  where s.round_id = r.id and s.player_id is not null;

  update players p set chips = p.chips + s.payout
  from bj_seats s
  where s.round_id = r.id and s.player_id = p.id and s.payout > 0;

  -- 황금 칩 무승부: 칩 대신 황금 칩을 돌려준다 (아직 유효할 때만)
  update players p set golden_chips = p.golden_chips + 1
  from bj_seats s
  where s.round_id = r.id and s.player_id = p.id and s.golden and s.result = 'push' and p.golden_until > now();

  update bj_rounds
  set phase = 'done', settled_at = now(), turn_seat = null, turn_deadline = null,
      next_at = p_base + interval '5 seconds'
  where id = r.id;
end $$;

-- 화면에 필요한 전부: 라운드 + 좌석(이름, 합계)
create function public.bj_state(p_room text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r bj_rounds;
begin
  select * into r from bj_rounds where room_code = p_room order by id desc limit 1;
  if not found then
    return jsonb_build_object('now', now(), 'round', null, 'seats', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'now', now(),
    'round', to_jsonb(r) || jsonb_build_object('dealer_total', bj_total(r.dealer_cards)),
    'seats', coalesce((
      select jsonb_agg(jsonb_build_object(
          'seat', s.seat, 'player_id', s.player_id, 'name', coalesce(p.name, s.bot_name), 'bot', s.player_id is null,
          'amount', s.amount, 'golden', s.golden, 'doubled', s.doubled, 'cards', to_jsonb(s.cards),
          'total', bj_total(s.cards), 'state', s.state, 'last_action', s.last_action,
          'result', s.result, 'payout', s.payout)
        order by s.seat)
      from bj_seats s left join players p on p.id = s.player_id
      where s.round_id = r.id), '[]'::jsonb));
end $$;

-- ============================================================
-- RPC
-- ============================================================

-- 마감이 지난 단계를 진행하고 지금 상태를 돌려준다. 여러 단계가 밀려 있으면 끝까지 따라잡는다
create function public.bj_tick(p_room text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r bj_rounds;
  steps int := 0;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(hashtext('bj:' || p_room));

  loop
    select * into r from bj_rounds where room_code = p_room order by id desc limit 1;
    exit when not found or steps >= 40;
    steps := steps + 1;
    if r.phase = 'betting' and now() >= r.bet_closes_at then
      perform bj_start(r.id, r.bet_closes_at);
    elsif r.phase = 'playing' and now() >= r.turn_deadline then
      -- 시간 초과면 스탠드 (이미 행동을 끝낸 자리는 그대로)
      update bj_seats set state = 'stood', last_action = 'timeout'
      where round_id = r.id and seat = r.turn_seat and state = 'playing';
      perform bj_advance(r.id, r.turn_deadline);
    elsif r.phase = 'dealer' and now() >= r.turn_deadline then
      perform bj_settle(r.id, r.turn_deadline);
    else
      exit;
    end if;
  end loop;

  return bj_state(p_room);
end $$;

-- 자리에 앉아 건다. 판이 없거나 끝났으면 새 판(10초 베팅 창)을 연다
create function public.bj_bet(p_room text, p_amount bigint, p_golden boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r bj_rounds;
  amount bigint := case when p_golden then 100 else p_amount end;
  free int;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if amount is null or amount <= 0 then raise exception 'invalid_amount'; end if;
  if not exists (select 1 from players where id = me and named) then raise exception 'not_named'; end if;

  perform bj_tick(p_room);
  select * into r from bj_rounds where room_code = p_room order by id desc limit 1;

  if not found or r.phase = 'done' then
    insert into rooms (code) values (p_room) on conflict do nothing;
    -- 직전 판 결과 연출이 끝난 뒤부터 10초
    insert into bj_rounds (room_code, bet_closes_at)
    values (p_room, greatest(now(), coalesce(r.next_at, now())) + interval '10 seconds')
    returning * into r;
  elsif r.phase <> 'betting' then
    raise exception 'betting_closed';
  end if;

  if exists (select 1 from bj_seats where round_id = r.id and player_id = me) then raise exception 'already_bet'; end if;
  select min(i) into free from generate_series(1, 4) i
  where not exists (select 1 from bj_seats where round_id = r.id and seat = i);
  if free is null then raise exception 'table_full'; end if;

  if p_golden then
    update players set golden_chips = golden_chips - 1
    where id = me and golden_chips > 0 and golden_until > now();
    if not found then raise exception 'no_golden'; end if;
  else
    update players set chips = chips - amount where id = me and chips >= amount;
    if not found then raise exception 'insufficient_chips'; end if;
  end if;

  insert into bj_seats (round_id, room_code, seat, player_id, amount, golden)
  values (r.id, p_room, free, me, amount, p_golden);
  return bj_state(p_room);
exception
  when unique_violation then raise exception 'already_bet';
end $$;

-- 혼자 앉아 있으면 베팅 창을 기다리지 않고 바로 딜
create function public.bj_deal(p_room text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r bj_rounds;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  perform bj_tick(p_room);
  select * into r from bj_rounds where room_code = p_room order by id desc limit 1;
  if not found or r.phase <> 'betting' then raise exception 'betting_closed'; end if;
  if not exists (select 1 from bj_seats where round_id = r.id and player_id = me) then raise exception 'not_seated'; end if;
  if exists (select 1 from bj_seats where round_id = r.id and player_id is distinct from me) then raise exception 'not_alone'; end if;

  update bj_rounds set bet_closes_at = now() where id = r.id and bet_closes_at > now();
  return bj_tick(p_room);
end $$;

-- 내 차례 행동: hit | stand | double
create function public.bj_action(p_room text, p_action text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r bj_rounds;
  s bj_seats;
  t int;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if p_action not in ('hit', 'stand', 'double') then raise exception 'invalid_action'; end if;

  perform bj_tick(p_room);
  select * into r from bj_rounds where room_code = p_room order by id desc limit 1;
  if not found or r.phase <> 'playing' or r.turn_seat is null then raise exception 'not_your_turn'; end if;
  select * into s from bj_seats where round_id = r.id and seat = r.turn_seat;
  if s.player_id is distinct from me or s.state <> 'playing' then raise exception 'not_your_turn'; end if;

  if p_action = 'hit' then
    update bj_seats set cards = cards || bj_draw(), last_action = 'hit'
    where round_id = r.id and seat = s.seat returning * into s;
    t := bj_total(s.cards);
    if t >= 21 then
      update bj_seats set state = case when t > 21 then 'bust' else 'stood' end where round_id = r.id and seat = s.seat;
      update bj_rounds set turn_deadline = now() + interval '0.8 seconds' where id = r.id;
    else
      update bj_rounds set turn_deadline = now() + interval '11 seconds' where id = r.id;
    end if;
  elsif p_action = 'stand' then
    update bj_seats set state = 'stood', last_action = 'stand' where round_id = r.id and seat = s.seat;
    update bj_rounds set turn_deadline = now() + interval '0.5 seconds' where id = r.id;
  else
    if cardinality(s.cards) <> 2 or s.golden then raise exception 'cannot_double'; end if;
    update players set chips = chips - s.amount where id = me and chips >= s.amount;
    if not found then raise exception 'insufficient_chips'; end if;
    update bj_seats set doubled = true, cards = cards || bj_draw(), last_action = 'double'
    where round_id = r.id and seat = s.seat returning * into s;
    update bj_seats set state = case when bj_total(s.cards) > 21 then 'bust' else 'stood' end
    where round_id = r.id and seat = s.seat;
    update bj_rounds set turn_deadline = now() + interval '0.9 seconds' where id = r.id;
  end if;

  return bj_state(p_room);
end $$;

-- 라운지 타일용: 지금 판에 앉은 회원 수 (AI 제외). 10분 넘게 멈춘 판은 0
create function public.bj_seated(p_room text)
returns int
language sql stable security definer set search_path = public as $$
  select coalesce((
    select count(*)::int from bj_seats s
    where s.round_id = r.id and s.player_id is not null
  ), 0)
  from (select * from bj_rounds where room_code = p_room order by id desc limit 1) r
  where r.created_at > now() - interval '10 minutes'
    and (r.phase <> 'done' or r.next_at > now())
$$;

-- ============================================================
-- 전광판: 블랙잭 지급 1,000칩 이상이면 빅 윈 (홀짝과 같은 기준)
-- ============================================================
alter table public.lounge_events drop constraint lounge_events_game_check;
alter table public.lounge_events add constraint lounge_events_game_check check (game in ('slot', 'oddeven', 'blackjack'));

create function public.bj_seat_event()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.player_id is not null and new.payout >= 1000 and old.payout is null then
    insert into lounge_events (kind, game, player_id, name, amount)
    select 'bigwin', 'blackjack', p.id, p.name, new.payout
    from players p where p.id = new.player_id;
  end if;
  return new;
end $$;

create trigger bj_seat_event after update of payout on public.bj_seats
for each row execute function public.bj_seat_event();

-- ============================================================
-- 이번 주 큰손에 블랙잭도 (ADR-0012). 건 칩 = 더블이면 두 배, 황금 칩은 0
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
  where player_id is not null and payout is not null;

revoke all on public.game_results from public, anon, authenticated;

-- ============================================================
-- 권한
-- ============================================================
revoke execute on function public.bj_total(smallint[])                from public, anon;
revoke execute on function public.bj_draw()                           from public, anon, authenticated;
revoke execute on function public.bj_start(bigint, timestamptz)       from public, anon, authenticated;
revoke execute on function public.bj_advance(bigint, timestamptz)     from public, anon, authenticated;
revoke execute on function public.bj_settle(bigint, timestamptz)      from public, anon, authenticated;
revoke execute on function public.bj_state(text)                      from public, anon, authenticated;
revoke execute on function public.bj_seat_event()                     from public, anon, authenticated;
revoke execute on function public.bj_tick(text)                       from public, anon;
revoke execute on function public.bj_bet(text, bigint, boolean)       from public, anon;
revoke execute on function public.bj_deal(text)                       from public, anon;
revoke execute on function public.bj_action(text, text)               from public, anon;
revoke execute on function public.bj_seated(text)                     from public, anon;
grant  execute on function public.bj_total(smallint[])                to authenticated;
grant  execute on function public.bj_tick(text)                       to authenticated;
grant  execute on function public.bj_bet(text, bigint, boolean)       to authenticated;
grant  execute on function public.bj_deal(text)                       to authenticated;
grant  execute on function public.bj_action(text, text)               to authenticated;
grant  execute on function public.bj_seated(text)                     to authenticated;

alter publication supabase_realtime add table public.bj_rounds, public.bj_seats;
