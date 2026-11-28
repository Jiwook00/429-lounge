-- 소수결 은퇴 (ADR-0022). 이용이 적어(11/20~11/28 16판, 참가 34건) 앱에서 뺀다.
--
-- 테이블과 지난 기록은 그대로 둔다 (`game_results`의 소수결 기록 = 이번 주 큰손도 그대로, 뷰는 다시 만들지 않는다).
-- 막는 것: 새 참가(minority_pick)와 새 판 열기(minority_tick). 이미 열린 판의 정산은 계속한다 → 칩이 갇히지 않는다.
-- 시그니처가 같아 create or replace로 권한(grant)이 그대로 유지된다. 홀짝 은퇴(ADR-0015)와 같은 방식.
-- 옛 앱은 소수결 화면이 있으니 min_version을 올려 안내 카드를 띄운다 (ADR-0010).
--
-- 적용 시점: 새 앱(0.16.0)을 배포한 뒤. 새 앱은 minority_tick을 부르지 않으므로,
-- 열린 판이 남아 있으면 정산이 늦어진다 → 마지막 판(평일 14시 → 17시 마감)이 끝난 뒤나 주말에 적용하고,
-- 이 파일 끝의 정산 루프가 적용 시점에 마감된 판을 모두 정산한다.

create or replace function public.minority_pick(p_choice int)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'game_retired';
end $$;

-- 마감 지난 판 정산 + 상태만. 새 판은 열지 않는다 (minority_next_open은 null → 앱 타일엔 "다음 판 없음")
create or replace function public.minority_tick()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  cur minority_rounds;
  mine record;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(4290);

  -- 지난 판 정산 (진행 중이던 판)
  for cur in select * from minority_rounds where settled_at is null and closes_at <= now() order by id loop
    perform minority_settle(cur.id);
  end loop;

  -- 아직 안 닫힌 판 (옛 앱이 화면에 그린다)
  select * into cur from minority_rounds where settled_at is null and closes_at > now() order by id desc limit 1;

  select r.id, qq.prompt, qq.option_a, qq.option_b, r.winner, r.a_count, r.b_count, mp.choice, mp.amount, mp.payout - mp.amount as net
    into mine
  from minority_picks mp
  join minority_rounds r on r.id = mp.round_id
  join minority_questions qq on qq.id = r.question_id
  where mp.player_id = me and r.settled_at is not null
  order by r.id desc limit 1;

  return jsonb_build_object(
    'round', case when cur.id is null then null else (
      select jsonb_build_object(
        'id', cur.id, 'question', qq.prompt, 'option_a', qq.option_a, 'option_b', qq.option_b,
        'closes_at', cur.closes_at, 'stake', cur.stake,
        'participants', (select count(*) from minority_picks where round_id = cur.id),
        'my_pick', (select choice from minority_picks where round_id = cur.id and player_id = me))
      from minority_questions qq where qq.id = cur.question_id) end,
    'next_opens_at', null,
    'mine', case when mine.id is null then null else jsonb_build_object(
      'id', mine.id, 'question', mine.prompt, 'option_a', mine.option_a, 'option_b', mine.option_b,
      'winner', mine.winner, 'a_count', mine.a_count, 'b_count', mine.b_count,
      'choice', mine.choice, 'amount', mine.amount, 'net', mine.net,
      'picks', (select jsonb_agg(jsonb_build_object('name', pl.name, 'choice', mp2.choice, 'me', mp2.player_id = me)
                                 order by mp2.created_at)
                from minority_picks mp2 join players pl on pl.id = mp2.player_id
                where mp2.round_id = mine.id)) end
  );
end $$;

update public.client_policy set min_version = '0.16.0';

-- 적용 시점에 이미 마감된 판은 지금 정산한다 (새 앱은 minority_tick을 부르지 않는다)
do $$
declare r record;
begin
  for r in select id from public.minority_rounds where settled_at is null and closes_at <= now() order by id loop
    perform public.minority_settle(r.id);
  end loop;
end $$;
