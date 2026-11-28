-- 429 드롭 4·2·9 단계 전이와 포켓 빈도를 로컬 DB에서 재현한다 (서버 `plinko_resolve`를 직접 부른다).
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v n=250000 -v power=854 -f scripts/drop_stage_sim.sql
-- power: 854 = PERFECT(834~874), 800 = GOOD, 0 = 기본. 랜덤(AUTO)은 -v power='floor(random()*1001)::int'
-- 확률 경제를 바꾸는 스크립트가 아니다. 단계 규칙(0→1→2→3→0, FEVER면 0)이 지켜지는지 보는 확인용이고,
-- 환수율은 FEVER 분산이 커서 25만 공으로도 ±1.5%p 흔들린다. 비교는 포켓 빈도로 한다.
\if :{?n} \else \set n 250000 \endif
\if :{?power} \else \set power 854 \endif
create temp table sim (lv int, la int, pocket bool, fever bool, payout bigint);
-- psql 변수는 $$ 안에서 안 풀려서 DO 문을 문자열로 만들어 실행한다
select format($do$
do $b$
declare lv int := 0; r jsonb; p bool;
begin
  for i in 1..%s loop
    r := plinko_resolve(50, 0, plinko_grade(%s), false, lv);
    p := (r->'pocket') is not null and r->'pocket' <> 'null'::jsonb;
    insert into sim values (lv, (r->>'letters')::int, p, (r->>'fever')::bool, (r->>'payout')::bigint);
    lv := (r->>'letters')::int;
  end loop;
end $b$
$do$, :n, :'power') \gexec
-- 전이표: 포켓에 들어간 판의 (이전 단계, 종류) → 이후 단계. FEVER는 늘 0, HOT(3)의 일반 포켓도 0
select lv as before, case when fever then 'FEVER' else 'pocket' end as kind, la as after, count(*)
from sim where pocket group by 1, 2, 3 order by 1, 2;
-- 요약
select count(*) balls,
       round(100.0 * sum(payout) / (50 * count(*)), 2) as rtp_pct,
       round(100.0 * count(*) filter (where pocket) / count(*), 3) as pocket_pct,
       round(count(*)::numeric / count(*) filter (where pocket), 1) as balls_per_pocket,
       round(count(*)::numeric / count(*) filter (where fever), 0) as balls_per_fever,
       round(100.0 * count(*) filter (where lv = 3) / count(*), 1) as pct_balls_in_hot
from sim;
