-- 이미 열린 소수결은 200칩, 새로 열리는 판은 50칩으로 고정한다.
-- 과거 결과는 각 회원이 실제로 낸 참가비를 돌려준다.
alter table public.minority_rounds
  add column stake bigint not null default 200 check (stake > 0);
alter table public.minority_rounds alter column stake set default 50;

create or replace function public.minority_tick()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  slot timestamptz := minority_slot(now());
  q int;
  cur minority_rounds;
  mine record;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(4290);

  -- 지난 판 정산
  for cur in select * from minority_rounds where settled_at is null and closes_at <= now() order by id loop
    perform minority_settle(cur.id);
  end loop;

  -- 지금 판 열기: 안 쓴 질문 중 무작위, 다 썼으면 가장 오래전에 쓴 것
  if slot is not null and not exists (select 1 from minority_rounds where opens_at = slot) then
    select id into q from minority_questions order by used_at nulls first, random() limit 1;
    update minority_questions set used_at = now() where id = q;
    insert into minority_rounds (question_id, opens_at, closes_at) values (q, slot, slot + interval '3 hours');
  end if;

  select * into cur from minority_rounds where opens_at = slot and settled_at is null;

  -- 내가 참가한 가장 최근 정산된 판 (결과 알림, 쉬는 시간 한 줄)
  select r.id, qq.prompt, qq.option_a, qq.option_b, r.winner, r.a_count, r.b_count, mp.choice, mp.amount, mp.payout - mp.amount as net
    into mine
  from minority_picks mp
  join minority_rounds r on r.id = mp.round_id
  join minority_questions qq on qq.id = r.question_id
  where mp.player_id = me and r.settled_at is not null
  order by r.id desc limit 1;

  return jsonb_build_object(
    'round', case when cur.id is null then null else (
      select jsonb_build_object(
        'id', cur.id, 'question', qq.prompt, 'option_a', qq.option_a, 'option_b', qq.option_b,
        'closes_at', cur.closes_at, 'stake', cur.stake,
        'participants', (select count(*) from minority_picks where round_id = cur.id),
        'my_pick', (select choice from minority_picks where round_id = cur.id and player_id = me))
      from minority_questions qq where qq.id = cur.question_id) end,
    'next_opens_at', minority_next_open(now()),
    'mine', case when mine.id is null then null else jsonb_build_object(
      'id', mine.id, 'question', mine.prompt, 'option_a', mine.option_a, 'option_b', mine.option_b,
      'winner', mine.winner, 'a_count', mine.a_count, 'b_count', mine.b_count,
      'choice', mine.choice, 'amount', mine.amount, 'net', mine.net,
      'picks', (select jsonb_agg(jsonb_build_object('name', pl.name, 'choice', mp2.choice, 'me', mp2.player_id = me)
                                 order by mp2.created_at)
                from minority_picks mp2 join players pl on pl.id = mp2.player_id
                where mp2.round_id = mine.id)) end
  );
end $$;

create or replace function public.minority_pick(p_choice int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  cur minority_rounds;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if p_choice is null or p_choice not in (0, 1) then raise exception 'invalid_choice'; end if;
  if not exists (select 1 from players where id = me and named) then raise exception 'not_named'; end if;

  perform minority_tick();
  select * into cur from minority_rounds
  where opens_at = minority_slot(now()) and settled_at is null and closes_at > now();
  if cur.id is null then raise exception 'minority_closed'; end if;
  if exists (select 1 from minority_picks where round_id = cur.id and player_id = me) then
    raise exception 'already_picked';
  end if;

  update players set chips = chips - cur.stake where id = me and chips >= cur.stake;
  if not found then raise exception 'insufficient_chips'; end if;

  insert into minority_picks (round_id, player_id, choice, amount) values (cur.id, me, p_choice, cur.stake);
  return minority_tick();
exception
  when unique_violation then raise exception 'already_picked';
end $$;

-- 슬롯의 일반 칩 베팅은 최대 200칩이다.
create or replace function public.slot_spin(p_amount bigint, p_golden boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  base constant text[] := array[
    'cherry','cherry','cherry','cherry','cherry','cherry',
    'bell','bell','bell','bell','bell',
    'bar','bar','bar','bar',
    'seven','seven','seven',
    '429',
    'blank','blank','blank','blank','blank',
    '500','500'
  ];
  amount bigint := case when p_golden then 100 else p_amount end;
  vip boolean;
  strip text[];
  calm text[]; -- 리스핀용: 500 제외
  initial text[] := '{}';
  reels text[] := '{}';
  glitched int[] := '{}';
  sym text;
  mult int;
  pay bigint;
  me players;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if amount is null or amount not between 1 and 200 then raise exception 'invalid_amount'; end if;

  select golden_until > now() into vip from players where id = auth.uid();
  vip := coalesce(vip, false);

  if p_golden then
    update players set golden_chips = golden_chips - 1
    where id = auth.uid() and golden_chips > 0 and golden_until > now();
    if not found then raise exception 'no_golden'; end if;
  else
    update players set chips = chips - amount
    where id = auth.uid() and chips >= amount;
    if not found then raise exception 'insufficient_chips'; end if;
  end if;

  strip := case when vip then base || array['429', 'blank'] else base end;
  calm := array(select s from unnest(strip) s where s <> '500');

  for i in 1..3 loop
    sym := strip[1 + floor(random() * array_length(strip, 1))::int];
    initial := initial || sym;
    if sym = '500' then
      glitched := glitched || i;
      sym := calm[1 + floor(random() * array_length(calm, 1))::int];
    end if;
    reels := reels || sym;
  end loop;

  mult := slot_multiplier(reels);
  pay := amount * mult;

  update players set chips = chips + pay where id = auth.uid() returning * into me;
  insert into slot_spins (player_id, amount, golden, reels, multiplier, payout, initial_reels, glitched, vip)
  values (auth.uid(), amount, p_golden, reels, mult, pay, initial, glitched, vip);

  return jsonb_build_object(
    'reels', reels, 'initial_reels', initial, 'glitched', glitched, 'vip', vip,
    'multiplier', mult, 'payout', pay, 'player', to_jsonb(me)
  );
end $$;

-- 구버전은 소수결 참가비를 200칩으로 표시하고 슬롯에서 500칩을 보낼 수 있다.
update public.client_policy set min_version = '0.11.2';
