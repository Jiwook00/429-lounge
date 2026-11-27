-- 429 드롭 보드 레벨 (ADR-0019): 확정 FEVER 대신, 4·2·9 글자가 켜질수록 보드에 보너스 핀이 늘어난다.
--   레벨 = 켜진 글자 수 0~3 (players.plinko_letters). FEVER가 아닌 포켓마다 한 칸 오르고, HOT(3)은 다음 포켓에서 0으로.
--   FEVER(포켓마다 1/8)가 나도 0으로. FEVER 공은 늘 기본 핀.
--   4: 골드 (6, ±6) / 4·2: 파란 분열 (9, ±7) / 4·2·9 HOT: 골드 (9, ±5), (7, ±3)
-- 금액은 10~200칩 (앱 단위 10 · 50 · 100 · 200). 황금 칩은 그대로 100칩.
-- 환수율(같은 금액, 기본/GOOD/PERFECT): 평소 98.6 / 99.1 / 99.6%, VIP HOUR 105.6 / 106.1 / 106.6%. HOT 레벨만 111.7%.
-- 수치의 원본은 scripts/drop_ev.py.

create function public.plinko_gold(p_r int, p_j int, p_level int)
returns boolean
language sql immutable as $$
  select (p_r = 8 and abs(p_j) = 4)
      or (p_level >= 1 and p_r = 6 and abs(p_j) = 6)
      or (p_level >= 3 and ((p_r = 9 and abs(p_j) = 5) or (p_r = 7 and abs(p_j) = 3)))
$$;

create function public.plinko_split(p_r int, p_j int, p_level int)
returns boolean
language sql immutable as $$
  select (p_r = 10 and abs(p_j) = 8)
      or (p_level >= 2 and p_r = 9 and abs(p_j) = 7)
$$;

create or replace function public.plinko_catch(p_grade text, p_vip boolean)
returns numeric
language sql immutable as $$
  select case p_grade when 'perfect' then 0.0761 when 'good' then 0.0730 else 0.0700 end
       + case when p_vip then 0.0424 else 0 end
$$;

-- 레벨이 경로의 특수 핀을 바꾸므로 시그니처가 바뀐다
drop function public.plinko_launch(int, boolean, numeric, bigint);
drop function public.plinko_path(int, int, boolean, numeric, boolean, numeric, bigint);

create function public.plinko_path(
  p_j int, p_row int, p_fever boolean, p_catch numeric, p_split_used boolean, p_gold numeric, p_amount bigint, p_level int
) returns jsonb
language plpgsql volatile as $$
declare
  r int := p_row;
  j int := p_j;
  js int[] := '{}';
  gold numeric := p_gold;
  used boolean := p_split_used;
  lv int := case when p_fever then 0 else p_level end;
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
    if plinko_gold(r, j, lv) then gold := gold + 0.3; end if;
    d := case when random() < 0.5 then 1 else -1 end;
    if plinko_split(r, j, lv) and not used and not p_fever then
      used := true;
      split_row := r;
      clone := plinko_path(j - d, r + 1, p_fever, p_catch, true, gold, p_amount, lv);
    end if;
    if r = 11 then
      jf := j + d;
      if jf > 12 then jf := j - 1; end if;
      if jf < -12 then jf := j + 1; end if;
      m := plinko_bucket((jf + 12) / 2) * (case when p_fever then 1.5 else 1 end) + gold;
      return jsonb_build_object('from', p_row, 'js', to_jsonb(js), 'bucket', (jf + 12) / 2, 'gold', gold,
        'mult', m, 'payout', floor(p_amount * m)::bigint, 'pocket', false, 'split', split_row, 'clone', clone);
    end if;
    r := r + 1;
    j := j + d;
  end loop;
end $$;

create function public.plinko_launch(p_lane int, p_fever boolean, p_catch numeric, p_amount bigint, p_level int)
returns jsonb
language sql volatile as $$
  select case when p_lane = 0
    then plinko_path(0, 0, p_fever, p_catch, false, 0, p_amount, p_level)
    else plinko_path(p_lane, 1, p_fever, p_catch, false, 0, p_amount, p_level) end
$$;

