-- 앱 최소 버전 (ADR-0010)
--  - RPC 시그니처를 바꾸는 마이그레이션이면 같은 파일에서 min_version을 올린다.
--    그보다 낮은 앱은 테이블을 막고 업데이트 안내만 보여준다.
--  - 한 줄짜리 테이블. 쓰기는 마이그레이션(또는 대시보드 SQL)으로만.

create table public.client_policy (
  id          boolean primary key default true check (id),
  min_version text not null default '0.0.0' check (min_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$')
);
insert into public.client_policy default values;

alter table public.client_policy enable row level security;
-- 로그인 전에도 읽을 수 있게 anon까지
create policy "read client policy" on public.client_policy for select to anon, authenticated using (true);

revoke insert, update, delete, truncate on public.client_policy from anon, authenticated;
