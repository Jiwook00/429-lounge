-- 429 드롭 2판 (ADR-0019): 칸 배수 다듬기, FEVER 공 40개 ×1.5, 4·2·9 글자(포켓 천장), VIP HOUR 포켓 확장.
--
-- 수치의 원본은 scripts/drop_ev.py. 바꾸면 docs/chip-economy.md도 같이.
-- 환수율: 평소 98 / 98.5 / 99%, VIP HOUR(황금 칩 유효 시간) 105 / 105.5 / 106% (기본 / GOOD / PERFECT)
-- 앱이 보여 주는 칸 배수가 바뀌므로 min_version을 올린다 (ADR-0010).

-- 4·2·9: FEVER가 아닌 포켓마다 한 글자. 0~2 (세 번째 포켓은 FEVER 확정이라 3은 저장하지 않는다)
alter table public.players
  add column plinko_letters smallint not null default 0 check (plinko_letters between 0 and 2);

alter table public.plinko_drops
  add column vip     boolean  not null default false,
  add column letters smallint; -- 이 판이 끝난 뒤 글자 수 (이전 판은 null)

-- ============================================================
-- 규칙
-- ============================================================

create or replace function public.plinko_bucket(p_idx int)
returns numeric
language sql immutable as $$
  select (array[16, 5, 2, 1.4, 0.8, 0.5, 0.3, 0.5, 0.8, 1.4, 2, 5, 16]::numeric[])[p_idx + 1]
$$;

-- 등급별 포켓이 공을 잡을 확률. VIP HOUR엔 입구가 넓다
drop function public.plinko_catch(text);
create function public.plinko_catch(p_grade text, p_vip boolean)
returns numeric
language sql immutable as $$
  select case p_grade when 'perfect' then 0.0322 when 'good' then 0.0312 else 0.0302 end
       + case when p_vip then 0.0135 else 0 end
$$;

-- FEVER 공 배수 ×1.5 (나머지는 20261126120000_plinko_drop.sql과 같다)
create or replace function public.plinko_path(
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
      m := plinko_bucket((jf + 12) / 2) * (case when p_fever then 1.5 else 1 end) + gold;
      return jsonb_build_object('from', p_row, 'js', to_jsonb(js), 'bucket', (jf + 12) / 2, 'gold', gold,
        'mult', m, 'payout', floor(p_amount * m)::bigint, 'pocket', false, 'split', split_row, 'clone', clone);
    end if;
    r := r + 1;
    j := j + d;
  end loop;
end $$;

-- 지갑과 무관한 한 판 결과. p_letters = 이 판 전의 글자 수, 반환의 letters = 이 판 뒤 글자 수
drop function public.plinko_sim(int, int, text);
drop function public.plinko_resolve(bigint, int, text);
create function public.plinko_resolve(p_amount bigint, p_lane int, p_grade text, p_vip boolean, p_letters int)
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
  ceiling boolean := false;
  letters int := p_letters;
  reels text[];
  refund bigint := 0;
  fb jsonb;
begin
  ball := plinko_launch(p_lane, false, plinko_catch(p_grade, p_vip), p_amount);
  total := (ball->>'payout')::bigint + coalesce((ball->'clone'->>'payout')::bigint, 0);
  top := greatest((ball->>'mult')::numeric, coalesce((ball->'clone'->>'mult')::numeric, 0));
  -- 분열 핀(10줄)이 포켓(6줄)보다 아래라 포켓은 한 판에 많아야 한 번
  if (ball->>'pocket')::boolean then
    ceiling := letters >= 2;
    is_fever := ceiling or random() < 0.125;
    if is_fever then
      letters := 0;
      reels := array['429', '429', '429'];
      for i in 1..40 loop
        fb := plinko_launch(floor(random() * 3)::int - 1, true, 0, p_amount);
        fever_balls := fever_balls || fb;
        total := total + (fb->>'payout')::bigint;
        top := greatest(top, (fb->>'mult')::numeric);
      end loop;
    else
      letters := letters + 1;
      -- 연출용 릴. 429 둘이면 리치. 셋 다 429는 FEVER일 때만
      reels := array[
        case when random() < 0.4 then '429' else syms[1 + floor(random() * 5)::int] end,
        '429',
        syms[2 + floor(random() * 4)::int]];
      if reels[1] <> '429' then reels[2] := syms[1 + floor(random() * 5)::int]; end if;
      refund := floor(p_amount * 0.2)::bigint;
      total := total + refund;
    end if;
    pocket := jsonb_build_object('reels', to_jsonb(reels), 'fever', is_fever, 'refund', refund, 'ceiling', ceiling);
  end if;
  return jsonb_build_object('ball', ball, 'pocket', pocket, 'fever_balls', fever_balls,
    'payout', total, 'top_mult', top, 'fever', is_fever, 'letters', letters, 'vip', p_vip);
end $$;

-- ============================================================
-- 던지기
-- ============================================================

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
  -- 글자는 판 사이에 이어지므로 행을 잠그고 읽는다 (동시에 던진 공끼리 글자를 덮어쓰지 않게)
  select coalesce(golden_until > now(), false), plinko_letters into vip, letters
  from players where id = me and named for update;
  if not found then raise exception 'not_named'; end if;
  if amount is null or amount not between 1 and 300 then raise exception 'invalid_amount'; end if;
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

-- 로컬 환수율 확인용 (클라이언트는 못 부른다). 글자를 판 사이에 이어 간다
create function public.plinko_sim(p_n int, p_lane int default 0, p_grade text default 'none', p_vip boolean default false)
returns jsonb
language plpgsql volatile as $$
declare
  paid numeric := 0;
  fevers int := 0;
  ceilings int := 0;
  pockets int := 0;
  letters int := 0;
  res jsonb;
begin
  for i in 1..p_n loop
    res := plinko_resolve(100, p_lane, p_grade, p_vip, letters);
    letters := (res->>'letters')::int;
    paid := paid + (res->>'payout')::bigint;
    if (res->>'fever')::boolean then fevers := fevers + 1; end if;
    if res->'pocket' <> 'null'::jsonb then
      pockets := pockets + 1;
      if (res->'pocket'->>'ceiling')::boolean then ceilings := ceilings + 1; end if;
    end if;
  end loop;
  return jsonb_build_object('n', p_n, 'rtp', round(paid / (p_n * 100.0), 4), 'fevers', fevers,
    'ceilings', ceilings, 'pockets', pockets);
end $$;

-- ============================================================
-- 권한: 클라이언트는 plinko_drop만
-- ============================================================

revoke execute on function public.plinko_bucket(int)                                              from public, anon, authenticated;
revoke execute on function public.plinko_catch(text, boolean)                                     from public, anon, authenticated;
revoke execute on function public.plinko_path(int, int, boolean, numeric, boolean, numeric, bigint) from public, anon, authenticated;
revoke execute on function public.plinko_resolve(bigint, int, text, boolean, int)                 from public, anon, authenticated;
revoke execute on function public.plinko_sim(int, int, text, boolean)                             from public, anon, authenticated;
revoke execute on function public.plinko_drop(bigint, int, int, boolean)                          from public, anon;
grant  execute on function public.plinko_drop(bigint, int, int, boolean)                          to authenticated;

update public.client_policy set min_version = '0.15.0';
