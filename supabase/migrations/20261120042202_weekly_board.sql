-- 이번 주 큰손: 주간 순수익 순위 (ADR-0012)
--
-- 순수익 = 지급액 - 실제로 건 칩 (황금 칩 베팅은 건 칩 0). 토큰 환전·출근 도장·파산 구제는 빼서
-- 요금제 차이 없이 테이블 위 성적만 센다. 주는 KST 월요일 00시부터.
--
-- 모든 게임의 한 판 결과는 game_results 뷰 하나로 모은다.
-- 새 게임을 만들면 이 뷰를 다시 만들어 union all 한 줄을 더한다 (CLAUDE.md "꼭 지킬 것").

create view public.game_results as
  select player_id, 'slot'::text as game,
         payout - case when golden then 0 else amount end as net,
         created_at as played_at
  from public.slot_spins
  union all
  -- 홀짝은 정산이 끝난 베팅만 (payout이 채워진 것)
  select player_id, 'oddeven', payout - case when golden then 0 else amount end, created_at
  from public.oddeven_bets
  where payout is not null;

-- 뷰는 소유자 권한으로 돌아 RLS를 건너뛴다 → 클라이언트에선 못 읽게 막고 weekly_board()로만
revoke all on public.game_results from public, anon, authenticated;

create index slot_spins_created_idx   on public.slot_spins (created_at);
create index oddeven_bets_created_idx on public.oddeven_bets (created_at);

-- 이번 주 큰손 위 p_top명 + (그 밖이면) 내 줄. 이번 주에 한 판이라도 한, 닉네임을 정한 회원만
create function public.weekly_board(p_top int default 3)
returns table (rank int, name text, net bigint, me boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  week_start timestamptz := date_trunc('week', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  return query
  with totals as (
    select r.player_id, sum(r.net)::bigint as net
    from game_results r
    where r.played_at >= week_start
    group by r.player_id
  ), ranked as (
    select (rank() over (order by t.net desc))::int as rank, p.name, t.net, p.id = auth.uid() as me
    from totals t join players p on p.id = t.player_id
    where p.named
  )
  select x.rank, x.name, x.net, x.me
  from ranked x
  where x.rank <= least(greatest(p_top, 1), 10) or x.me
  order by x.rank, x.name;
end $$;

revoke execute on function public.weekly_board(int) from public, anon;
grant  execute on function public.weekly_board(int) to authenticated;
