-- 픽셀 보드 (ADR-0017): 칩과 무관한 무료 공용 벽.
-- 32×32칸, 색 8개. KST 월요일마다 새 벽(지난 벽은 남겨 둔다).
-- 칠하기는 토큰 버킷: 최대 10개, 30초마다 1개 충전. 같은 색 덧칠은 차감 없음(304).
-- 칩·지갑·game_results와 무관하다 (이번 주 큰손에 안 들어감).

create table public.pixel_board (
  week date not null,
  x smallint not null check (x between 0 and 31),
  y smallint not null check (y between 0 and 31),
  color smallint not null check (color between 0 and 7),
  player_id uuid not null references public.players(id) on delete cascade,
  painted_at timestamptz not null,
  primary key (week, x, y)
);
alter table public.pixel_board enable row level security;
revoke all on public.pixel_board from public, anon, authenticated;
-- Realtime 변경 신호를 받으려면 읽기 권한이 필요하다. 벽은 모두에게 공개.
grant select on public.pixel_board to authenticated;
create policy "픽셀 보드 조회" on public.pixel_board for select to authenticated using (true);

-- 회원별 버킷. tokens = refill_from 시점의 개수, refill_from이 null이면 가득 참
create table public.pixel_buckets (
  player_id uuid primary key references public.players(id) on delete cascade,
  tokens smallint not null,
  refill_from timestamptz
);
alter table public.pixel_buckets enable row level security;
revoke all on public.pixel_buckets from public, anon, authenticated;

-- 지금 시각 기준 버킷 (저장하지 않고 계산만)
create function public.pixel_bucket_at(p_tokens integer, p_from timestamptz, t timestamptz,
  out tokens integer, out refill_from timestamptz)
language plpgsql immutable set search_path = '' as $$
declare
  gained integer;
begin
  if p_from is null then
    tokens := coalesce(p_tokens, 10);
    refill_from := null;
    return;
  end if;
  gained := greatest(0, floor(extract(epoch from (t - p_from)) / 30)::integer);
  tokens := least(10, p_tokens + gained);
  refill_from := case when tokens >= 10 then null else p_from + gained * interval '30 seconds' end;
end $$;
revoke all on function public.pixel_bucket_at(integer, timestamptz, timestamptz) from public, anon, authenticated;

-- 이번 주 벽 + 내 버킷 + 칸을 많이 가진 회원
create function public.pixel_state(uid uuid, t timestamptz)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  w date := date_trunc('week', t at time zone 'Asia/Seoul')::date;
  b record;
  bucket record;
begin
  select * into b from public.pixel_buckets where player_id = uid;
  select * into bucket from public.pixel_bucket_at(b.tokens, b.refill_from, t);
  return jsonb_build_object(
    'now', t,
    'week', w,
    'cap', 10,
    'refill', 30,
    'left', bucket.tokens,
    'next_at', bucket.refill_from + interval '30 seconds',
    'pixels', coalesce((
      select jsonb_agg(jsonb_build_object('x', p.x, 'y', p.y, 'c', p.color, 'p', pl.name, 'at', p.painted_at))
      from public.pixel_board p join public.players pl on pl.id = p.player_id
      where p.week = w), '[]'::jsonb),
    'painters', coalesce((
      select jsonb_agg(jsonb_build_object('name', s.name, 'count', s.n, 'me', s.id = uid) order by s.n desc, s.last desc)
      from (
        select pl.id, pl.name, count(*) as n, max(p.painted_at) as last
        from public.pixel_board p join public.players pl on pl.id = p.player_id
        where p.week = w group by pl.id, pl.name
      ) s), '[]'::jsonb)
  );
end $$;
revoke all on function public.pixel_state(uuid, timestamptz) from public, anon, authenticated;

create function public.pixel_board()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  return public.pixel_state(auth.uid(), clock_timestamp());
end $$;
revoke all on function public.pixel_board() from public, anon;
grant execute on function public.pixel_board() to authenticated;

-- status: created(칠함) / same(같은 색, 차감 없음) / limited(429, 버킷이 빔)
create function public.pixel_paint(p_x integer, p_y integer, p_color integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  t timestamptz := clock_timestamp();
  w date := date_trunc('week', t at time zone 'Asia/Seoul')::date;
  b public.pixel_buckets;
  bucket record;
  current_color smallint;
  status text;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from public.players where id = uid and named) then raise exception 'not_named'; end if;
  if p_x is null or p_y is null or p_color is null
     or p_x not between 0 and 31 or p_y not between 0 and 31 or p_color not between 0 and 7
  then raise exception 'invalid_pixel'; end if;

  insert into public.pixel_buckets values (uid, 10, null) on conflict (player_id) do nothing;
  select * into strict b from public.pixel_buckets where player_id = uid for update;
  select * into bucket from public.pixel_bucket_at(b.tokens, b.refill_from, t);

  select color into current_color from public.pixel_board where week = w and x = p_x and y = p_y;
  if current_color = p_color then
    status := 'same';
  elsif bucket.tokens <= 0 then
    status := 'limited';
  else
    insert into public.pixel_board values (w, p_x, p_y, p_color, uid, t)
      on conflict (week, x, y) do update
      set color = excluded.color, player_id = excluded.player_id, painted_at = excluded.painted_at;
    update public.pixel_buckets
      set tokens = bucket.tokens - 1, refill_from = coalesce(bucket.refill_from, t)
      where player_id = uid;
    status := 'created';
  end if;

  return public.pixel_state(uid, t) || jsonb_build_object('status', status);
end $$;
revoke all on function public.pixel_paint(integer, integer, integer) from public, anon;
grant execute on function public.pixel_paint(integer, integer, integer) to authenticated;

alter publication supabase_realtime add table public.pixel_board;
