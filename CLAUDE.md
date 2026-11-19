# 429 Lounge

Claude Code 토큰 사용량을 칩으로 바꿔 회원들과 짧은 카지노 게임을 즐기는 macOS 메뉴바 앱.
대상: Claude Code 사용자 (1차). 개요는 [README.md](README.md), 디자인은 [DESIGN.md](DESIGN.md), 결정 기록은 [docs/madr/](docs/madr/).

## 명령어

```sh
supabase start                       # 로컬 백엔드 (Docker). 끌 때: supabase stop
supabase migration new <name>        # 마이그레이션 추가
supabase migration up --local        # 새 마이그레이션만 적용
supabase db reset                    # 처음부터 다시 적용 (테스트 데이터 전부 삭제)

swift build                          # 전체 빌드
swift test                           # LoungeCore 테스트
scripts/build-app.sh --open          # build/429 Lounge.app 생성 후 재실행

swift run lounge-bot --name 철수      # 상대 봇
swift run lounge-scan                # 토큰 로그 파싱 결과
```

## 구조

| 타깃                        | 역할                                                                     | 의존           |
| --------------------------- | ------------------------------------------------------------------------ | -------------- |
| `LoungeCore`                | Claude Code 로그(`~/.claude/projects/**/*.jsonl`) 파싱. UI·네트워크 없음 | -              |
| `LoungeNet`                 | Supabase: 익명 로그인, RPC 래퍼, Realtime 스트림                         | supabase-swift |
| `Lounge429`                 | SwiftUI 메뉴바 앱 (`MenuBarExtra` window 스타일)                         | Core, Net      |
| `lounge-bot`, `lounge-scan` | 개발용 CLI                                                               | Net / Core     |

- 화면 상태: `LoungeStore`(지갑, 사용량, 칩 지급), `OddEvenTable`(테이블 동기화). 둘 다 `@MainActor @Observable`
- 뷰는 값을 받는다 (`LoungeView`, `OddEvenView`). 스냅샷 렌더링에 그대로 쓰기 위해서
- 서버 로직은 `supabase/migrations/*.sql`의 Postgres 함수에 있다

## 꼭 지킬 것

- **결과와 칩 증감은 서버에서만.** 클라이언트는 테이블을 읽기만 하고, 쓰기는 `security definer` RPC로만 한다. 새 게임도 같은 패턴. ([ADR-0003](docs/madr/0003-server-authoritative-rpc.md))
- **마이그레이션은 추가만.** 이미 적용된 파일은 고치지 말고 새 파일을 만든다. 함수 시그니처가 바뀌면 `drop function` 후 재생성하고 권한(`revoke`/`grant`)도 다시 건다.
- **픽셀 규칙.** 스프라이트 정수 배율, Galmuri는 12/24pt(Galmuri9는 10pt)만, `pixelBox` 테두리. 색은 `Theme` 토큰만 쓰고 hex를 뷰에 직접 넣지 않는다. 발광은 `.glow()`로, DESIGN.md §7에 적힌 곳에만. 자세한 건 DESIGN.md.
- **칩 규칙을 바꾸면** `docs/chip-economy.md`도 같이 고친다.
- **Swift 6 strict concurrency.** `LoungeCore`, `LoungeNet` 타입은 `Sendable`로 유지한다.
- 코드 주석과 UI 카피는 한국어. 카피 톤은 DESIGN.md §11.

## 검증 방법

UI를 바꾸면 스냅샷으로 직접 확인한다 (앱을 띄우지 않고 PNG로 렌더링):

```sh
swift build --product Lounge429
.build/debug/Lounge429 --snapshot /tmp/x.png [--locked] [--table betting|reveal|crowd|crowd-reveal|crowd-won|live|slot-idle|slot-spinning|slot-glitch|slot-win|slot-wild|slot-found|slot-big|slot-jackpot|slot-lose|slot-live]
```

- `--table live`: 실서버에 접속해 8초 후 화면을 찍는다. `LOUNGE_DEBUG=1`이면 Realtime 이벤트 로그, `LOUNGE_E2E_BET=golden|chips`면 자동 베팅
- `LOUNGE_FAKE_429=1`: 가짜 429 상태 (리셋 시각은 "2시간 뒤 정각"으로 고정이라 재실행해도 황금 칩 중복 없음)
- 멀티플레이는 `lounge-bot` 두 개 + `--table live` 조합으로 확인
- 서버 함수를 바꾸면 RPC를 직접 호출해 거절 케이스까지 확인한다. 로컬 공개 키는 `LoungeConfig.local` 참고
- E2E는 앱과 같은 `default` 프로필 세션을 쓴다. 테스트 후 지갑이 지저분하면 `supabase db reset`

## 알아둘 것

- 로그 한 응답이 여러 줄로 기록된다 → `message.id + requestId`로 중복 제거
- 429는 로그에 `apiErrorStatus: 429`, `quotaLimits.resetsAt`, `rateLimitType`으로 남는다
- 세션은 키체인이 아니라 `~/Library/Application Support/429Lounge/sessions/<host>/<profile>/`에 파일로 저장
- `ImageRenderer`는 메인 런루프가 필요하다. `dispatchMain()`으로 돌리면 멈춘다 (`NSApplication.run()` 사용)
- 메뉴바 관리 앱(Bartender, Ice 등)이 새 아이콘을 숨김 영역에 넣을 수 있다

## 문서 업데이트

- 디자인 결정이 나면 DESIGN.md의 🟡를 ✅로 바꾸고 변경 기록에 한 줄
- 되돌리기 어렵거나 이유를 남겨야 하는 결정은 `docs/madr/NNNN-제목.md` (MADR 형식, 템플릿은 `0000-template.md`)
