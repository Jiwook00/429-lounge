-- 429 드롭 (ADR-0018): 12줄 격자 플링코 + 스타트 포켓 + FEVER.
--
-- 공 하나 = plinko_drop 한 번. 서버가 줄마다 왼쪽·오른쪽을 정해 경로 전체를 돌려주고, 클라이언트는 재생만 한다.
-- 칸 번호 j: 줄 r의 핀은 j = -(r+2), -r, ..., r+2 (짝수 간격). 공은 줄 r에서 j±1로 다음 줄에 간다.
-- 수치의 원본은 scripts/drop_ev.py (DP로 환수율을 정확히 계산). 바꾸면 docs/chip-economy.md도 같이.

create table public.plinko_drops (
  id         bigint generated always as identity primary key,
  player_id  uuid not null references public.players (id) on delete cascade,
  amount     bigint not null check (amount > 0), -- 황금 칩이면 100
  golden     boolean not null default false,
  lane       smallint not null check (lane between -1 and 1),
  power      smallint not null check (power between 0 and 1000),
  grade      text not null check (grade in ('none', 'good', 'perfect')),
  pocket     boolean not null default false,
  fever      boolean not null default false,
  top_mult   numeric not null, -- 이번 공(분열·FEVER 포함) 중 가장 큰 배수
  payout     bigint not null,
  result     jsonb not null,
  created_at timestamptz not null default now()
);
create index plinko_drops_player_idx on public.plinko_drops (player_id, created_at desc);

alter table public.plinko_drops enable row level security;
create policy "read own drops" on public.plinko_drops for select to authenticated using (player_id = auth.uid());

-- ============================================================
-- 규칙 (scripts/drop_ev.py와 같은 값)
-- ============================================================

-- 칸 0~12의 배수 (건 칩 포함)
create function public.plinko_bucket(p_idx int)
returns numeric
language sql immutable as $$
  select (array[16, 4, 1.8, 1.3, 1.0, 0.6, 0.4, 0.6, 1.0, 1.3, 1.8, 4, 16]::numeric[])[p_idx + 1]
$$;

-- 게이지 24칸 중 뗀 칸: 가운데(20번) PERFECT, 18·19·21·22번 GOOD. 파워는 0~1000
create function public.plinko_grade(p_power int)
returns text
language sql immutable as $$
  select case least(23, (p_power * 24) / 1000)
    when 20 then 'perfect'
    when 18 then 'good' when 19 then 'good' when 21 then 'good' when 22 then 'good'
    else 'none' end
$$;

-- 등급별로 포켓이 공을 잡을 확률. 환수율 98 / 98.5 / 99%
create function public.plinko_catch(p_grade text)
returns numeric
language sql immutable as $$
  select case p_grade when 'perfect' then 0.1068 when 'good' then 0.1008 else 0.0947 end
$$;

-- 공 하나의 경로. (p_row, p_j) 핀에서 출발해 칸에 떨어지거나 포켓에 잡힐 때까지.
-- 반환: from(첫 줄), js(줄마다 맞은 핀의 j), bucket(칸, 포켓이면 null), gold(골드 보너스 합),
--       mult, payout, pocket, split(분열한 줄), clone(분열로 생긴 공, 같은 모양)
create function public.plinko_path(
  p_j int, p_row int, p_fever boolean, p_catch numeric, p_split_used boolean, p_gold numeric, p_amount bigint
) returns jsonb
language plpgsql volatile as $$
declare
  r int := p_row;
  j int := p_j;
  js int[] := '{}';
  gold numeric := p_gold;
  used boolean := p_split_used;
  d int;
  jf int;
  split_row int;
  clone jsonb;
  m numeric;
