-- 소수결: 둘 중 하나를 500칩 걸고 고르면, 적게 고른 쪽이 이긴다 (ADR-0013, docs/chip-economy.md)
--
-- 평일(KST) 8·11·14시에 판이 열리고 3시간 뒤(11·14·17시) 정산. 질문은 미리 넣어 둔 것 중 무작위, 쓰면 used_at.
-- 정산: 참가 3명 미만 / 동점 / 전원 일치면 무효(전액 돌려줌). 아니면 소수 쪽이 진 사람 칩을 똑같이 나눈다(내림).
-- 홀짝처럼 지연 정산: 누가 minority_tick()을 부르면 지난 판을 정산하고 지금 판을 연다 (ADR-0003)
-- 마감 전엔 남이 뭘 골랐는지 안 보인다 (참가 인원만). 정산 뒤엔 이름까지 공개

create table public.minority_questions (
  id       int primary key,
  prompt   text not null,
  option_a text not null,
  option_b text not null,
  used_at  timestamptz
);

create table public.minority_rounds (
  id          bigint generated always as identity primary key,
  question_id int not null references public.minority_questions (id),
  opens_at    timestamptz not null unique,
  closes_at   timestamptz not null,
  settled_at  timestamptz,
  a_count     int,
  b_count     int,
  winner      smallint check (winner in (0, 1)), -- null = 무효 또는 정산 전
  created_at  timestamptz not null default now()
);

create table public.minority_picks (
  round_id   bigint not null references public.minority_rounds (id) on delete cascade,
  player_id  uuid not null references public.players (id) on delete cascade,
  choice     smallint not null check (choice in (0, 1)),
  amount     bigint not null check (amount > 0),
  payout     bigint, -- 정산 후 채워짐 (0 = 짐, amount = 무효로 돌려받음)
  created_at timestamptz not null default now(),
  primary key (round_id, player_id)
);
create index minority_picks_created_idx on public.minority_picks (created_at);

alter table public.minority_questions enable row level security;
alter table public.minority_rounds    enable row level security;
alter table public.minority_picks     enable row level security;
-- 쓴 질문만 읽힌다 (앞으로 나올 질문은 비밀)
create policy "read used questions" on public.minority_questions for select to authenticated using (used_at is not null);
create policy "read rounds"         on public.minority_rounds    for select to authenticated using (true);
-- 내 선택은 늘, 남의 선택은 정산 뒤에만
create policy "read picks" on public.minority_picks for select to authenticated using (
  player_id = auth.uid()
  or exists (select 1 from public.minority_rounds r where r.id = round_id and r.settled_at is not null)
);

