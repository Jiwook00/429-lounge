# 429 Lounge

Claude Code와 Codex 토큰 사용량을 칩으로 바꿔 회원들과 짧은 카지노 게임을 즐기는 macOS 메뉴바 앱.
개요는 [README.md](README.md), 디자인은 [DESIGN.md](DESIGN.md), 결정 기록은 [docs/madr/](docs/madr/)을 참고한다.

> **앱을 "설치"해 달라는 요청이면** 개발 환경(Supabase, swift build)을 세우지 말고 [docs/install.md](docs/install.md)를 따른다. 아래 내용은 개발용이다.

## Claude Code와 Codex 협업

- 두 에이전트의 공통 작업 규칙은 이 파일에서 관리한다. `CLAUDE.md`는 `@AGENTS.md`로 이 파일을 불러온다.
- 기획이나 기능 설계를 시작할 때 `PLANNING.local.md`가 있으면 읽는다. 제품 의도와 아이디어를 담은 로컬 전용 문서다. 현재 구현은 코드와 README에서, 빌드 버전은 `scripts/build-app.sh`의 `VERSION`에서, 배포 상태는 GitHub 릴리스 기록에서 확인한다. 로컬 기획과 개인적인 맥락은 공개 저장소에 올리지 않는다.
- 작업을 이어받으면 현재 브랜치, `git status --short`, `git diff`, `git diff --cached`를 확인하고 기존 변경을 보존한다. 순차 작업은 같은 브랜치와 작업 디렉터리에서 이어가고, 동시에 수정해야 할 때는 작업별 브랜치와 worktree를 사용한다.
- 미완료 작업을 넘길 때는 작업 목표와 현재 브랜치, 커밋 또는 미커밋 변경, 확정된 결정, 실행한 검증과 결과, 바로 이어서 할 일을 짧게 남긴다.
- 개발과 테스트는 로컬 Supabase를 기본으로 한다. 운영 DB 변경은 `supabase db push --dry-run` 결과를 사용자에게 보여주고 확인을 받은 뒤 적용한다.

## 명령어

```sh
supabase start                       # 로컬 백엔드 (Docker). 끌 때: supabase stop
supabase migration new <name>        # 마이그레이션 추가
supabase migration up --local        # 새 마이그레이션만 적용
supabase db reset                    # 처음부터 다시 적용 (테스트 데이터 전부 삭제)

swift build                          # 전체 빌드
swift test                           # LoungeCore 테스트
scripts/build-app.sh --open          # build/429 Lounge.app 생성 후 재실행 (로컬 서버)
scripts/build-app.sh --dist          # 운영 서버용 유니버설 앱 + build/429-Lounge.zip (릴리스 절차는 README)
supabase db push --dry-run           # 운영 DB(서울, 링크됨)에 적용될 마이그레이션 확인

swift run lounge-bot --name 철수      # 상대 봇
swift run lounge-scan                # 토큰 로그 파싱 결과
scripts/install-hooks.sh             # 클론마다 한 번: git 훅 (커밋하는 Markdown 표를 Prettier로 정렬)
```

## 구조

| 타깃                        | 역할                                                                                     | 의존           |
| --------------------------- | ---------------------------------------------------------------------------------------- | -------------- |
| `LoungeCore`                | Claude Code·Codex 로그(`~/.claude/projects`, `~/.codex/sessions`) 파싱. UI·네트워크 없음 | -              |
| `LoungeNet`                 | Supabase: 익명 로그인, RPC 래퍼, Realtime 스트림                                         | supabase-swift |
| `Lounge429`                 | SwiftUI 메뉴바 앱 (`MenuBarExtra` window 스타일)                                         | Core, Net      |
| `lounge-bot`, `lounge-scan` | 개발용 CLI                                                                               | Net / Core     |

- 화면 상태: `LoungeStore`(지갑, 사용량, 칩 지급), `RouletteTable`·`BlackjackTable`(테이블 동기화), `PlinkoTable`(429 드롭: 서버 경로를 60ms 틱으로 재생). 모두 `@MainActor @Observable`
- 뷰는 값을 받는다 (`LoungeView`, `RouletteView`). 스냅샷 렌더링에 그대로 쓰기 위해서
- 서버 로직은 `supabase/migrations/*.sql`의 Postgres 함수에 있다

## 꼭 지킬 것

