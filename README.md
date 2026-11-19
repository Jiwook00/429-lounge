# 429 Lounge

> HTTP 429 Too Many Requests. 개발자들의 은밀한 VIP 카지노 라운지.

Claude Code 토큰 사용량을 칩으로 바꿔 회원들과 짧은 카지노 게임을 즐기는 macOS 메뉴바 앱.

- 빌드나 Claude 답변을 기다리는 **10~30초짜리 틈**에 한 판
- 코딩하는 만큼 메뉴바의 칩이 오른다
- 리밋(429)에 걸리면 짜증 대신 **VIP HOUR**. 리셋 전까지 쓸 수 있는 황금 칩을 준다

> 프로토타입 단계. 초대된 회원과 먼저 운영해 보고 공개 여부를 정한다. 백엔드는 로컬 Supabase에서 개발 중.

## 기능

|                                                            | 상태 |
| ---------------------------------------------------------- | ---- |
| Claude Code 로그에서 오늘/5시간 토큰 사용량, 429 리밋 감지 | ✅   |
| 메뉴바 칩 아이콘 + 라스베가스 네온 도트 그래픽 팝오버      | ✅   |
| 칩 경제: 토큰 환전, 출근 도장, 파산 구제, 황금 칩          | ✅   |
| **구슬 홀짝** (실시간 멀티 테이블, 15초 라운드)            | ✅   |
| 슬롯머신 (솔로)                                            | ⏳   |
| 블랙잭 (솔로 / 테이블)                                     | ⏳   |
| 룰렛 (테이블)                                              | ⏳   |
| 닉네임, 방 코드, 회원 목록                                 | ⏳   |
| 원격 서버 배포                                             | ⏳   |

### 칩

| 수입      |                                                                           |
| --------- | ------------------------------------------------------------------------- |
| 토큰 환전 | 새로 쓴 토큰 1,000개 = 1칩 (캐시 읽기 제외, 상한 없음)                    |
| 출근 도장 | 하루 첫 접속 +100칩, 잔액 100 미만이면 +300칩                             |
| 황금 칩   | 429에 걸리면 3개(주간 리밋 10개). 1개 = 공짜 100칩 베팅. 리셋 시각에 소멸 |

칩은 현금·실물로 바꿀 수 없고 주고받을 수도 없다. 자세한 규칙은 [docs/chip-economy.md](docs/chip-economy.md).

### 구슬 홀짝

엎어 둔 그릇 아래 구슬이 홀인지 짝인지 맞힌다. 같은 방 사람들이 15초 동안 동시에 베팅하고, 구슬이 하나씩 굴러 나온 뒤 5초 후 다음 판. 맞히면 2배. 결과와 정산은 전부 서버에서.

## 시작하기

필요한 것: macOS 14+, Xcode(Swift 6), Docker, [Supabase CLI](https://supabase.com/docs/guides/cli)

```sh
supabase start                  # 로컬 백엔드 (첫 실행은 이미지 다운로드로 몇 분)
scripts/build-app.sh --open     # build/429 Lounge.app 빌드 후 실행
```

메뉴바에 칩 아이콘과 숫자가 뜬다. Bartender나 Ice 같은 메뉴바 관리 앱을 쓰면 숨김 영역에 들어갔을 수 있다.

혼자 멀티를 해보려면 상대 봇을 앉힌다:

```sh
swift run lounge-bot --name 철수
```

## 개발

```sh
swift build && swift test
swift run lounge-scan                                  # 토큰 로그 파싱 결과
.build/debug/Lounge429 --snapshot out.png [--locked] [--table betting|reveal|crowd|crowd-reveal|live]
supabase db reset                                      # 마이그레이션 전체 재적용 (데이터 삭제)
```

| 환경변수                                     |                                          |
| -------------------------------------------- | ---------------------------------------- |
| `LOUNGE_FAKE_429=1`                          | 가짜 429 상태로 실행 (VIP HOUR, 황금 칩) |
| `LOUNGE_DEBUG=1`                             | Realtime 이벤트 로그                     |
| `LOUNGE_E2E_BET=golden\|chips`               | `--table live` 스냅샷에서 자동 베팅      |
| `LOUNGE_SUPABASE_URL`, `LOUNGE_SUPABASE_KEY` | 원격 Supabase 사용 (기본값은 로컬)       |

## 구조

```
Sources/
  LoungeCore/     Claude Code 로그 파싱 (사용량, 429)
  LoungeNet/      Supabase: 익명 로그인, RPC, Realtime
  Lounge429/      메뉴바 앱 (SwiftUI)
    UI/           테마, 도트 렌더러, 스프라이트, 화면
  lounge-bot/     개발용 봇
  lounge-scan/    개발용 로그 확인 CLI
supabase/
  migrations/     스키마 + 게임·칩 로직 (Postgres 함수)
scripts/          .app 번들 빌드
docs/
  chip-economy.md 칩 규칙
  madr/           아키텍처 결정 기록 (ADR)
DESIGN.md         디자인 기준 (임시, 계속 업데이트)
CLAUDE.md         Claude Code 작업 가이드
```

## 문서

- [DESIGN.md](DESIGN.md): 컨셉, 픽셀 규칙, 타이포, 색, 열린 디자인 결정
- [docs/chip-economy.md](docs/chip-economy.md): 칩 수입과 서버 검사
- [docs/madr/](docs/madr/): 왜 이렇게 만들었는지 (Swift Package, Supabase, 서버 정산, 토큰 환율, 도트, 인증)

## 로드맵

1. 스프라이트 시트 정식 제작, 승리·황금 칩 연출 (무드는 라스베가스로 확정)
2. 슬롯머신 (황금 칩 무료 스핀)
3. 닉네임, 방 코드로 테이블 나누기
4. 원격 Supabase로 옮겨서 초대 회원에게 배포 (서명, 공증)
5. 블랙잭, 룰렛

## 크레딧

- 폰트: [Galmuri](https://github.com/quiple/galmuri) by Minseo Lee, SIL Open Font License 1.1