insert into public.minority_questions (id, prompt, option_a, option_b) values
  (1,  '들여쓰기는',          '탭',        '스페이스'),
  (2,  '브랜치 합칠 땐',      'rebase',    'merge'),
  (3,  '에디터 테마',         '다크',      '라이트'),
  (4,  '금요일 오후 배포',    '한다',      '안 한다'),
  (5,  'Claude가 짠 코드',    '바로 커밋', '읽고 커밋'),
  (6,  '아침 첫 잔',          '아아',      '뜨아'),
  (7,  '커밋 메시지는',       '한국어',    '영어'),
  (8,  '에러가 나면',         '로그부터',  'Claude부터'),
  (9,  '작업할 때 음악',      '가사 있음', '가사 없음'),
  (10, '일하기 좋은 카페',    '조용한 곳', '적당히 소란'),
  (11, '429에 걸리면',        '쉰다',      '다른 도구로'),
  (12, '먼저 쓰는 건',        '테스트',    '코드'),
  (13, '주석은',              '꼼꼼히',    '코드로 말함'),
  (14, '모니터는',            '한 대',     '여러 대'),
  (15, '키보드는',            '기계식',    '노트북 그대로'),
  (16, '원두 취향',           '산미',      '고소'),
  (17, '커피는',              '핸드드립',  '에스프레소'),
  (18, '집중이 잘 되는 시간', '밤',        '새벽'),
  (19, '리팩터링은',          '지금',      '나중에'),
  (20, '프롬프트는',          '길게',      '짧게'),
  (21, '정리는',              '회의로',    '문서로'),
  (22, '점심은',              '혼밥',      '같이'),
  (23, '사이드 프로젝트',     '끝까지',    '새로 시작'),
  (24, '알림은',              '다 켬',     '다 끔'),
  (25, '터미널은',            '기본 그대로', '잔뜩 꾸밈'),
  (26, '열어 둔 브라우저 탭', '10개 이하', '50개 이상'),
  (27, '앉는 자리',           '창가',      '벽 쪽'),
  (28, '퇴근 후 코딩',        '한다',      '안 한다'),
  (29, 'git은',               'CLI',       'GUI'),
  (30, '마감은',              '미리미리',  '전날 몰아서'),
  (31, '오늘 할 일 목록',     '종이',      '앱'),
  (32, '새 프로젝트 첫 파일', 'README',    '코드'),
  (33, '돈을 쓴다면',         '의자',      '모니터'),
  (34, '페어 프로그래밍',     '좋다',      '혼자가 좋다'),
  (35, '첫 커밋 메시지',      'init',      'Initial commit'),
  (36, '겨울 음료',           '라떼',      '차'),
  (37, '버전 올리기',         '신중히',    '일단 올림'),
  (38, '카페 디저트',         '케이크',    '쿠키'),
  (39, '코드 리뷰 코멘트',    '칭찬부터',  '본론부터'),
  (40, '빌드 기다리는 동안',  '429 Lounge', '딴짓 안 함');

-- 첫 판: 2026-11-20(금) 14시 판은 4번 질문으로
update public.minority_questions set used_at = now() where id = 4;
insert into public.minority_rounds (question_id, opens_at, closes_at)
values (4, '2026-11-20 14:00:00+09', '2026-11-20 17:00:00+09');

-- ts가 속한 판의 여는 시각. 평일 8~17시(KST) 밖이면 null
create function public.minority_slot(ts timestamptz)
returns timestamptz
language sql stable set search_path = public as $$
  select case
    when extract(isodow from ts at time zone 'Asia/Seoul') between 1 and 5
     and extract(hour from ts at time zone 'Asia/Seoul') between 8 and 16
    then (date_trunc('day', ts at time zone 'Asia/Seoul')
          + make_interval(hours => 8 + 3 * ((extract(hour from ts at time zone 'Asia/Seoul')::int - 8) / 3)))
         at time zone 'Asia/Seoul'
  end
$$;

-- ts 뒤에 열리는 첫 판
create function public.minority_next_open(ts timestamptz)
returns timestamptz
language sql stable set search_path = public as $$
  select min(s) from (
    select (date_trunc('day', ts at time zone 'Asia/Seoul') + make_interval(days => d, hours => h)) at time zone 'Asia/Seoul' as s
    from generate_series(0, 7) d, unnest(array[8, 11, 14]) h
  ) x
  where s > ts and extract(isodow from s at time zone 'Asia/Seoul') between 1 and 5
$$;

-- 한 판 정산 (내부용)
create function public.minority_settle(p_round bigint)
returns void
language plpgsql security definer set search_path = public as $$
declare
  a int; b int; w smallint; winners int; losers int; share bigint;
begin
  select count(*) filter (where choice = 0), count(*) filter (where choice = 1)
    into a, b from minority_picks where round_id = p_round;

  if a + b < 3 or a = b or a = 0 or b = 0 then
    w := null; -- 무효: 전액 돌려줌
    update minority_picks set payout = amount where round_id = p_round;
  else
    w := case when a < b then 0 else 1 end;
    winners := least(a, b);
    losers  := greatest(a, b);
    share := (losers * 500) / winners;
    update minority_picks set payout = case when choice = w then amount + share else 0 end where round_id = p_round;
  end if;

  update players p set chips = p.chips + mp.payout
  from minority_picks mp
  where mp.round_id = p_round and mp.player_id = p.id and mp.payout > 0;

  update minority_rounds set settled_at = now(), a_count = a, b_count = b, winner = w where id = p_round;
end $$;

