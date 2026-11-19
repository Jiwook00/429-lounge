-- 429 Lounge: 슬롯머신 (솔로)
--
-- 릴 3개 × 가운데 한 줄. 결과와 정산은 이 함수에서만 (ADR-0003).
-- 릴 구성(24칸): 체리 6, 벨 5, BAR 4, 7 3, 429 1, 빈칸 5 → 환수율 약 93.4%, 당첨 확률 약 28%
--
-- 배당 (건 금액 × 배수, 건 금액 포함)
--   같은 심볼 3개: 429 ×429 · 7 ×50 · BAR ×20 · 벨 ×10 · 체리 ×5
--   체리 2개 ×3
--   429 하나 ×1(본전), 둘 ×3

create table public.slot_spins (
  id         bigint generated always as identity primary key,
  player_id  uuid not null references public.players (id) on delete cascade,
  amount     bigint not null check (amount > 0),
  golden     boolean not null default false,
  reels      text[] not null,
  multiplier int not null,
  payout     bigint not null,
  created_at timestamptz not null default now()
);
create index slot_spins_player_idx on public.slot_spins (player_id, id desc);

alter table public.slot_spins enable row level security;
create policy "read own spins" on public.slot_spins for select to authenticated using (player_id = auth.uid());

-- 결과 판정만 (순수 함수, 테스트하기 쉽게 분리)
create function public.slot_multiplier(r text[])
returns int
language sql immutable as $$
  select case
    when r[1] = r[2] and r[2] = r[3] and r[1] <> 'blank' then
      case r[1] when '429' then 429 when 'seven' then 50 when 'bar' then 20 when 'bell' then 10 when 'cherry' then 5 else 0 end
    when (select count(*) from unnest(r) s where s = 'cherry') = 2 then 3
    when (select count(*) from unnest(r) s where s = '429') = 2 then 3
    when (select count(*) from unnest(r) s where s = '429') = 1 then 1
    else 0
  end
$$;

create function public.slot_spin(p_amount bigint, p_golden boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  strip constant text[] := array[
    'cherry','cherry','cherry','cherry','cherry','cherry',
    'bell','bell','bell','bell','bell',
    'bar','bar','bar','bar',
    'seven','seven','seven',
    '429',
    'blank','blank','blank','blank','blank'
  ];
  amount bigint := case when p_golden then 100 else p_amount end;
  reels text[];
  mult int;
  pay bigint;
  me players;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if amount is null or amount <= 0 then raise exception 'invalid_amount'; end if;

  if p_golden then
    update players set golden_chips = golden_chips - 1
    where id = auth.uid() and golden_chips > 0 and golden_until > now();
    if not found then raise exception 'no_golden'; end if;
  else
    update players set chips = chips - amount
    where id = auth.uid() and chips >= amount;
    if not found then raise exception 'insufficient_chips'; end if;
  end if;

  reels := array[
    strip[1 + floor(random() * array_length(strip, 1))::int],
    strip[1 + floor(random() * array_length(strip, 1))::int],
    strip[1 + floor(random() * array_length(strip, 1))::int]
  ];
  mult := slot_multiplier(reels);
  pay := amount * mult;

  update players set chips = chips + pay where id = auth.uid() returning * into me;
  insert into slot_spins (player_id, amount, golden, reels, multiplier, payout)
  values (auth.uid(), amount, p_golden, reels, mult, pay);

  return jsonb_build_object('reels', reels, 'multiplier', mult, 'payout', pay, 'player', to_jsonb(me));
end $$;

revoke execute on function public.slot_spin(bigint, boolean) from public, anon;
grant  execute on function public.slot_spin(bigint, boolean) to authenticated;