- **결과와 칩 증감은 서버에서만.** 클라이언트는 테이블을 읽기만 하고, 쓰기는 `security definer` RPC로만 한다. 새 게임도 같은 패턴. ([ADR-0003](docs/madr/0003-server-authoritative-rpc.md))
- **마이그레이션은 추가만.** 이미 적용된 파일은 고치지 말고 새 파일을 만든다. 함수 시그니처가 바뀌면 `drop function` 후 재생성하고 권한(`revoke`/`grant`)도 다시 건다.
- **픽셀 규칙.** 스프라이트 정수 배율, Galmuri는 12/24pt(Galmuri9는 10pt)만, `pixelBox` 테두리. 색은 `Theme` 토큰만 쓰고 hex를 뷰에 직접 넣지 않는다. 발광은 `.glow()`로, DESIGN.md §7에 적힌 곳에만. 자세한 건 DESIGN.md.
- **새 게임을 만들면** `game_results` 뷰를 다시 만들어 그 게임의 한 판(`net` = 지급액 − 건 칩, 황금 칩은 0)을 `union all`로 더한다. 안 하면 이번 주 큰손에서 빠진다 ([ADR-0012](docs/madr/0012-weekly-board-net-winnings.md))
- **칩 규칙을 바꾸면** `docs/chip-economy.md`도 같이 고친다.
- **Markdown은 Prettier로 정렬된 상태로 커밋한다** (`.prettierrc.json`). `scripts/install-hooks.sh`를 한 번 실행하면 pre-commit 훅이 커밋하는 `.md`의 스테이징된 내용만 정렬해 다시 올린다. 훅을 안 쓰는 환경이면 커밋 전에 `npx prettier --write <파일>`. 편집할 때 파일 전체를 정렬하는 도구가 남기는 엉뚱한 정렬 변경을 막기 위해서다
- **Swift 6 strict concurrency.** `LoungeCore`, `LoungeNet` 타입은 `Sendable`로 유지한다.
- 코드 주석과 UI 카피는 한국어. 카피 톤은 DESIGN.md §11.

## 검증 방법

UI를 바꾸면 스냅샷으로 직접 확인한다 (앱을 띄우지 않고 PNG로 렌더링):

```sh
swift build --product Lounge429
.build/debug/Lounge429 --snapshot /tmp/x.png [--locked] [--table readme|roulette-idle|roulette-betting|roulette-golden|roulette-alone|roulette-spin|roulette-cut-near|roulette-cut-edge|roulette-cut-land|roulette-closed|roulette-win|roulette-void|roulette-help|roulette-live|slot-idle|slot-spinning|slot-glitch|slot-win|slot-big|slot-jackpot|slot-lose|slot-live|nickname|nickname-taken|lobby-busy|lobby-quiet|lobby-ticker|lobby-alone|lobby-board|lobby-board-me|lobby-board-empty|lobby-board-10|lobby-board-10-me|lobby-flip|lobby-live|lobby-whatsnew|lobby-whatsnew-skip|lobby-new|bj-idle|bj-betting|bj-full|bj-dealing|bj-deal|bj-myturn|bj-turn|bj-dealer|bj-result|bj-help|bj-live|minority-open|minority-picked|minority-closed|minority-result-win|minority-result-lose|minority-result-void|wall-idle|wall-painted|wall-same|wall-limited|wall-empty|wall-live|plinko-idle|plinko-charging|plinko-flying|plinko-win|plinko-big|plinko-max|plinko-pocket|plinko-letters|plinko-hot|plinko-fever|plinko-fever-end|plinko-vip|plinko-live|update|update-notice|update-sparkle|update-required]
```