-- 지난 판 정산 + 지금 판 열기 + 화면에 필요한 상태
create function public.minority_tick()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  slot timestamptz := minority_slot(now());
  q int;
  cur minority_rounds;
  mine record;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(4290);

  -- 지난 판 정산
  for cur in select * from minority_rounds where settled_at is null and closes_at <= now() order by id loop
    perform minority_settle(cur.id);
  end loop;

  -- 지금 판 열기: 안 쓴 질문 중 무작위, 다 썼으면 가장 오래전에 쓴 것
  if slot is not null and not exists (select 1 from minority_rounds where opens_at = slot) then
    select id into q from minority_questions order by used_at nulls first, random() limit 1;
    update minority_questions set used_at = now() where id = q;
    insert into minority_rounds (question_id, opens_at, closes_at) values (q, slot, slot + interval '3 hours');
  end if;

  select * into cur from minority_rounds where opens_at = slot and settled_at is null;

  -- 내가 참가한 가장 최근 정산된 판 (결과 알림, 쉬는 시간 한 줄)
  select r.id, qq.prompt, qq.option_a, qq.option_b, r.winner, r.a_count, r.b_count, mp.choice, mp.payout - mp.amount as net
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
        'closes_at', cur.closes_at,
        'participants', (select count(*) from minority_picks where round_id = cur.id),
        'my_pick', (select choice from minority_picks where round_id = cur.id and player_id = me))
      from minority_questions qq where qq.id = cur.question_id) end,
    'next_opens_at', minority_next_open(now()),
    'mine', case when mine.id is null then null else jsonb_build_object(
      'id', mine.id, 'question', mine.prompt, 'option_a', mine.option_a, 'option_b', mine.option_b,
      'winner', mine.winner, 'a_count', mine.a_count, 'b_count', mine.b_count,
      'choice', mine.choice, 'net', mine.net,
      'picks', (select jsonb_agg(jsonb_build_object('name', pl.name, 'choice', mp2.choice, 'me', mp2.player_id = me)
                                 order by mp2.created_at)
                from minority_picks mp2 join players pl on pl.id = mp2.player_id
                where mp2.round_id = mine.id)) end
  );
end $$;

-- 500칩 걸고 고르기
create function public.minority_pick(p_choice int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  cur minority_rounds;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if p_choice not in (0, 1) then raise exception 'invalid_choice'; end if;
  if not exists (select 1 from players where id = me and named) then raise exception 'not_named'; end if;

  perform minority_tick();
  select * into cur from minority_rounds
  where opens_at = minority_slot(now()) and settled_at is null and closes_at > now();
  if cur.id is null then raise exception 'minority_closed'; end if;
  if exists (select 1 from minority_picks where round_id = cur.id and player_id = me) then
    raise exception 'already_picked';
  end if;

  update players set chips = chips - 500 where id = me and chips >= 500;
  if not found then raise exception 'insufficient_chips'; end if;

  insert into minority_picks (round_id, player_id, choice, amount) values (cur.id, me, p_choice, 500);
  return minority_tick();
exception
  when unique_violation then raise exception 'already_picked';
end $$;

-- 이번 주 큰손에 소수결도 (ADR-0012)
create or replace view public.game_results as
  select player_id, 'slot'::text as game,
         payout - case when golden then 0 else amount end as net,
         created_at as played_at
  from public.slot_spins
  union all
  select player_id, 'oddeven', payout - case when golden then 0 else amount end, created_at
  from public.oddeven_bets
  where payout is not null
  union all
  select player_id, 'minority', payout - amount, created_at
  from public.minority_picks
  where payout is not null;

revoke all on public.game_results from public, anon, authenticated;

revoke execute on function public.minority_settle(bigint)   from public, anon, authenticated;
revoke execute on function public.minority_slot(timestamptz)      from public, anon;
revoke execute on function public.minority_next_open(timestamptz) from public, anon;
revoke execute on function public.minority_tick()          from public, anon;
revoke execute on function public.minority_pick(int)       from public, anon;
grant  execute on function public.minority_tick()          to authenticated;
grant  execute on function public.minority_pick(int)       to authenticated;