begin
  loop
    js := js || j;
    if r = 6 and j = 0 and not p_fever and random() < p_catch then
      return jsonb_build_object('from', p_row, 'js', to_jsonb(js), 'bucket', null, 'gold', gold,
        'mult', 0, 'payout', 0, 'pocket', true, 'split', split_row, 'clone', clone);
    end if;
    if r = 8 and j in (4, -4) then gold := gold + 0.3; end if;
    d := case when random() < 0.5 then 1 else -1 end;
    if r = 10 and j in (8, -8) and not used and not p_fever then
      used := true;
      split_row := r;
      clone := plinko_path(j - d, r + 1, p_fever, p_catch, true, gold, p_amount);
    end if;
    if r = 11 then
      jf := j + d;
      if jf > 12 then jf := j - 1; end if;
      if jf < -12 then jf := j + 1; end if;
      m := plinko_bucket((jf + 12) / 2) * (case when p_fever then 2 else 1 end) + gold;
      return jsonb_build_object('from', p_row, 'js', to_jsonb(js), 'bucket', (jf + 12) / 2, 'gold', gold,
        'mult', m, 'payout', floor(p_amount * m)::bigint, 'pocket', false, 'split', split_row, 'clone', clone);
    end if;
    r := r + 1;
    j := j + d;
  end loop;
end $$;

-- 레인에서 공 하나. 옆 레인은 입구 가이드 핀 (0, ±2)이 안쪽 (1, ∓1)로 민다 → 경로는 1줄부터
create function public.plinko_launch(p_lane int, p_fever boolean, p_catch numeric, p_amount bigint)
returns jsonb
language sql volatile as $$
  select case when p_lane = 0
    then plinko_path(0, 0, p_fever, p_catch, false, 0, p_amount)
    else plinko_path(-p_lane, 1, p_fever, p_catch, false, 0, p_amount) end
$$;

-- 지갑과 무관한 한 판 결과 (plinko_drop과 plinko_sim이 같이 쓴다)
create function public.plinko_resolve(p_amount bigint, p_lane int, p_grade text)
returns jsonb
language plpgsql volatile as $$
declare
  ball jsonb;
  total bigint;
  top numeric;
  pocket jsonb;
  fever_balls jsonb := '[]'::jsonb;
  syms constant text[] := array['429', '7', 'BAR', '200', '404'];
  is_fever boolean := false;
  reels text[];
  refund bigint := 0;
  fb jsonb;
begin
  ball := plinko_launch(p_lane, false, plinko_catch(p_grade), p_amount);
  total := (ball->>'payout')::bigint + coalesce((ball->'clone'->>'payout')::bigint, 0);
  top := greatest((ball->>'mult')::numeric, coalesce((ball->'clone'->>'mult')::numeric, 0));

  -- 분열 핀(10줄)이 포켓(6줄)보다 아래라 포켓은 한 판에 많아야 한 번
  if (ball->>'pocket')::boolean then
    is_fever := random() < 0.125;
    if is_fever then
      reels := array['429', '429', '429'];
      for i in 1..15 loop
        fb := plinko_launch(floor(random() * 3)::int - 1, true, 0, p_amount);
        fever_balls := fever_balls || fb;
        total := total + (fb->>'payout')::bigint;
        top := greatest(top, (fb->>'mult')::numeric);
      end loop;
    else
      -- 연출용 릴. 429 둘이면 리치. 셋 다 429는 FEVER일 때만
      reels := array[
        case when random() < 0.4 then '429' else syms[1 + floor(random() * 5)::int] end,
        '429',
        syms[2 + floor(random() * 4)::int]];
      if reels[1] <> '429' then reels[2] := syms[1 + floor(random() * 5)::int]; end if;
      refund := floor(p_amount * 0.2)::bigint;
      total := total + refund;
    end if;
    pocket := jsonb_build_object('reels', to_jsonb(reels), 'fever', is_fever, 'refund', refund);
  end if;

  return jsonb_build_object('ball', ball, 'pocket', pocket, 'fever_balls', fever_balls,
    'payout', total, 'top_mult', top, 'fever', is_fever);
end $$;

