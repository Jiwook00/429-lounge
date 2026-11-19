-- 429 Lounge: 플레이어 지갑 + 구슬 홀짝 테이블 (프로토타입)
--
-- 원칙
--  - 결과(구슬 개수)와 칩 증감은 전부 서버(이 함수들)에서만 일어난다.
--    테이블은 RLS로 읽기만 열고, 쓰기는 security definer 함수로만.
--  - 크론/서버 프로세스 없이 "지연 정산": 테이블에 앉은 클라이언트가
--    마감 시각에 oddeven_tick()을 부르면 그때 정산하고 다음 판을 연다.

-- ============================================================
-- 플레이어
-- ============================================================
create table public.players (
  id         uuid primary key references auth.users (id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 16),
  chips      bigint not null default 1000 check (chips >= 0),
  created_at timestamptz not null default now()
);

-- ============================================================
-- 방 / 홀짝 라운드 / 베팅
-- ============================================================
create table public.rooms (
  code       text primary key check (code ~ '^[A-Z0-9]{4,8}$'),
  created_at timestamptz not null default now()
);

create table public.oddeven_rounds (
  id         bigint generated always as identity primary key,
  room_code  text not null references public.rooms (code) on delete cascade,
  opens_at   timestamptz not null,
  closes_at  timestamptz not null,
  marbles    smallint check (marbles between 1 and 12), -- 정산 전엔 null (클라이언트에 결과가 새지 않음)
  settled_at timestamptz
);
create index oddeven_rounds_room_idx on public.oddeven_rounds (room_code, id desc);

create table public.oddeven_bets (
  round_id   bigint not null references public.oddeven_rounds (id) on delete cascade,
  room_code  text not null, -- Realtime 필터용 비정규화
  player_id  uuid not null references public.players (id) on delete cascade,
  side       text not null check (side in ('odd', 'even')),
  amount     bigint not null check (amount > 0),
  payout     bigint, -- 정산 후 채워짐 (0 = 짐)
  created_at timestamptz not null default now(),
  primary key (round_id, player_id)
);
create index oddeven_bets_room_idx on public.oddeven_bets (room_code);

-- ============================================================
-- RLS: 로그인한 사용자(익명 포함)는 읽기만
-- ============================================================
alter table public.players        enable row level security;
alter table public.rooms          enable row level security;
alter table public.oddeven_rounds enable row level security;
alter table public.oddeven_bets   enable row level security;

create policy "read players" on public.players        for select to authenticated using (true);
create policy "read rooms"   on public.rooms          for select to authenticated using (true);
create policy "read rounds"  on public.oddeven_rounds for select to authenticated using (true);
create policy "read bets"    on public.oddeven_bets   for select to authenticated using (true);

-- ============================================================
-- 함수
-- ============================================================

-- 내 플레이어 행을 만들거나 이름을 바꾼다.
create function public.ensure_player(p_name text)
returns public.players
language plpgsql security definer set search_path = public as $$
declare
  me public.players;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into players (id, name) values (auth.uid(), p_name)
  on conflict (id) do update set name = excluded.name
  returning * into me;
  return me;
end $$;

-- 방의 현재 라운드를 돌려준다. 마감된 라운드가 있으면 정산하고 다음 판을 연다.
create function public.oddeven_tick(p_room text)
returns public.oddeven_rounds
language plpgsql security definer set search_path = public as $$
declare
  betting constant interval := interval '15 seconds';
  reveal  constant interval := interval '5 seconds'; -- 결과 연출 시간
  r public.oddeven_rounds;
  starts timestamptz;
begin
  -- 같은 방의 tick/bet을 직렬화
  perform pg_advisory_xact_lock(hashtext('oddeven:' || p_room));
  insert into rooms (code) values (p_room) on conflict do nothing;

  select * into r from oddeven_rounds where room_code = p_room order by id desc limit 1;

  if not found then
    insert into oddeven_rounds (room_code, opens_at, closes_at)
    values (p_room, now(), now() + betting)
    returning * into r;
    return r;
  end if;

  if r.settled_at is null then
    if now() < r.closes_at then
      return r; -- 진행 중 (또는 오픈 대기 중)
    end if;

    -- 정산: 구슬 1~12개
    update oddeven_rounds
    set marbles = 1 + floor(random() * 12)::int, settled_at = now()
    where id = r.id
    returning * into r;

    update oddeven_bets b
    set payout = case when (r.marbles % 2 = 1) = (b.side = 'odd') then b.amount * 2 else 0 end
    where b.round_id = r.id;

    update players p
    set chips = p.chips + b.payout
    from oddeven_bets b
    where b.round_id = r.id and b.player_id = p.id and b.payout > 0;
  end if;

  -- 다음 판: 직전 판 마감 + 연출 시간 뒤에 오픈 (방이 오래 비었으면 지금부터)
  starts := greatest(now(), r.closes_at + reveal);
  insert into oddeven_rounds (room_code, opens_at, closes_at)
  values (p_room, starts, starts + betting)
  returning * into r;
  return r;
end $$;

-- 현재 라운드에 베팅. 한 판에 한 번만.
create function public.oddeven_bet(p_room text, p_side text, p_amount bigint)
returns public.oddeven_bets
language plpgsql security definer set search_path = public as $$
declare
  r public.oddeven_rounds;
  bet public.oddeven_bets;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount'; end if;

  r := oddeven_tick(p_room);
  if now() < r.opens_at or now() >= r.closes_at then
    raise exception 'betting_closed';
  end if;

  update players set chips = chips - p_amount
  where id = auth.uid() and chips >= p_amount;
  if not found then raise exception 'insufficient_chips'; end if;

  insert into oddeven_bets (round_id, room_code, player_id, side, amount)
  values (r.id, p_room, auth.uid(), p_side, p_amount)
  returning * into bet;
  return bet;
exception
  when unique_violation then raise exception 'already_bet';
end $$;

revoke execute on function public.ensure_player(text)                from public, anon;
revoke execute on function public.oddeven_tick(text)                 from public, anon;
revoke execute on function public.oddeven_bet(text, text, bigint)    from public, anon;
grant  execute on function public.ensure_player(text)                to authenticated;
grant  execute on function public.oddeven_tick(text)                 to authenticated;
grant  execute on function public.oddeven_bet(text, text, bigint)    to authenticated;

-- ============================================================
-- Realtime
-- ============================================================
alter publication supabase_realtime add table public.players, public.oddeven_rounds, public.oddeven_bets;
