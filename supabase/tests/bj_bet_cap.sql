-- 블랙잭 베팅 상한(200)·잔액·더블다운·중복 정산 확인. 로컬 DB 전용, 끝에 rollback이라 흔적이 남지 않는다.
--   docker exec -i supabase_db_429-lounge psql -U postgres -v ON_ERROR_STOP=1 < supabase/tests/bj_bet_cap.sql
-- 시간은 트랜잭션 안에서 안 흐르므로 마감 시각을 직접 당겨 bj_tick을 진행시킨다.
begin;

create schema bjt;
grant usage on schema bjt to authenticated;
create table bjt.t_log (name text, ok boolean, detail text);
grant all on bjt.t_log to authenticated;

-- 회원 만들기 + 그 회원으로 호출 (rpc는 authenticated 권한으로)
create function bjt.mk(p_name text, p_chips bigint, p_golden int default 0) returns uuid
language plpgsql as $$
declare u uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role) values (u, 'authenticated', 'authenticated');
  insert into players (id, name, chips, golden_chips, golden_until, named)
  values (u, p_name, p_chips, p_golden, now() + interval '1 day', true)
  on conflict (id) do update set name = p_name, chips = p_chips, golden_chips = p_golden, golden_until = now() + interval '1 day', named = true;
  return u;
end $$;