- `--table roulette-live`: 설정된 Supabase 서버의 룰렛 테이블에 앉아 25초 동안 상태 줄을 찍고 화면을 저장한다. `LOUNGE_E2E_BET=chips`면 빨강 50 + 7에 10, `golden`이면 홀에 황금 칩을 한 번 건다
- `LOUNGE_FAKE_429=1`: 가짜 429 상태 (리셋 시각은 "2시간 뒤 정각"으로 고정이라 재실행해도 황금 칩 중복 없음)
- 멀티플레이는 `lounge-bot` 두 개(기본이 룰렛, 판마다 한두 칸) + `--table roulette-live` 조합으로 확인. 룰렛 서버 함수는 `roulette_tick`이 jsonb 하나로 판 전체를 돌려주고, 공이 도는 6초와 결과 4초는 `RouletteTable.phase`가 마감 시각으로 정한다
- 라운지 접속은 `lounge-bot --name 철수 [--blink] [--watch]` + `--table lobby-live`(20초 동안 회원 목록 출력 후 화면). `--blink`는 7초마다 보는 중을 껐다 켜고, `--watch`는 봇 쪽에서 본 회원 목록을 찍는다 (다른 회원 화면에 내가 어떻게 보이는지)
- 블랙잭은 `lounge-bot --name 철수 --blackjack` 두세 개 + `--table bj-live`(25초 동안 상태 줄 출력 후 화면). `LOUNGE_E2E_BET=1`이면 앱 계정도 30칩 걸고 친다. 서버 함수는 `bj_tick`이 jsonb 하나로 판 전체를 돌려주고, 카드 도착(날아오는) 시각은 `BlackjackTable.apply`가 정한다
- 소수결은 `lounge-bot --name 철수 --minority 0|1`로 봇이 고르고, `--table lobby-live`가 끝날 때 `minority ...`로 상태를 찍는다. 정산을 보려면 로컬 DB에서 `update minority_rounds set closes_at = now() where settled_at is null`
- 라운지 벽화는 `lounge-bot --name 철수 --wall`(2~5초마다 옆 칸으로 걸어가며 칠함, 10개 쓰면 429 받고 대기)을 띄워 두고 앱에서 벽화를 연다. `--table wall-live`는 25초 동안 새 칸과 도착 지연을 찍는다(몇 초 안이면 Realtime). 서버 함수는 `pixel_board`(읽기) / `pixel_paint`(칠하기, 버킷 검사)이고 칩과 무관하다 ([ADR-0017](docs/madr/0017-lounge-wall-free-pixels.md))
- 429 드롭은 `PlinkoTable`이 서버 응답의 경로(`js`)를 60ms 틱으로 재생한다. 지갑·지급 팝업·내 전광판 이벤트는 공이 닿을 때 반영하니, 로직을 건드리면 `--table plinko-live`(`LOUNGE_E2E_BET=1` 손으로 누르고 떼기 / `auto` / `golden`)로 25초 돌린 뒤 끝 줄의 "보이는 칩 = 서버 칩"과 `plinko_drops`의 `sum(payout - amount)`가 앱 칩 변화와 맞는지 본다. 봇은 `lounge-bot --name 철수 --plinko`. 장면 스냅샷은 `PlinkoFake`(서버 규칙을 옮긴 가짜 응답)로 시드 고정이라 같은 그림이 나온다. 효과음은 `python3 scripts/gen_drop_sounds.py`로 다시 굽는다. 버벅임은 `LOUNGE_PLINKO_WINDOW=1`(실제 창에 띄움) `LOUNGE_PLINKO_SOUND=1`(소리 켬)을 붙여 같은 명령으로 재면 `perf 틱 간격`·`perf 틱 작업`이 찍힌다. 간격 60ms·작업 몇 ms 이하가 정상. 429 드롭 소리는 `AVAudioPlayer` 대신 `DropAudio`(`AVAudioEngine`, 늘 재생 중인 노드에 `.interrupts`로 버퍼 예약)로 낸다 — `AVAudioPlayer`나 노드의 `stop()`은 메인 스레드를 수십 ms 막아 공이 버벅였다
- 이번 주 큰손은 `--table lobby-live`가 끝날 때 `board [...]`로 출력한다. 봇이 판을 돌리는 동안 두 번 찍어 순수익이 바뀌는지 본다
- 잭팟 알림은 로컬 DB에 다른 회원 이름으로 `insert into lounge_events (kind, game, player_id, name, amount) select 'jackpot','slot',id,name,4290 from players where name='철수'`를 넣어 본다. 번들로 띄운 앱(`build-app.sh --open`)에서만 macOS 알림이 뜬다 (`swift run`·스냅샷은 번들 ID가 없어 건너뜀)
- Presence 갱신은 같은 키로 "나감 + 들어옴"이 함께 온다 → 나감부터 처리해야 회원이 사라지지 않는다
- 소켓이 재연결되면 SDK는 채널에 다시 들어가기만 하고 `track`은 다시 안 보낸다 → `statusChange`의 두 번째 `.subscribed`부터 다시 track. 재연결 땐 `presence_state`(전체 목록)가 "들어옴"으로만 오니 목록을 갈아끼운다. 재현: `lounge-bot` 띄우고 `docker restart supabase_realtime_429-lounge` 후 `--table lobby-live`
- 서버 함수를 바꾸면 RPC를 직접 호출해 거절 케이스까지 확인한다. 로컬 공개 키는 `LoungeConfig.local` 참고
- E2E는 앱과 같은 `default` 프로필 세션을 쓴다. 테스트 후 지갑이 지저분하면 `supabase db reset`
- 운영 서버로 확인할 땐 `LOUNGE_SERVER=remote`. 운영 DB엔 실제 회원 데이터가 있으니 테스트 계정은 끝나고 지운다

