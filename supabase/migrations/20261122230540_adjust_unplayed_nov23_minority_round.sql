-- 11월 23일 오전 8시 소수결은 참가하기 전까지만 50칩으로 조정한다.
do $$
begin
  -- 소수결 참가와 같은 잠금으로 참가자 확인과 변경을 한 트랜잭션에 묶는다.
  perform pg_advisory_xact_lock(4290);

  update public.minority_rounds r
  set stake = 50
  where r.opens_at = timestamptz '2026-11-23 08:00:00+09'
    and r.stake = 200
    and r.settled_at is null
    and r.closes_at > clock_timestamp()
    and not exists (
      select 1 from public.minority_picks p where p.round_id = r.id
    );
end $$;