create function bjt.act_as(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
end $$;

-- 예외 메시지(또는 'ok')를 돌려주는 호출 도우미
create function bjt.try_bet(room text, amt bigint, g boolean default false) returns text
language plpgsql as $$
begin
  perform public.bj_bet(room, amt, g);
  return 'ok';
exception when others then return sqlerrm;
end $$;

create function bjt.try_act(room text, a text) returns text
language plpgsql as $$
begin
  perform public.bj_action(room, a);
  return 'ok';
exception when others then return sqlerrm;
end $$;

create function bjt.chk(n text, cond boolean, d text default '') returns void
language plpgsql as $$
begin
  insert into bjt.t_log values (n, coalesce(cond, false), d);
end $$;


-- ============ 1. 한도 ============
reset role;
do $$
declare u uuid; r text; c bigint;
begin
  u := bjt.mk('한도A', 1000);
  perform bjt.act_as(u);
  set local role authenticated;

  r := bjt.try_bet('TCAP0', 0); perform bjt.chk('0칩 거절', r = 'invalid_amount', r);
  r := bjt.try_bet('TCAP0', -5); perform bjt.chk('음수 거절', r = 'invalid_amount', r);
  r := bjt.try_bet('TCAP0', 201); perform bjt.chk('201칩 거절', r = 'invalid_amount', r);
  r := bjt.try_bet('TCAP0', 100000); perform bjt.chk('10만칩 거절', r = 'invalid_amount', r);
  reset role;
  select chips into c from players where id = u;
  perform bjt.chk('거절된 베팅은 칩을 안 깎음', c = 1000, c::text);

  set local role authenticated;
  r := bjt.try_bet('TCAP0', 200); perform bjt.chk('200칩 허용', r = 'ok', r);
  reset role;
  select chips into c from players where id = u;
  perform bjt.chk('200칩 차감', c = 800, c::text);
  perform bjt.chk('좌석 금액 200', (select amount from bj_seats where player_id = u order by round_id desc limit 1) = 200);

  set local role authenticated;
  r := bjt.try_bet('TCAP0', 30); perform bjt.chk('같은 판 두 번 거절', r = 'already_bet', r);
end $$;

-- 기존 기본 베팅(10·30·50·100) 그대로 허용
reset role;
do $$
declare u uuid; amt bigint; r text; c bigint; i int := 0;
begin
  foreach amt in array array[10, 30, 50, 100]::bigint[] loop
    i := i + 1;
    u := bjt.mk('기본' || i, 1000);
    perform bjt.act_as(u);
    set local role authenticated;
    r := bjt.try_bet('TCAP1', amt);
    reset role;
    select chips into c from players where id = u;
    perform bjt.chk('기본 베팅 ' || amt, r = 'ok' and c = 1000 - amt, r || ' ' || c);
  end loop;
end $$;

-- ============ 2. 잔액 ============
reset role;
do $$
declare u uuid; r text; c bigint;
begin
  u := bjt.mk('잔액A', 150);
  perform bjt.act_as(u);
  set local role authenticated;
  r := bjt.try_bet('TCAP2', 200); perform bjt.chk('잔액 150에 200 거절', r = 'insufficient_chips', r);
  reset role;
  select chips into c from players where id = u;
  perform bjt.chk('잔액 부족 시 칩 그대로', c = 150, c::text);
  set local role authenticated;
  r := bjt.try_bet('TCAP2', 150); perform bjt.chk('잔액 150에 150 허용', r = 'ok', r);
  reset role;
  select chips into c from players where id = u;
  perform bjt.chk('잔액 0', c = 0, c::text);
end $$;

-- ============ 3. 황금 칩은 늘 100 (금액 무시) ============
reset role;
do $$
declare u uuid; r text; c bigint; g int; a bigint;
begin
  u := bjt.mk('황금A', 1000, 2);
  perform bjt.act_as(u);
  set local role authenticated;
  r := bjt.try_bet('TCAP3', 999, true);
  reset role;
  select chips, golden_chips into c, g from players where id = u;
  select amount into a from bj_seats where player_id = u order by round_id desc limit 1;
  perform bjt.chk('황금 칩: 금액 인자 무시', r = 'ok' and a = 100 and c = 1000 and g = 1, r || ' ' || a || ' ' || c || ' ' || g);
end $$;

-- ============ 4. 더블다운 + 정산 (200칩) ============
-- 판을 직접 세팅: 내 자리 카드/딜러 카드를 고정해 결과를 정한다
create function bjt.setup(room text, u uuid, amt bigint, mine smallint[], dealer smallint[]) returns void
language plpgsql as $$
declare rid bigint; s int;
begin
  reset role;
  perform bjt.act_as(u);
  set local role authenticated;
  perform public.bj_bet(room, amt, false);
  reset role;
  select max(id) into rid from bj_rounds where room_code = room;
  update bj_rounds set bet_closes_at = now() - interval '1 second' where id = rid;
  set local role authenticated;
  perform public.bj_tick(room); -- 딜: 봇 착석, 카드 배분
  reset role;
  select seat into s from bj_seats where round_id = rid and player_id = u;
  update bj_seats set cards = mine, state = 'playing' where round_id = rid and seat = s;
  update bj_rounds set phase = 'playing', turn_seat = s, turn_deadline = now() + interval '1 hour', dealer_cards = dealer where id = rid;
end $$;

-- 더블 성공: 20 vs 딜러 19 → 800 지급 (건 400) → 칩 1000-200-200+800 = 1400
reset role;
do $$
declare u uuid; c bigint; rid bigint; r text; p bigint; res text;
begin
  u := bjt.mk('더블승', 1000);
  perform bjt.setup('TDBL1', u, 200, array[4, 5]::smallint[], array[8]::smallint[]); -- 5+6=11
  perform bjt.act_as(u);
  set local role authenticated;
  r := bjt.try_act('TDBL1', 'double');
  reset role;
  select chips into c from players where id = u;
  perform bjt.chk('더블: 두 번째 200 차감', r = 'ok' and c = 600, r || ' ' || c);
  select max(id) into rid from bj_rounds where room_code = 'TDBL1';
  -- 결과 고정: 내 카드 20, 딜러 19 (딜러 두 장째에서 17 이상이면 멈춤)
  update bj_seats set cards = array[9, 12]::smallint[], state = 'stood', doubled = true where round_id = rid and player_id = u;
  update bj_rounds set phase = 'dealer', turn_seat = null, turn_deadline = now() - interval '1 second', dealer_cards = array[8, 9]::smallint[] where id = rid;
  set local role authenticated;
  perform public.bj_tick('TDBL1');
  reset role;
  select chips into c from players where id = u;
  select payout, result into p, res from bj_seats where round_id = rid and player_id = u;
  perform bjt.chk('더블 승리 정산', c = 1400 and p = 800 and res = 'win', c || ' ' || p || ' ' || res);
  -- 중복 정산 방지: 다시 tick/bet/상태 조회를 해도 칩이 그대로
  set local role authenticated;
  perform public.bj_tick('TDBL1'); perform public.bj_tick('TDBL1');
  reset role;
  select chips into c from players where id = u;
  perform bjt.chk('tick 반복에도 이중 지급 없음', c = 1400, c::text);
  -- game_results 순수익 = 지급 - 건 칩(더블 두 배)
  perform bjt.chk('큰손 순수익 +400', (select net from game_results where player_id = u) = 400, (select net from game_results where player_id = u)::text);
end $$;

-- 더블 패배: 칩 1000-400 = 600
reset role;
do $$
declare u uuid; c bigint; rid bigint; r text;
begin
  u := bjt.mk('더블패', 1000);
  perform bjt.setup('TDBL2', u, 200, array[4, 5]::smallint[], array[8]::smallint[]);
  perform bjt.act_as(u);
  set local role authenticated;
  r := bjt.try_act('TDBL2', 'double');
  reset role;
  select max(id) into rid from bj_rounds where room_code = 'TDBL2';
  update bj_seats set cards = array[4, 5, 6]::smallint[], state = 'stood' where round_id = rid and player_id = u; -- 5+6+7=18
  update bj_rounds set phase = 'dealer', turn_seat = null, turn_deadline = now() - interval '1 second', dealer_cards = array[9, 12]::smallint[] where id = rid;
  set local role authenticated;
  perform public.bj_tick('TDBL2');
  perform public.bj_tick('TDBL2');
  reset role;
  select chips into c from players where id = u;
  perform bjt.chk('더블 패배: 400 잃음', c = 600, c::text);
  perform bjt.chk('큰손 순수익 -400', (select net from game_results where player_id = u) = -400);
end $$;

-- 더블 푸시: 건 칩 두 배 돌려받음 → 1000
reset role;
do $$
declare u uuid; c bigint; rid bigint;
begin
  u := bjt.mk('더블무', 1000);
  perform bjt.setup('TDBL3', u, 200, array[4, 5]::smallint[], array[8]::smallint[]);
  perform bjt.act_as(u);
  set local role authenticated;
  perform bjt.try_act('TDBL3', 'double');
  reset role;
  select max(id) into rid from bj_rounds where room_code = 'TDBL3';
  update bj_seats set cards = array[9, 8]::smallint[], state = 'stood' where round_id = rid and player_id = u; -- 19
  update bj_rounds set phase = 'dealer', turn_seat = null, turn_deadline = now() - interval '1 second', dealer_cards = array[8, 9]::smallint[] where id = rid; -- 19
  set local role authenticated;
  perform public.bj_tick('TDBL3'); perform public.bj_tick('TDBL3');
  reset role;
  select chips into c from players where id = u;
  perform bjt.chk('더블 푸시: 칩 그대로', c = 1000, c::text);
end $$;

-- 더블 잔액 부족: 200 걸고 남은 칩이 200 미만이면 거절, 칩·자리 그대로
reset role;
do $$
declare u uuid; c bigint; rid bigint; r text; dbl boolean; n int;
begin
  u := bjt.mk('더블잔액', 399);
  perform bjt.setup('TDBL4', u, 200, array[4, 5]::smallint[], array[8]::smallint[]); -- 남은 199
  perform bjt.act_as(u);
  set local role authenticated;
  r := bjt.try_act('TDBL4', 'double');
  reset role;
  select chips into c from players where id = u;
  select doubled, cardinality(cards) into dbl, n from bj_seats where player_id = u order by round_id desc limit 1;
  perform bjt.chk('더블 잔액 부족 거절', r = 'insufficient_chips' and c = 199 and not dbl and n = 2, r || ' ' || c);
end $$;

-- 황금 칩 더블 불가, 블랙잭 정산(200칩 → 550)
reset role;
do $$
declare u uuid; c bigint; rid bigint; r text; p bigint;
begin
  u := bjt.mk('황금더블', 1000, 1);
  perform bjt.act_as(u);
  set local role authenticated;
  perform public.bj_bet('TDBL5', 100, true);
  reset role;
  select max(id) into rid from bj_rounds where room_code = 'TDBL5';
  update bj_rounds set bet_closes_at = now() - interval '1 second' where id = rid;
  set local role authenticated; perform public.bj_tick('TDBL5'); reset role;
  update bj_seats set cards = array[4, 5]::smallint[], state = 'playing' where round_id = rid and player_id = u;
  update bj_rounds set phase = 'playing', turn_seat = (select seat from bj_seats where round_id = rid and player_id = u), turn_deadline = now() + interval '1 hour' where id = rid;
  set local role authenticated; r := bjt.try_act('TDBL5', 'double'); reset role;
  perform bjt.chk('황금 칩 더블 불가', r = 'cannot_double', r);

  u := bjt.mk('블랙잭200', 1000);
  perform bjt.setup('TBJ1', u, 200, array[0, 12]::smallint[], array[8]::smallint[]);
  select max(id) into rid from bj_rounds where room_code = 'TBJ1';
  update bj_seats set state = 'blackjack' where round_id = rid and player_id = u;
  update bj_rounds set phase = 'dealer', turn_seat = null, turn_deadline = now() - interval '1 second', dealer_cards = array[8, 9]::smallint[] where id = rid;
  perform bjt.act_as(u);
  set local role authenticated; perform public.bj_tick('TBJ1'); perform public.bj_tick('TBJ1'); reset role;
  select chips into c from players where id = u;
  select payout into p from bj_seats where round_id = rid and player_id = u;
  perform bjt.chk('200칩 블랙잭 550 지급', p = 550 and c = 1350, p || ' ' || c);
end $$;

reset role;
select name, case when ok then 'PASS' else 'FAIL' end as result, detail from bjt.t_log order by ctid;
select count(*) filter (where not ok) as failures, count(*) as total from bjt.t_log;
rollback;
