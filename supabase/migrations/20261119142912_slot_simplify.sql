-- 429 Lounge: 슬롯 기믹 정리 — 200 와일드, 404 심볼 제거 (docs/chip-economy.md)
--
-- 남는 기믹: 500 글리치 리스핀, VIP HOUR 부스트, 응답 라인(클라이언트 연출)
--
-- 릴(26칸): 체리 6, 벨 5, BAR 4, 7 3, 429 1, 빈칸 5, 500 2
--   평소     환수율 ≈ 93.37%, 당첨 ≈ 28.4%, 잭팟 1/13,824
--   VIP HOUR 429 +1, 빈칸 +1 (28칸) → 환수율 ≈ 107.97%, 당첨 ≈ 34.9%, 잭팟 1/2,197
-- 500은 리스핀 때 같은 릴(500 제외)에서 다시 뽑으므로 환수율에 영향 없음.

create or replace function public.slot_multiplier(r text[])
returns int
language plpgsql immutable as $$
declare
  f429 int := (select count(*) from unnest(r) s where s = '429');
  best int := 0;
begin
  if r[1] = r[2] and r[2] = r[3] then
    best := case r[1] when '429' then 429 when 'seven' then 50 when 'bar' then 20 when 'bell' then 10 when 'cherry' then 5 else 0 end;
    if best > 0 then return best; end if;
  end if;
  if (select count(*) from unnest(r) s where s = 'cherry') = 2 then best := 3; end if;
  if f429 = 2 then best := greatest(best, 3);
  elsif f429 = 1 then best := greatest(best, 1);
  end if;
  return best;
end $$;

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
  if amount is null or amount <= 0 then raise exception 'invalid_amount'; end if;

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
