-- 429 Lounge: 슬롯에 HTTP 상태 코드 기믹 추가 (docs/chip-economy.md)
--
--   200 OK          와일드. 체리/벨/BAR/7 세 개 맞추기에 대신 들어간다 (429는 대신 못 함). 200×3 = ×25
--   404 Not Found   빈칸 대체. 값 없음. 단 404×3 = "찾았다!" ×4
--   500 Error       당첨선에 뜨면 그 릴이 한 번 더 돈다 (다시 돌 땐 500 없음)
--   VIP HOUR        황금 칩이 유효한 동안(= 429 리셋 전) 릴에 429가 한 칸 더 들어간다
--
-- 릴(31칸): 체리 6, 벨 6, BAR 4, 7 3, 429 1, 404 8, 200 1, 500 2
--   평소     환수율 ≈ 93.8%, 당첨 ≈ 25%, 잭팟 1/24,389
--   VIP HOUR 환수율 ≈ 108.2%, 당첨 ≈ 32%, 잭팟 1/3,375

alter table public.slot_spins
  add column initial_reels text[],  -- 500 리스핀 전 (연출용)
  add column glitched      int[] not null default '{}', -- 리스핀된 릴 번호 (1부터)
  add column vip           boolean not null default false;

create or replace function public.slot_multiplier(r text[])
returns int
language plpgsql immutable as $$
declare
  wild   int := (select count(*) from unnest(r) s where s = '200');
  others text[] := array(select s from unnest(r) s where s <> '200');
  f429   int := (select count(*) from unnest(r) s where s = '429');
  best   int := 0;
begin
  if f429 = 3 then return 429; end if; -- 잭팟은 순수 429 세 개만

  if wild = 3 then
    best := 25;
  elsif (select count(distinct s) from unnest(others) s) = 1 and others[1] in ('seven', 'bar', 'bell', 'cherry') then
    best := case others[1] when 'seven' then 50 when 'bar' then 20 when 'bell' then 10 else 5 end;
  end if;

  if (select count(*) from unnest(r) s where s = '404') = 3 then best := greatest(best, 4); end if;
  -- 체리 페어는 진짜 체리 2개 (와일드 제외)
  if best = 0 and (select count(*) from unnest(r) s where s = 'cherry') >= 2 then best := 3; end if;

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
    'bell','bell','bell','bell','bell','bell',
    'bar','bar','bar','bar',
    'seven','seven','seven',
    '429',
    '404','404','404','404','404','404','404','404',
    '200',
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

  strip := case when vip then base || array['429'] else base end;
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
