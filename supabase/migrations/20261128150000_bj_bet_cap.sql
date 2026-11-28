-- 블랙잭 일반 칩 베팅 상한 1~200 (앱이 칩 단위를 반복해 눌러 판돈을 늘릴 수 있게 된다).
-- 그동안 서버엔 상한이 없고 앱 버튼만 100이 최대였다. 더블다운은 같은 금액을 한 번 더 걸어 최대 400칩.
-- 황금 칩은 늘 100 (p_amount 무시). 시그니처가 같아 create or replace로 권한(grant)이 그대로 유지된다.
create or replace function public.bj_bet(p_room text, p_amount bigint, p_golden boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r bj_rounds;
  amount bigint := case when p_golden then 100 else p_amount end;
  free int;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if amount is null or amount not between 1 and 200 then raise exception 'invalid_amount'; end if;
  if not exists (select 1 from players where id = me and named) then raise exception 'not_named'; end if;

  perform bj_tick(p_room);
  select * into r from bj_rounds where room_code = p_room order by id desc limit 1;

  if not found or r.phase = 'done' then
    insert into rooms (code) values (p_room) on conflict do nothing;
    -- 직전 판 결과 연출이 끝난 뒤부터 10초
    insert into bj_rounds (room_code, bet_closes_at)
    values (p_room, greatest(now(), coalesce(r.next_at, now())) + interval '10 seconds')
    returning * into r;
  elsif r.phase <> 'betting' then
    raise exception 'betting_closed';
  end if;

  if exists (select 1 from bj_seats where round_id = r.id and player_id = me) then raise exception 'already_bet'; end if;
  select min(i) into free from generate_series(1, 4) i
  where not exists (select 1 from bj_seats where round_id = r.id and seat = i);
  if free is null then raise exception 'table_full'; end if;

  if p_golden then
    update players set golden_chips = golden_chips - 1
    where id = me and golden_chips > 0 and golden_until > now();
    if not found then raise exception 'no_golden'; end if;
  else
    update players set chips = chips - amount where id = me and chips >= amount;
    if not found then raise exception 'insufficient_chips'; end if;
  end if;

  insert into bj_seats (round_id, room_code, seat, player_id, amount, golden)
  values (r.id, p_room, free, me, amount, p_golden);
  return bj_state(p_room);
exception
  when unique_violation then raise exception 'already_bet';
end $$;