-- p_letters = 이 판의 보드 레벨(0~3), 반환의 letters = 이 판 뒤 레벨, level = 이 판에 쓴 레벨
create or replace function public.plinko_resolve(p_amount bigint, p_lane int, p_grade text, p_vip boolean, p_letters int)
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
  level int := least(3, greatest(0, p_letters));
  letters int := level;
  reels text[];
  refund bigint := 0;
  fb jsonb;
begin
  ball := plinko_launch(p_lane, false, plinko_catch(p_grade, p_vip), p_amount, level);
  total := (ball->>'payout')::bigint + coalesce((ball->'clone'->>'payout')::bigint, 0);
  top := greatest((ball->>'mult')::numeric, coalesce((ball->'clone'->>'mult')::numeric, 0));
  -- 분열 핀(9·10줄)이 포켓(6줄)보다 아래라 포켓은 한 판에 많아야 한 번
  if (ball->>'pocket')::boolean then
    is_fever := random() < 0.125;
    if is_fever then
      letters := 0;
      reels := array['429', '429', '429'];
      for i in 1..40 loop
        fb := plinko_launch(floor(random() * 3)::int - 1, true, 0, p_amount, 0);
        fever_balls := fever_balls || fb;
        total := total + (fb->>'payout')::bigint;
        top := greatest(top, (fb->>'mult')::numeric);
      end loop;
    else
      -- 한 칸 오른다. HOT(3)이던 보드는 이 포켓으로 끝
      letters := case when level >= 3 then 0 else level + 1 end;
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
    'payout', total, 'top_mult', top, 'fever', is_fever, 'letters', letters, 'level', level, 'vip', p_vip);
end $$;

-- 금액 10~200칩
create or replace function public.plinko_drop(p_amount bigint, p_lane int, p_power int, p_golden boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  amount bigint := case when p_golden then 100 else p_amount end;
  lane int := greatest(-1, least(1, coalesce(p_lane, 0)));
  power int := greatest(0, least(1000, coalesce(p_power, 0)));
  grade text := plinko_grade(power);
  vip boolean;
  letters int;
  res jsonb;
  pay bigint;
  player_row players;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  -- 레벨은 판 사이에 이어지므로 행을 잠그고 읽는다 (동시에 던진 공끼리 덮어쓰지 않게)
  select coalesce(golden_until > now(), false), plinko_letters into vip, letters
  from players where id = me and named for update;
  if not found then raise exception 'not_named'; end if;
  if amount is null or amount not between 10 and 200 then raise exception 'invalid_amount'; end if;
  if p_golden then
    update players set golden_chips = golden_chips - 1
    where id = me and golden_chips > 0 and golden_until > now();
    if not found then raise exception 'no_golden'; end if;
  else
    update players set chips = chips - amount
    where id = me and chips >= amount;
    if not found then raise exception 'insufficient_chips'; end if;
  end if;
  res := plinko_resolve(amount, lane, grade, vip, letters);
  pay := (res->>'payout')::bigint;
  update players set chips = chips + pay, plinko_letters = (res->>'letters')::int
  where id = me returning * into player_row;
  insert into plinko_drops (player_id, amount, golden, lane, power, grade, pocket, fever, top_mult, payout, result, vip, letters)
  values (me, amount, p_golden, lane, power, grade, res->'pocket' is not null and res->'pocket' <> 'null'::jsonb,
          (res->>'fever')::boolean, (res->>'top_mult')::numeric, pay, res, vip, (res->>'letters')::int);
  return res || jsonb_build_object('lane', lane, 'power', power, 'grade', grade, 'amount', amount,
    'golden', p_golden, 'player', to_jsonb(player_row));
end $$;

revoke execute on function public.plinko_gold(int, int, int)                                              from public, anon, authenticated;
revoke execute on function public.plinko_split(int, int, int)                                             from public, anon, authenticated;
revoke execute on function public.plinko_catch(text, boolean)                                             from public, anon, authenticated;
revoke execute on function public.plinko_path(int, int, boolean, numeric, boolean, numeric, bigint, int)  from public, anon, authenticated;
revoke execute on function public.plinko_launch(int, boolean, numeric, bigint, int)                       from public, anon, authenticated;
revoke execute on function public.plinko_resolve(bigint, int, text, boolean, int)                         from public, anon, authenticated;
revoke execute on function public.plinko_drop(bigint, int, int, boolean)                                  from public, anon;
grant  execute on function public.plinko_drop(bigint, int, int, boolean)                                  to authenticated;
