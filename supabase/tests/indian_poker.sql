-- 인디언 포커 서버 규칙 확인 (ADR-0023). 로컬 DB 전용, 끝에 rollback이라 흔적이 남지 않는다.
--   docker exec -i supabase_db_429-lounge psql -U postgres -v ON_ERROR_STOP=1 < supabase/tests/indian_poker.sql
-- 트랜잭션 안에서는 now()가 멈춰 있으므로, 시간이 지난 일은 ip_advance(테이블, 미래 시각)나 마감을 당겨서 진행한다.
-- 카드는 판이 시작된 뒤 ip_cards를 직접 바꿔 정한다. 마지막은 컴퓨터 판단끼리 수백 판 시뮬레이션.
begin;

create schema ipt;
grant usage on schema ipt to authenticated;
create table ipt.t_log (name text, ok boolean, detail text);
grant all on ipt.t_log to authenticated;

create function ipt.mk(p_name text, p_chips bigint, p_named boolean default true) returns uuid
language plpgsql as $$
declare u uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role) values (u, 'authenticated', 'authenticated');
  insert into players (id, name, chips, named) values (u, p_name, p_chips, p_named)
  on conflict (id) do update set name = p_name, chips = p_chips, named = p_named;
  return u;
end $$;

create function ipt.as_(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
end $$;

-- RPC를 그 회원으로 부르고 예외 메시지(또는 'ok')
create function ipt.act(u uuid, t bigint, a text, amt bigint default null) returns text language plpgsql as $$
begin perform ipt.as_(u); perform public.ip_action(t, a, amt); return 'ok';
exception when others then return sqlerrm; end $$;
create function ipt.create_(u uuid, bots int) returns text language plpgsql as $$
begin perform ipt.as_(u); return (public.ip_create(bots) -> 'table' ->> 'id');
exception when others then return sqlerrm; end $$;
create function ipt.join_(u uuid, t bigint) returns text language plpgsql as $$
begin perform ipt.as_(u); perform public.ip_join(t); return 'ok';
exception when others then return sqlerrm; end $$;
create function ipt.leave_(u uuid, t bigint) returns jsonb language plpgsql as $$
begin perform ipt.as_(u); return public.ip_leave(t); end $$;
create function ipt.tick(u uuid, t bigint) returns jsonb language plpgsql as $$
begin perform ipt.as_(u); return public.ip_tick(t); end $$;

create function ipt.hand(t bigint) returns ip_hands language sql as $$
  select * from ip_hands where table_id = t order by hand_no desc limit 1 $$;
create function ipt.seat(t bigint, s int) returns ip_hand_seats language sql as $$
  select * from ip_hand_seats where hand_id = (ipt.hand(t)).id and seat = s $$;
create function ipt.chips(u uuid) returns bigint language sql as $$ select chips from players where id = u $$;
create function ipt.cards(t bigint, c int[]) returns void language plpgsql as $$
declare i int;
begin
  for i in 1..cardinality(c) loop
    update ip_cards set card = c[i] where hand_id = (ipt.hand(t)).id and seat = i;
  end loop;
end $$;
-- 지금 판이 끝나고 다음 판 시작 (모두 아직 앉아 있는 것으로)
create function ipt.next_hand(t bigint) returns void language plpgsql as $$
declare h ip_hands := ipt.hand(t);
begin
  if h.phase <> 'done' then raise exception 'hand not done'; end if;
  update ip_members set seen_at = h.next_at where table_id = t and left_at is null;
  perform ip_advance(t, h.next_at);
end $$;
-- 판을 끝낸다: 사람은 모두 폴드
create function ipt.finish(t bigint) returns void language plpgsql as $$
declare h ip_hands; s ip_hand_seats; i int := 0;
begin
  loop
    h := ipt.hand(t); i := i + 1;
    exit when h.phase = 'done' or i > 50;
    s := ipt.seat(t, h.turn_seat);
    if s.player_id is null then perform ip_advance(t, h.turn_deadline);
    else perform ip_apply(h.id, h.turn_seat, 'fold', null, h.turn_started_at); end if;
  end loop;
end $$;

create function ipt.chk(n text, cond boolean, d text default '') returns void language plpgsql as $$
begin insert into ipt.t_log values (n, coalesce(cond, false), d); end $$;


-- ============ 1. 로비 · 만들기 · 입장 · 카드 가림 ============
do $$
declare a uuid; b uuid; c uuid; d uuid; e uuid; nn uuid; poor uuid; r text; t bigint; st jsonb; lob jsonb; h ip_hands; x int;
begin
  a := ipt.mk('포커A', 1000); b := ipt.mk('포커B', 1000); c := ipt.mk('포커C', 1000); d := ipt.mk('포커D', 1000);
  e := ipt.mk('포커E', 1000); nn := ipt.mk('손님 ABCDEF', 1000, false); poor := ipt.mk('포커가난', 9);

  r := ipt.create_(nn, 1); perform ipt.chk('닉네임 없으면 못 만듦', r = 'not_named', r);
  r := ipt.create_(poor, 1); perform ipt.chk('앤티보다 적으면 못 만듦', r = 'insufficient_chips', r);
  r := ipt.create_(a, 0); perform ipt.chk('컴퓨터 0명 거절', r = 'invalid_bots', r);
  r := ipt.create_(a, 4); perform ipt.chk('컴퓨터 4명 거절', r = 'invalid_bots', r);

  r := ipt.create_(a, 3); t := r::bigint;
  perform ipt.chk('만들기: 4석', (select capacity from ip_tables where id = t) = 4, r);
  h := ipt.hand(t);
  perform ipt.chk('첫 판 바로 시작, 첫 행동 1번', h.hand_no = 1 and h.phase = 'betting' and h.first_seat = 1 and h.turn_seat = 1);
  perform ipt.chk('사람 차례 11초 (+딜 2초)', h.turn_deadline - h.turn_started_at = interval '11 seconds' and h.turn_started_at = now() + interval '2 seconds');
  perform ipt.chk('앤티 10 차감', ipt.chips(a) = 990, ipt.chips(a)::text);
  perform ipt.chk('나머지 자리는 컴퓨터', (select count(*) from ip_hand_seats where hand_id = h.id and player_id is null) = 3);
  perform ipt.chk('앤티 판돈 40', (select sum(put) from ip_hand_seats where hand_id = h.id) = 40);
  perform ipt.chk('카드 1~10 서로 다름', (select count(distinct card) from ip_cards where hand_id = h.id) = 4);
  r := ipt.create_(a, 1); perform ipt.chk('한 번에 한 테이블', r = 'already_at_table', r);

  -- 카드 가림
  st := ipt.tick(a, t);
  perform ipt.chk('내 카드는 안 옴', st -> 'seats' -> 0 -> 'card' = 'null'::jsonb, (st -> 'seats' -> 0)::text);
  perform ipt.chk('상대 카드는 옴', (select bool_and(s -> 'card' <> 'null'::jsonb) from jsonb_array_elements(st -> 'seats') s where (s ->> 'seat')::int > 1));
  perform ipt.as_(e);
  st := public.ip_tick(t);
  perform ipt.chk('앉지 않은 회원은 카드 전부 가림', (select bool_and(s -> 'card' = 'null'::jsonb) from jsonb_array_elements(st -> 'seats') s));

  -- 로비: 사람만 센다
  lob := public.ip_lobby();
  select count(*) into x from jsonb_array_elements(lob -> 'tables') j where (j ->> 'id')::bigint = t and (j ->> 'humans')::int = 1 and (j ->> 'capacity')::int = 4
    and j -> 'names' = jsonb_build_array('포커A');
  perform ipt.chk('로비 1/4, 컴퓨터 이름 숨김', x = 1, (lob -> 'tables')::text);
  perform ipt.as_(a);
  perform ipt.chk('로비에 내 테이블', (public.ip_lobby() ->> 'my_table')::bigint = t);

  -- 입장
  r := ipt.join_(nn, t); perform ipt.chk('닉네임 없으면 못 앉음', r = 'not_named', r);
  r := ipt.join_(poor, t); perform ipt.chk('앤티보다 적으면 못 앉음', r = 'insufficient_chips', r);
  r := ipt.join_(b, t); perform ipt.chk('B 입장', r = 'ok', r);
  r := ipt.join_(b, t); perform ipt.chk('같은 테이블 다시 입장은 그대로', r = 'ok', r);
  perform ipt.chk('B는 2번 자리 대기', (select seat from ip_members where table_id = t and player_id = b and left_at is null) = 2);
  perform ipt.chk('진행 중 판의 2번은 여전히 컴퓨터', (ipt.seat(t, 2)).player_id is null);
  perform ipt.chk('B 칩은 다음 판까지 그대로', ipt.chips(b) = 1000);
  st := ipt.tick(b, t);
  perform ipt.chk('대기 중인 B는 판 카드 다 봄(판 밖)', (select bool_and(s -> 'card' <> 'null'::jsonb) from jsonb_array_elements(st -> 'seats') s));
  perform ipt.join_(c, t); perform ipt.join_(d, t);
  r := ipt.join_(e, t); perform ipt.chk('만석이면 table_full', r = 'table_full', r);

  -- 첫 판 끝 → 둘째 판은 사람 넷, 첫 행동은 2번
  perform ipt.finish(t);
  perform ipt.next_hand(t);
  h := ipt.hand(t);
  perform ipt.chk('둘째 판: 컴퓨터 자리를 사람이 차지', (select count(*) from ip_hand_seats where hand_id = h.id and player_id is not null) = 4);
  perform ipt.chk('첫 행동 자리 회전 (2번)', h.first_seat = 2 and h.turn_seat = 2, h.first_seat || '/' || h.turn_seat);
  perform ipt.chk('B 앤티', ipt.chips(b) = 990);

  -- 직접 테이블 읽기: 카드 테이블은 막힘
  set local role authenticated;
  begin
    perform count(*) from ip_cards;
    perform ipt.chk('ip_cards 직접 읽기 막힘', false, 'read ok');
  exception when insufficient_privilege then
    perform ipt.chk('ip_cards 직접 읽기 막힘', true);
  end;
  begin
    perform ip_settle(h.id, now());
    perform ipt.chk('내부 함수 호출 막힘', false);
  exception when insufficient_privilege then
    perform ipt.chk('내부 함수 호출 막힘', true);
  end;
  reset role;
end $$;


-- ============ 2. 사람 넷: 체크 조건, 레이즈 최소폭, 올인, 사이드팟 ============
do $$
declare a uuid; b uuid; c uuid; d uuid; r text; t bigint; h ip_hands; before bigint; after bigint; st jsonb;
begin
  a := ipt.mk('사이드A', 1000); b := ipt.mk('사이드B', 1000); c := ipt.mk('사이드C', 1000); d := ipt.mk('사이드D', 1000);
  t := ipt.create_(a, 3)::bigint;
  perform ipt.join_(b, t); perform ipt.join_(c, t); perform ipt.join_(d, t);
  perform ipt.finish(t);
  update players set chips = 50 where id = b;   -- 앤티 뒤 40
  update players set chips = 110 where id = c;  -- 앤티 뒤 100
  before := ipt.chips(a) + ipt.chips(b) + ipt.chips(c) + ipt.chips(d);
  perform ipt.next_hand(t);
  perform ipt.cards(t, array[8, 10, 9, 7]); -- A 8, B 10, C 9, D 7
  h := ipt.hand(t);

  r := ipt.act(a, t, 'check'); perform ipt.chk('내 차례 아니면 거절', r = 'not_your_turn', r);
  r := ipt.act(b, t, 'call'); perform ipt.chk('걸린 게 없으면 콜 거절', r = 'nothing_to_call', r);
  r := ipt.act(b, t, 'raise', 10); perform ipt.chk('걸린 게 없으면 레이즈 대신 베팅', r = 'cannot_raise', r);
  r := ipt.act(b, t, 'bet', 5); perform ipt.chk('베팅 최소 10', r = 'raise_too_small', r);
  r := ipt.act(b, t, 'bet', 0); perform ipt.chk('0칩 베팅 거절', r = 'invalid_amount', r);
  r := ipt.act(b, t, 'shove'); perform ipt.chk('모르는 행동 거절', r = 'invalid_action', r);
  r := ipt.act(b, t, 'bet', 1000); perform ipt.chk('잔액보다 큰 베팅 = 올인', r = 'ok' and (ipt.seat(t, 2)).all_in and (ipt.seat(t, 2)).bet = 40 and ipt.chips(b) = 0, r);
  h := ipt.hand(t);
  perform ipt.chk('올인 40이 최소 폭', h.current_bet = 40 and h.min_raise = 40, h.current_bet || '/' || h.min_raise);

  r := ipt.act(c, t, 'check'); perform ipt.chk('베팅 뒤 체크 거절', r = 'cannot_check', r);
  r := ipt.act(c, t, 'bet', 50); perform ipt.chk('베팅 뒤 베팅 대신 레이즈', r = 'cannot_bet', r);
  r := ipt.act(c, t, 'raise', 30); perform ipt.chk('직전 폭(40)보다 작은 레이즈 거절', r = 'raise_too_small' and ipt.chips(c) = 100, r);
  r := ipt.act(c, t, 'raise', 60); perform ipt.chk('C 레이즈 60 = 잔액 전부 → 올인', r = 'ok' and (ipt.seat(t, 3)).all_in and (ipt.seat(t, 3)).bet = 100 and ipt.chips(c) = 0, r);
  h := ipt.hand(t);
  perform ipt.chk('최소 폭 60으로', h.current_bet = 100 and h.min_raise = 60);

  r := ipt.act(d, t, 'raise', 50); perform ipt.chk('D 레이즈 50 거절 (최소 60)', r = 'raise_too_small', r);
  r := ipt.act(d, t, 'raise', 100); perform ipt.chk('D 레이즈 100', r = 'ok' and (ipt.seat(t, 4)).bet = 200, r);
  r := ipt.act(a, t, 'call'); perform ipt.chk('A 콜 200', r = 'ok', r);
  h := ipt.hand(t);
  perform ipt.chk('모두 맞추면 바로 공개·정산', h.phase = 'done' and h.next_at = h.settled_at + interval '5 seconds', h.phase);
  -- 낸 칩: B 50, C 110, D 210, A 210 = 580. 메인 200 → B(10), 사이드1 180 → C(9), 사이드2 200 → A(8 > D 7)
  perform ipt.chk('메인 팟: B 200', (ipt.seat(t, 2)).payout = 200, (ipt.seat(t, 2)).payout::text);
  perform ipt.chk('사이드 팟 1: C 180', (ipt.seat(t, 3)).payout = 180, (ipt.seat(t, 3)).payout::text);
  perform ipt.chk('사이드 팟 2: A 200', (ipt.seat(t, 1)).payout = 200, (ipt.seat(t, 1)).payout::text);
  perform ipt.chk('D 0', (ipt.seat(t, 4)).payout = 0);
  after := ipt.chips(a) + ipt.chips(b) + ipt.chips(c) + ipt.chips(d);
  perform ipt.chk('사람끼리 판: 칩 합계 보존', before = after, before || ' → ' || after);
  perform ipt.chk('지갑: A 1000-10-200+200, B 200', ipt.chips(a) = 990 - 10 - 200 + 200 and ipt.chips(b) = 200, ipt.chips(a) || '/' || ipt.chips(b));
  st := ipt.tick(a, t);
  perform ipt.chk('끝난 판은 내 카드도 공개', (st -> 'seats' -> 0 ->> 'card')::int = 8);
  perform ipt.chk('순수익 = 지급 − 낸 칩', (st -> 'seats' -> 2 ->> 'net')::int = 70, (st -> 'seats' -> 2)::text);
  perform ipt.chk('이번 주 큰손 뷰에 들어감', (select sum(net) from game_results where game = 'indian_poker' and player_id = c) = 70);

  -- 다음 판: 잔액 0인 B·C는 앤티가 없어 자리에서 빠짐, 첫 행동은 3번 → 빈 자리는 컴퓨터
  perform ipt.next_hand(t);
  perform ipt.finish(t);
  update players set chips = 0 where id in (b, c); -- (앞 판에서 딴 칩이 있어 직접 0으로)
  perform ipt.next_hand(t);
  h := ipt.hand(t);
  perform ipt.chk('앤티 없는 회원은 broke로 빠짐', (select count(*) from ip_members where table_id = t and left_reason = 'broke') = 2);
  perform ipt.chk('빠진 자리는 다시 컴퓨터', (ipt.seat(t, 2)).player_id is null and (ipt.seat(t, 3)).player_id is null);
  perform ipt.chk('넷째 판 첫 행동 4번', h.hand_no = 4 and h.first_seat = 4, h.hand_no || '/' || h.first_seat);
end $$;


-- ============ 3. 전원 체크 · 동점 나눔 · 남는 칩 ============
do $$
declare a uuid; b uuid; r text; t bigint; h ip_hands;
begin
  a := ipt.mk('체크A', 1000); b := ipt.mk('체크B', 1000);
  t := ipt.create_(a, 1)::bigint;
  perform ipt.join_(b, t);
  perform ipt.finish(t);
  perform ipt.next_hand(t);
  perform ipt.cards(t, array[3, 6]);
  h := ipt.hand(t);
  perform ipt.chk('2인 둘째 판 첫 행동 2번', h.turn_seat = 2);
  r := ipt.act(b, t, 'check'); perform ipt.chk('아무도 안 걸었으면 체크', r = 'ok', r);
  perform ipt.chk('체크 뒤에도 판 진행', (ipt.hand(t)).phase = 'betting' and (ipt.hand(t)).turn_seat = 1);
  r := ipt.act(a, t, 'check');
  h := ipt.hand(t);
  perform ipt.chk('전원 체크면 공개', r = 'ok' and h.phase = 'done', r);
  perform ipt.chk('높은 카드(6) B가 앤티 20', (ipt.seat(t, 2)).payout = 20 and (ipt.seat(t, 1)).payout = 0);

  -- 동점 (한 벌이라 실제로는 안 나오지만 카드를 직접 같게)
  perform ipt.next_hand(t);
  perform ipt.cards(t, array[5, 5]);
  h := ipt.hand(t); -- 첫 행동 1번
  r := ipt.act(a, t, 'bet', 15);
  r := ipt.act(b, t, 'call');
  perform ipt.chk('동점이면 나눔 25:25', (ipt.seat(t, 1)).payout = 25 and (ipt.seat(t, 2)).payout = 25, (ipt.seat(t, 1)).payout || '/' || (ipt.seat(t, 2)).payout);

  -- 나눠 떨어지지 않으면 첫 행동 자리부터 한 칩: 컴퓨터(폴드)가 낸 앤티로 홀수 판돈
end $$;

do $$
declare a uuid; b uuid; r text; t bigint; h ip_hands;
begin
  a := ipt.mk('홀수A', 1000); b := ipt.mk('홀수B', 1000);
  t := ipt.create_(a, 2)::bigint;      -- 3석
  perform ipt.join_(b, t);
  perform ipt.finish(t);
  perform ipt.next_hand(t);            -- A, B, 컴퓨터(3번), 첫 행동 2번
  perform ipt.cards(t, array[5, 5, 1]);
  h := ipt.hand(t);
  update ip_hand_seats set put = 5 where hand_id = h.id and seat = 3; -- 판돈 25 만들기 (테스트용)
  r := ipt.act(b, t, 'check');
  -- 3번 컴퓨터 차례: 폴드시킨다
  perform ip_apply(h.id, 3::smallint, 'fold', null, now());
  r := ipt.act(a, t, 'check');
  perform ipt.chk('25칩 동점: 첫 행동 자리(2번)가 13, 1번 12', (ipt.seat(t, 2)).payout = 13 and (ipt.seat(t, 1)).payout = 12,
    (ipt.seat(t, 1)).payout || '/' || (ipt.seat(t, 2)).payout);
end $$;


-- ============ 4. 시간 초과 · 이탈 · 닫힘 · 따라잡기 ============
do $$
declare a uuid; b uuid; c uuid; r text; t bigint; h ip_hands; st jsonb; x int;
begin
  a := ipt.mk('시간A', 1000); b := ipt.mk('시간B', 1000); c := ipt.mk('시간C', 1000);
  t := ipt.create_(a, 2)::bigint;
  perform ipt.join_(b, t); perform ipt.join_(c, t);
  perform ipt.finish(t);
  perform ipt.next_hand(t);  -- 사람 셋, 첫 행동 2번(B)
  h := ipt.hand(t);

  -- 11초 안이면 그대로 (마감 1초 전 tick)
  perform ip_advance(t, h.turn_deadline - interval '1 second');
  perform ipt.chk('11초 안엔 그대로 B 차례', (ipt.hand(t)).turn_seat = 2);
  r := ipt.act(b, t, 'bet', 20);
  perform ipt.chk('B 베팅 20', r = 'ok' and (ipt.seat(t, 2)).put = 30, r);
  h := ipt.hand(t);
  perform ipt.chk('다음은 C, 다시 11초', h.turn_seat = 3 and h.turn_deadline = now() + interval '11 seconds');

  -- C 시간 초과 → 자동 폴드, 낸 앤티는 판돈에 남음
  update ip_hands set turn_deadline = now() - interval '1 second' where id = h.id;
  st := ipt.tick(a, t);
  perform ipt.chk('시간 초과 = 자동 폴드', (ipt.seat(t, 3)).folded and (ipt.seat(t, 3)).last_action = 'timeout');
  perform ipt.chk('판돈 그대로 (50)', (st -> 'hand' ->> 'pot')::int = 50, st -> 'hand' ->> 'pot');
  perform ipt.chk('다음은 A', (ipt.hand(t)).turn_seat = 1);

  -- 차례가 아닌 B가 나감 → 폴드, A 혼자 남아 바로 정산
  st := ipt.leave_(b, t);
  h := ipt.hand(t);
  perform ipt.chk('이탈 = 폴드', (ipt.seat(t, 2)).folded and (ipt.seat(t, 2)).last_action = 'leave');
  perform ipt.chk('하나 남으면 바로 정산, 나간 B의 베팅까지 A가 50', h.phase = 'done' and (ipt.seat(t, 1)).payout = 50 and (ipt.seat(t, 2)).payout = 0, h.phase);
  perform ipt.chk('B는 자리에서 빠짐', (st -> 'me' ->> 'member')::boolean = false and st -> 'me' ->> 'left_reason' = 'leave');
  r := ipt.act(b, t, 'check'); perform ipt.chk('나간 뒤 행동 거절', r = 'not_your_turn', r);

  -- 다음 판: A, C(사람) + 2번 컴퓨터. 첫 행동 3번(C). C 차례에 C가 나가면 바로 다음 차례
  perform ipt.next_hand(t);
  h := ipt.hand(t);
  perform ipt.chk('나간 자리는 컴퓨터로', (ipt.seat(t, 2)).player_id is null and h.first_seat = 3 and h.turn_seat = 3);
  perform ipt.leave_(c, t);
  h := ipt.hand(t);
  perform ipt.chk('내 차례에 나가면 다음 자리(1번)로', h.phase = 'betting' and h.turn_seat = 1 and (ipt.seat(t, 3)).last_action = 'leave');
  perform ipt.chk('C가 낸 앤티는 판돈에', (select sum(put) from ip_hand_seats where hand_id = h.id) = 30);

  -- 마지막 사람 A도 나감 → 사람이 없으니 바로 정산하고 테이블 닫힘
  st := ipt.leave_(a, t);
  perform ipt.chk('사람이 다 나가면 판 끝내고 닫힘', (ipt.hand(t)).phase = 'done' and st -> 'table' ->> 'status' = 'closed', st -> 'table' ->> 'status');
  r := ipt.join_(b, t); perform ipt.chk('닫힌 테이블 입장 거절', r = 'table_closed', r);
  perform ipt.as_(b);
  select count(*) into x from jsonb_array_elements(public.ip_lobby() -> 'tables') j where (j ->> 'id')::bigint = t;
  perform ipt.chk('닫힌 테이블은 로비에서 빠짐', x = 0);
end $$;

-- 잠수와 계속 보는 사람
do $$
declare a uuid; t bigint; h ip_hands; x int; st jsonb;
begin
  -- 비우고 떠난 테이블: 아무도 tick을 안 부르다가 1시간 뒤 로비에서 따라잡는다
  a := ipt.mk('잠수A', 1000);
  t := ipt.create_(a, 3)::bigint;
  perform ip_advance(t, now() + interval '1 hour');
  h := ipt.hand(t);
  -- 1판 시간 초과(13초) → 2판(18초, 마지막으로 본 지 30초 안) 시간 초과 → 3판 시작(36초)에서 away
  perform ipt.chk('따라잡기: 시간 초과 폴드 → 30초 지나 판 시작 때 away로 빠지고 닫힘',
    (select status from ip_tables where id = t) = 'closed' and h.hand_no = 2 and (ipt.seat(t, 1)).last_action = 'timeout'
    and (select left_reason from ip_members where table_id = t and player_id = a) = 'away', h.hand_no::text);
  perform ipt.chk('잠수한 사람은 앤티 두 번까지만 잃음', ipt.chips(a) = 980, ipt.chips(a)::text);

  -- 틱을 계속 부르던 사람은 그대로 (seen_at이 갱신돼서)
  a := ipt.mk('계속A', 1000);
  t := ipt.create_(a, 1)::bigint;
  perform ipt.finish(t);
  perform ipt.next_hand(t);
  perform ipt.chk('보고 있으면 다음 판도 앉아 있음', (ipt.hand(t)).hand_no = 2 and (ipt.seat(t, 1)).player_id = a);
end $$;


-- ============ 5. 컴퓨터 판단끼리 시뮬레이션 ============
-- 사람 자리도 컴퓨터 판단(ip_decide)으로 친다. 사람은 잔액이 적어 올인·사이드팟이 자주 나온다.
-- 확인: 판마다 지급 합 = 낸 칩 합, 올인한 사람은 자기 금액만큼만 땀, 칩 음수 없음, 행동이 모두 규칙 안,
--       전체 사람 칩 변화 = −(컴퓨터 순수익), 접지 않은 최고 카드만 메인 팟을 가져감
do $$
declare
  pl uuid[] := '{}';
  u uuid;
  t bigint;
  h ip_hands;
  cur ip_hand_seats;
  d record;
  i int;
  k int;
  hands int := 0;
  steps int := 0;
  total_before bigint;
  total_after bigint;
  bot_net bigint;
  bad int;
begin
  perform setseed(0.429);
  for i in 1..24 loop
    pl := pl || ipt.mk('시뮬' || i, (array[20, 35, 60, 100, 250, 1000])[1 + (i % 6)]);
  end loop;
  select sum(chips) into total_before from players where id = any(pl);

  for k in 1..40 loop -- 테이블 40개, 테이블마다 판이 닫힐 때까지 최대 20판
    -- 아직 앤티가 있는 사람 1~3명 + 컴퓨터
    u := (select p.id from players p where p.id = any(pl) and p.chips >= 10
          and not exists (select 1 from ip_members m where m.player_id = p.id and m.left_at is null) order by random() limit 1);
    exit when u is null;
    perform ipt.as_(u);
    t := (public.ip_create(1 + floor(random() * 3)::int) -> 'table' ->> 'id')::bigint;
    for i in 1..2 loop
      u := (select p.id from players p where p.id = any(pl) and p.chips >= 10
            and not exists (select 1 from ip_members m where m.player_id = p.id and m.left_at is null) order by random() limit 1);
      if u is not null and random() < 0.7 then perform ipt.join_(u, t); end if;
    end loop;

    loop
      steps := steps + 1;
      exit when steps > 100000;
      h := ipt.hand(t);
      exit when (select status from ip_tables where id = t) = 'closed';
      if h.phase = 'done' then
        hands := hands + 1;
        exit when h.hand_no >= 20;
        perform ipt.next_hand(t);
        continue;
      end if;
      cur := ipt.seat(t, h.turn_seat);
      if cur.player_id is null then
        perform ip_advance(t, h.turn_deadline);
      else
        select * into d from ip_decide(h.id, h.turn_seat);
        perform ip_apply(h.id, h.turn_seat, d.action, d.amount, h.turn_started_at + interval '1 second');
      end if;
    end loop;
    -- 남은 사람은 일어남
    if (select status from ip_tables where id = t) = 'open' then
      for u in select player_id from ip_members where table_id = t and left_at is null loop
        perform ipt.leave_(u, t);
      end loop;
      if (ipt.hand(t)).phase <> 'done' then perform ipt.finish(t); end if;
    end if;
  end loop;

  select sum(chips) into total_after from players where id = any(pl);
  select coalesce(sum(s.payout - s.put), 0) into bot_net
  from ip_hand_seats s join ip_hands hh on hh.id = s.hand_id
  where s.player_id is null and hh.table_id in (select distinct m.table_id from ip_members m where m.player_id = any(pl));

  perform ipt.chk('시뮬: 판 수', hands >= 100, hands || '판, 단계 ' || steps);
  select count(*) into bad from (
    select hh.id from ip_hands hh join ip_hand_seats s on s.hand_id = hh.id
    where hh.table_id in (select distinct m.table_id from ip_members m where m.player_id = any(pl))
    group by hh.id having sum(s.payout) is distinct from sum(s.put) or bool_or(s.payout is null)) z;
  perform ipt.chk('시뮬: 판마다 지급 합 = 판돈', bad = 0, bad || '판 어긋남');
  perform ipt.chk('시뮬: 칩 보존 (사람 칩 변화 = −컴퓨터 순수익)', total_after - total_before = -bot_net,
    total_before || ' → ' || total_after || ', 컴퓨터 ' || bot_net);
  perform ipt.chk('시뮬: 음수 칩 없음', not exists (select 1 from players where id = any(pl) and chips < 0));

  -- 올인한 자리는 각 상대에게서 자기가 낸 만큼까지만
  select count(*) into bad from ip_hand_seats a
  join ip_hands hh on hh.id = a.hand_id
  where a.all_in and hh.table_id in (select distinct m.table_id from ip_members m where m.player_id = any(pl))
    -- 이탈로 접은 사람이 더 많이 낸 판은 그 칩이 남은 사람에게 가므로 뺀다
    and not exists (select 1 from ip_hand_seats f where f.hand_id = a.hand_id and f.folded
                    and f.put > (select max(put) from ip_hand_seats l where l.hand_id = a.hand_id and not l.folded))
    and a.payout > (select sum(least(o.put, a.put)) from ip_hand_seats o where o.hand_id = a.hand_id);
  perform ipt.chk('시뮬: 올인은 낸 만큼만 땀', bad = 0, bad::text);
  select count(*) into bad from ip_hand_seats a join ip_hands hh on hh.id = a.hand_id
  where a.all_in and hh.table_id in (select distinct m.table_id from ip_members m where m.player_id = any(pl));
  perform ipt.chk('시뮬: 올인이 실제로 나옴', bad > 10, bad || '자리');
  select count(*) into bad from ip_hands hh
  where hh.table_id in (select distinct m.table_id from ip_members m where m.player_id = any(pl))
    and (select count(distinct put) from ip_hand_seats s where s.hand_id = hh.id and not s.folded) >= 2;
  perform ipt.chk('시뮬: 사이드팟 판이 실제로 나옴', bad > 5, bad || '판');

  -- 메인 팟(접지 않은 사람 중 가장 적게 낸 금액까지)은 접지 않은 최고 카드 자리가 가져감 → 그 자리 지급 ≥ 메인 팟 몫
  select count(*) into bad from ip_hands hh
  cross join lateral (
    select min(s.put) as lo, max(c.card) as best from ip_hand_seats s join ip_cards c using (hand_id, seat)
    where s.hand_id = hh.id and not s.folded) m
  where hh.table_id in (select distinct mm.table_id from ip_members mm where mm.player_id = any(pl))
    and (select count(*) from ip_hand_seats s join ip_cards c using (hand_id, seat) where s.hand_id = hh.id and not s.folded and c.card = m.best) = 1
    and (select s.payout from ip_hand_seats s join ip_cards c using (hand_id, seat) where s.hand_id = hh.id and not s.folded and c.card = m.best)
        < (select sum(least(s.put, m.lo)) from ip_hand_seats s where s.hand_id = hh.id);
  perform ipt.chk('시뮬: 최고 카드가 메인 팟을 가져감', bad = 0, bad || '판 어긋남');

  -- 행동 분포 (참고)
  perform ipt.chk('시뮬: 체크·베팅·콜·레이즈·폴드가 모두 나옴',
    (select count(distinct last_action) from ip_hand_seats s join ip_hands hh on hh.id = s.hand_id
     where hh.table_id in (select distinct m.table_id from ip_members m where m.player_id = any(pl))
       and last_action in ('check', 'bet', 'call', 'raise', 'fold')) = 5);
  raise notice '시뮬 % 판, 컴퓨터 순수익 %, 사람 칩 % → %', hands, bot_net, total_before, total_after;
end $$;

select name, case when ok then 'PASS' else 'FAIL' end as result, detail from ipt.t_log order by ctid;
select count(*) filter (where not ok) as failures, count(*) as total from ipt.t_log;
rollback;
