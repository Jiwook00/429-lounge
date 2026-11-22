-- 소수결 참가비 500 → 200 고정 (이슈 #8)
-- 정산은 고정값 대신 진 사람이 낸 칩 합계를 나눈다 (이미 500으로 걸린 판이 섞여도 칩이 새지 않게)

create or replace function public.minority_settle(p_round bigint)
returns void
language plpgsql security definer set search_path = public as $$
declare
  a int; b int; w smallint; winners int; pot bigint; share bigint;
begin
  select count(*) filter (where choice = 0), count(*) filter (where choice = 1)
    into a, b from minority_picks where round_id = p_round;

  if a + b < 3 or a = b or a = 0 or b = 0 then
    w := null; -- 무효: 전액 돌려줌
    update minority_picks set payout = amount where round_id = p_round;
  else
    w := case when a < b then 0 else 1 end;
    winners := least(a, b);
    select coalesce(sum(amount), 0) into pot from minority_picks where round_id = p_round and choice <> w;
    share := pot / winners;
    update minority_picks set payout = case when choice = w then amount + share else 0 end where round_id = p_round;
  end if;

  update players p set chips = p.chips + mp.payout
  from minority_picks mp
  where mp.round_id = p_round and mp.player_id = p.id and mp.payout > 0;

  update minority_rounds set settled_at = now(), a_count = a, b_count = b, winner = w where id = p_round;
end $$;

create or replace function public.minority_pick(p_choice int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  cur minority_rounds;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if p_choice not in (0, 1) then raise exception 'invalid_choice'; end if;
  if not exists (select 1 from players where id = me and named) then raise exception 'not_named'; end if;

  perform minority_tick();
  select * into cur from minority_rounds
  where opens_at = minority_slot(now()) and settled_at is null and closes_at > now();
  if cur.id is null then raise exception 'minority_closed'; end if;
  if exists (select 1 from minority_picks where round_id = cur.id and player_id = me) then
    raise exception 'already_picked';
  end if;

  update players set chips = chips - 200 where id = me and chips >= 200;
  if not found then raise exception 'insufficient_chips'; end if;

  insert into minority_picks (round_id, player_id, choice, amount) values (cur.id, me, p_choice, 200);
  return minority_tick();
exception
  when unique_violation then raise exception 'already_picked';
end $$;