## 알아둘 것

- Claude Code 로그는 한 응답이 여러 줄로 기록된다 → `message.id + requestId`로 중복 제거
- Claude Code의 429는 로그에 `apiErrorStatus: 429`, `quotaLimits.resetsAt`, `rateLimitType`으로 남는다
- Codex는 `token_usage_record`(응답마다, `response_id`)로 세고, 429는 `token_count.rate_limits` 창이 100%일 때. 같은 리밋의 `resets_at`이 초 단위로 흔들리니 `UsageScanner.mergeHits`로 고정한다
- 두 도구를 쓰면 토큰은 합쳐서 `claim_tokens` 한 번, 황금 칩은 리밋마다 ([ADR-0009](docs/madr/0009-codex-support-golden-per-tool.md))
- 번들 ID: 배포(`--dist`)만 `co.dwook.lounge429`, 로컬 빌드는 `co.dwook.lounge429.dev`. 설정(UserDefaults)과 알림 권한이 따로라, 개발 중에 닫은 "새로 들어온 것" 카드가 배포 앱에 남지 않는다
- 세션은 키체인이 아니라 `~/Library/Application Support/429Lounge/sessions/<host>/<profile>/`에 파일로 저장
- `ImageRenderer`는 메인 런루프가 필요하다. `dispatchMain()`으로 돌리면 멈춘다 (`NSApplication.run()` 사용)
- 메뉴바 관리 앱(Bartender, Ice 등)이 새 아이콘을 숨김 영역에 넣을 수 있다
- 서버 선택: `LOUNGE_SUPABASE_URL/KEY` → `LOUNGE_SERVER` → Info.plist `LoungeServer` → 로컬. Finder로 띄운 앱엔 환경변수가 없어서 배포 빌드는 Info.plist로 정한다 ([ADR-0007](docs/madr/0007-remote-supabase-zip-distribution.md))
- 로컬 Supabase MCP는 `.mcp.json`의 `supabase-local`(`http://127.0.0.1:54321/mcp`, 로그인 없음). Studio가 서빙하므로 `config.toml`의 `[studio] enabled = true`를 유지하고 `supabase start` 후 쓴다. 마이그레이션은 MCP `apply_migration`이 아니라 `supabase migration new`로 파일을 남긴다
- 원격 Auth 설정은 대시보드에서. `supabase config push`는 로컬 개발용 `config.toml`까지 덮어쓴다
- `ImageRenderer`는 `TextField`를 못 그린다. 스냅샷에선 `\.snapshotting` 환경값으로 Text로 바꿔 그린다
- 라운지 목록 = Presence(접속 중) + 명부(`named` 회원, `last_seen_at`). 앱은 `touch_seen`을 2분마다 ([ADR-0011](docs/madr/0011-lounge-roster-offline.md)). App Nap은 `AppDelegate`에서 막는다 (재워지면 하트비트가 밀려 Presence에서 빠진다)
- 업데이트는 안내만 ([ADR-0010](docs/madr/0010-update-notice-min-version.md)). RPC를 깨는 마이그레이션이면 같은 파일에서 `client_policy.min_version`을 올린다. 번들 없이 돌면 버전이 "dev"라 안내가 안 뜬다
- 닉네임은 `set_nickname` RPC로만, 라운지 전체에서 하나뿐(`lower(name)` 유니크). 처음엔 서버가 "손님 XXXXXX"

## 문서 업데이트

- 디자인 결정이 나면 DESIGN.md의 🟡를 ✅로 바꾸고 변경 기록에 한 줄
- 되돌리기 어렵거나 이유를 남겨야 하는 결정은 `docs/madr/NNNN-제목.md` (MADR 형식, 템플릿은 `0000-template.md`)
