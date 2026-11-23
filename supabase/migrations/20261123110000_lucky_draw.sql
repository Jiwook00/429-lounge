-- 티켓은 게임 베팅이 아닌 지급 기록이다. 주간 순수익에는 합산하지 않는다.
create table public.lucky_tickets (
  player_id uuid not null references public.players(id) on delete cascade,
  day date not null,
  number smallint not null check (number between 1 and 3),
  amount integer not null check (amount in (50, 100, 200, 300, 429)),
  claimed_at timestamptz not null,
  primary key (player_id, day, number)
);
alter table public.lucky_tickets enable row level security;
revoke all on public.lucky_tickets from public, anon, authenticated;
grant select on public.lucky_tickets to authenticated;
create policy "본인 티켓 조회" on public.lucky_tickets for select to authenticated
using (player_id = (select auth.uid()));

create function public.scratch_ticket(p_day date, p_number integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  wallet public.players;
  ticket public.lucky_tickets;
  last_ticket public.lucky_tickets;
  t timestamptz;
  roll integer;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select * into strict wallet from public.players where id = uid for update;
  t := clock_timestamp();
  -- 같은 티켓의 응답을 잃어버린 경우 이미 확정된 결과를 다시 반환한다.
  select * into ticket from public.lucky_tickets
    where player_id = uid and day = p_day and number = p_number;
  if not found then
    select * into last_ticket from public.lucky_tickets where player_id = uid and day = p_day
      order by number desc limit 1;
    if p_day is distinct from (t at time zone 'Asia/Seoul')::date
       or p_number is distinct from coalesce(last_ticket.number, 0) + 1
       or p_number not between 1 and 3
       or t < last_ticket.claimed_at + interval '2 hours'
    then raise exception 'ticket_unavailable'; end if;
    roll := floor(random() * 100)::integer;
    insert into public.lucky_tickets values
      (uid,p_day,p_number,case when roll < 36 then 100 when roll < 63 then 200
       when roll < 78 then 50 when roll < 90 then 300 else 429 end,t)
      returning * into ticket;
    update public.players set chips = chips + ticket.amount where id = uid returning * into wallet;
  end if;
  return jsonb_build_object('ticket', to_jsonb(ticket), 'player', to_jsonb(wallet));
end $$;
revoke all on function public.scratch_ticket(date, integer) from public, anon;
grant execute on function public.scratch_ticket(date, integer) to authenticated;
