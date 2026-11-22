-- 지난주 내 순위 (ADR-0012 추기). 칩 화면에 "지난주 3위"로 보여준다
--
-- 집계는 weekly_board와 같은 game_results 뷰, 기간만 지난주(KST 월~일). 동점이면 같은 순위.
-- 지난주에 한 판도 안 했거나 닉네임을 안 정했으면 행이 없다. 새 함수만 더하므로 옛 앱은 그대로 돈다.

create function public.last_week_rank()
returns table (rank int, net bigint)
language plpgsql stable security definer set search_path = public as $$
declare
  this_week timestamptz := date_trunc('week', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  last_week timestamptz := this_week - interval '7 days';
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  return query
  with totals as (
    select r.player_id, sum(r.net)::bigint as net
    from game_results r
    where r.played_at >= last_week and r.played_at < this_week
    group by r.player_id
  ), ranked as (
    select (rank() over (order by t.net desc))::int as rank, t.net, t.player_id
    from totals t join players p on p.id = t.player_id
    where p.named
  )
  select x.rank, x.net from ranked x where x.player_id = auth.uid();
end $$;

revoke execute on function public.last_week_rank() from public, anon;
grant  execute on function public.last_week_rank() to authenticated;