-- ============================================================
-- 던지기
-- ============================================================
create function public.plinko_drop(p_amount bigint, p_lane int, p_power int, p_golden boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  amount bigint := case when p_golden then 100 else p_amount end;
  lane int := greatest(-1, least(1, coalesce(p_lane, 0)));
  power int := greatest(0, least(1000, coalesce(p_power, 0)));
  grade text := plinko_grade(power);
  res jsonb;
  pay bigint;
  player_row players;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from players where id = me and named) then raise exception 'not_named'; end if;
  if amount is null or amount not between 1 and 200 then raise exception 'invalid_amount'; end if;

  if p_golden then
    update players set golden_chips = golden_chips - 1
    where id = me and golden_chips > 0 and golden_until > now();
    if not found then raise exception 'no_golden'; end if;
  else
    update players set chips = chips - amount
    where id = me and chips >= amount;
    if not found then raise exception 'insufficient_chips'; end if;
  end if;

  res := plinko_resolve(amount, lane, grade);
  pay := (res->>'payout')::bigint;

  update players set chips = chips + pay where id = me returning * into player_row;
  insert into plinko_drops (player_id, amount, golden, lane, power, grade, pocket, fever, top_mult, payout, result)
  values (me, amount, p_golden, lane, power, grade, res->'pocket' is not null and res->'pocket' <> 'null'::jsonb,
          (res->>'fever')::boolean, (res->>'top_mult')::numeric, pay, res);

  return res || jsonb_build_object('lane', lane, 'power', power, 'grade', grade, 'amount', amount,
    'golden', p_golden, 'player', to_jsonb(player_row));
end $$;

-- 로컬 환수율 확인용 (클라이언트는 못 부른다). 반환: 공 n개의 환수율, FEVER 수, 포켓 수
create function public.plinko_sim(p_n int, p_lane int default 0, p_grade text default 'none')
returns jsonb
language plpgsql volatile as $$
declare
  paid numeric := 0;
  fevers int := 0;
  pockets int := 0;
  res jsonb;
begin
  for i in 1..p_n loop
    res := plinko_resolve(100, p_lane, p_grade);
    paid := paid + (res->>'payout')::bigint;
    if (res->>'fever')::boolean then fevers := fevers + 1; end if;
    if res->'pocket' <> 'null'::jsonb then pockets := pockets + 1; end if;
  end loop;
  return jsonb_build_object('n', p_n, 'rtp', round(paid / (p_n * 100.0), 4), 'fevers', fevers, 'pockets', pockets);
end $$;

-- ============================================================
-- 전광판: FEVER로 1,000칩 이상, 또는 ×16 끝 칸이면서 500칩 이상
-- (200칩 공은 분열만으로 1,000칩을 자주 넘어서 지급액만으로는 거르지 않는다)
-- ============================================================
alter table public.lounge_events drop constraint lounge_events_game_check;
alter table public.lounge_events add constraint lounge_events_game_check
  check (game in ('slot', 'oddeven', 'blackjack', 'roulette', 'plinko'));

create function public.plinko_drop_event()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.fever and new.payout >= 1000) or (new.top_mult >= 16 and new.payout >= 500) then
    insert into lounge_events (kind, game, player_id, name, amount)
    select 'bigwin', 'plinko', p.id, p.name, new.payout
    from players p where p.id = new.player_id;
  end if;
  return new;
end $$;

create trigger plinko_drop_event after insert on public.plinko_drops
for each row execute function public.plinko_drop_event();

-- ============================================================
-- 이번 주 큰손에 429 드롭도 (ADR-0012). 공 하나가 한 판. 황금 칩은 건 칩 0
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
  from public.plinko_drops;

revoke all on public.game_results from public, anon, authenticated;

-- ============================================================
-- 권한: 클라이언트는 plinko_drop만
-- ============================================================
revoke execute on function public.plinko_bucket(int)                                              from public, anon, authenticated;
revoke execute on function public.plinko_grade(int)                                               from public, anon, authenticated;
revoke execute on function public.plinko_catch(text)                                              from public, anon, authenticated;
revoke execute on function public.plinko_path(int, int, boolean, numeric, boolean, numeric, bigint) from public, anon, authenticated;
revoke execute on function public.plinko_launch(int, boolean, numeric, bigint)                    from public, anon, authenticated;
revoke execute on function public.plinko_resolve(bigint, int, text)                               from public, anon, authenticated;
revoke execute on function public.plinko_sim(int, int, text)                                      from public, anon, authenticated;
revoke execute on function public.plinko_drop_event()                                             from public, anon, authenticated;
revoke execute on function public.plinko_drop(bigint, int, int, boolean)                          from public, anon;
grant  execute on function public.plinko_drop(bigint, int, int, boolean)                          to authenticated;
