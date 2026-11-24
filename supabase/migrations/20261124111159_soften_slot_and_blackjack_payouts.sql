-- 일반 슬롯에서 429 한 개로 본전이던 판의 지급을 1.8배로 올린다.
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
  single_429_bonus boolean;
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
  -- 구버전은 multiplier를 정수로 읽는다. 새 앱에는 실제 배당 배수를 따로 보낸다.
  single_429_bonus := mult = 1 and not vip and not p_golden;
  pay := case when single_429_bonus then amount * 9 / 5 else amount * mult end;

  update players set chips = chips + pay where id = auth.uid() returning * into me;
  insert into slot_spins (player_id, amount, golden, reels, multiplier, payout, initial_reels, glitched, vip)
  values (auth.uid(), amount, p_golden, reels, mult, pay, initial, glitched, vip);

  return jsonb_build_object(
    'reels', reels, 'initial_reels', initial, 'glitched', glitched, 'vip', vip,
    'multiplier', mult, 'payout_multiplier', case when single_429_bonus then 1.8 else mult end,
    'payout', pay, 'player', to_jsonb(me)
  );
end $$;

-- 블랙잭 내추럴: 일반 칩 2.75배, 황금 칩 2.5배. 지급액은 칩 단위로 내린다.
create or replace function public.bj_settle(p_round bigint, p_base timestamptz)
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
      when 'blackjack' then case when s.golden then s.amount * 5 / 2 else s.amount * 11 / 4 end
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
