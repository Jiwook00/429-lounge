-- 닉네임
--  - 처음 들어오면 "손님 3F2A9C" 같은 임시 이름. macOS 계정명은 서버로 보내지 않는다.
--  - 회원이 직접 정한 이름만 named = true. 앱은 named = false면 이름부터 정하게 한다.
--  - 이름은 라운지 전체에서 하나뿐 (대소문자 무시). 같은 이름으로 남을 사칭하지 못하게.

alter table public.players add column named boolean not null default false;
update public.players set named = true; -- 기존 회원은 이미 이름이 있는 걸로 본다

-- 중복 이름 정리: 먼저 들어온 사람이 이름을 갖고, 나머지는 손님으로 돌려서 다시 정하게 한다
update public.players p
set name = '손님 ' || upper(left(replace(p.id::text, '-', ''), 6)), named = false
where exists (
  select 1 from public.players o
  where lower(o.name) = lower(p.name) and (o.created_at, o.id) < (p.created_at, p.id)
);

create unique index players_name_unique on public.players (lower(name));

-- ensure_player(p_name): 매 접속마다 이름을 덮어쓰던 것 → 이름 없이 행만 보장
drop function public.ensure_player(text);

create function public.ensure_player()
returns public.players
language plpgsql security definer set search_path = public as $$
declare
  me public.players;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into players (id, name)
  values (auth.uid(), '손님 ' || upper(left(replace(auth.uid()::text, '-', ''), 6)))
  on conflict (id) do nothing;
  select * into me from players where id = auth.uid();
  return me;
end $$;

-- 닉네임 정하기 / 바꾸기. 앞뒤 공백은 지우고 1~12자, 줄바꿈 같은 제어 문자는 거절.
create function public.set_nickname(p_name text)
returns public.players
language plpgsql security definer set search_path = public as $$
declare
  v  text := btrim(coalesce(p_name, ''));
  me public.players;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if char_length(v) not between 1 and 12 or v ~ '[[:cntrl:]]' then
    raise exception 'invalid_nickname';
  end if;
  update players set name = v, named = true where id = auth.uid() returning * into me;
  if me.id is null then raise exception 'no_player'; end if;
  return me;
exception when unique_violation then
  raise exception 'nickname_taken';
end $$;

revoke execute on function public.ensure_player()     from public, anon;
revoke execute on function public.set_nickname(text)  from public, anon;
grant  execute on function public.ensure_player()     to authenticated;
grant  execute on function public.set_nickname(text)  to authenticated;
