# 429 Lounge

> HTTP 429 Too Many Requests. 개발자들의 은밀한 VIP 카지노 라운지.

Claude Code 토큰 사용량을 칩으로 바꿔 회원들과 짧은 카지노 게임을 즐기는 macOS 메뉴바 앱.

![라운지, 구슬 홀짝, 429 슬롯](docs/images/screens.png)

- 빌드나 Claude 답변을 기다리는 **10~30초짜리 틈**에 한 판
- 코딩하는 만큼 메뉴바의 칩이 오른다
- 리밋(429)에 걸리면 짜증 대신 **VIP HOUR**. 리셋 전까지 쓸 수 있는 황금 칩을 준다

> 프로토타입 단계. 초대된 회원과 먼저 운영해 보고 공개 여부를 정한다. 백엔드는 Supabase(서울), 개발은 로컬 Docker.

## 기능

|                                                             | 상태 |
| ----------------------------------------------------------- | ---- |
| Claude Code 로그에서 오늘/5시간 토큰 사용량, 429 리밋 감지  | ✅   |
| 메뉴바 칩 아이콘 + 라스베가스 네온 도트 그래픽 팝오버       | ✅   |
| 칩 경제: 토큰 환전, 출근 도장, 파산 구제, 황금 칩           | ✅   |
| **구슬 홀짝** (실시간 멀티 테이블, 15초 라운드)             | ✅   |
| **429 슬롯** (500 글리치, 응답 코드, 잭팟 ×429) + 승리 연출 | ✅   |
| 블랙잭 (솔로 / 테이블)                                      | ⏳   |
| 룰렛 (테이블)                                               | ⏳   |
| 닉네임 (처음엔 손님, 라운지 전체에서 하나뿐)                | ✅   |
| 원격 서버 배포 (초대 회원용 zip)                            | ✅   |
| 방 코드, 회원 목록                                          | ⏳   |

### 칩

| 수입      |                                                                           |
| --------- | ------------------------------------------------------------------------- |
| 토큰 환전 | 새로 쓴 토큰 1,000개 = 1칩 (캐시 읽기 제외, 상한 없음)                    |
| 출근 도장 | 하루 첫 접속 +100칩, 잔액 100 미만이면 +300칩                             |
| 황금 칩   | 429에 걸리면 3개(주간 리밋 10개). 1개 = 공짜 100칩 베팅. 리셋 시각에 소멸 |

칩은 현금·실물로 바꿀 수 없고 주고받을 수도 없다. 자세한 규칙은 [docs/chip-economy.md](docs/chip-economy.md).

### 구슬 홀짝

엎어 둔 그릇 아래 구슬이 홀인지 짝인지 맞힌다. 같은 방 사람들이 15초 동안 동시에 베팅하고, 구슬이 하나씩 굴러 나온 뒤 5초 후 다음 판. 맞히면 2배. 결과와 정산은 전부 서버에서.

### 429 슬롯

SPIN은 요청, 결과는 HTTP 응답.

- **500** 이 뜨면 그 릴이 치지직 깨지고 다시 돈다
- **429 세 개 = ×429 잭팟**. 실제로 리밋에 걸린 VIP HOUR엔 429가 더 자주 나온다
- 결과는 `200 OK`, `304 Not Modified`, `404 Not Found`처럼 응답 코드로 표시

## 설치

macOS 14 이상. 터미널에 한 줄:

```sh
curl -fsSL https://raw.githubusercontent.com/Jiwook00/429-lounge/main/scripts/install.sh | bash
```

최신 [릴리스](https://github.com/Jiwook00/429-lounge/releases/latest)를 받아 `/Applications`에 넣고 실행한다. 업데이트도 같은 명령. Claude Code에게 "이 레포 설치해줘"라고 해도 이 명령을 쓴다.

- 메뉴바에 칩 아이콘과 숫자가 뜬다. Bartender나 Ice 같은 메뉴바 관리 앱을 쓰면 숨김 영역에 들어갔을 수 있다
- 처음 들어오면 "손님 3F2A9C" 같은 임시 이름이 붙고, 닉네임을 정해야 테이블에 앉을 수 있다. 바꾸려면 팝오버 아래 "이름 바꾸기"
- 칩은 `~/.claude/projects`의 Claude Code 로그에서 토큰 사용량만 읽어서 계산한다. 대화 내용은 서버로 보내지 않는다
- 지우기: `rm -rf "/Applications/429 Lounge.app" ~/Library/Application\ Support/429Lounge`

릴리스 zip을 직접 받았다면 ad-hoc 서명이라 Gatekeeper가 막는다. `xattr -dr com.apple.quarantine "/Applications/429 Lounge.app"` 후 실행.

## 개발 환경

필요한 것: macOS 14+, Xcode(Swift 6), Docker, [Supabase CLI](https://supabase.com/docs/guides/cli)

```sh
supabase start                  # 로컬 백엔드 (첫 실행은 이미지 다운로드로 몇 분)
scripts/build-app.sh --open     # build/429 Lounge.app 빌드 후 실행
```

이렇게 만든 앱은 로컬 서버에 붙는다. 혼자 멀티를 해보려면 상대 봇을 앉힌다:

```sh
swift run lounge-bot --name 철수
```

## 릴리스

```sh
supabase db push --dry-run      # 서버 변경이 있으면 먼저 운영 DB에 (확인 후 --dry-run 빼고)
# scripts/build-app.sh의 VERSION을 올리고 커밋·푸시한 뒤
scripts/build-app.sh --dist     # 운영 서버용 유니버설 앱 → build/429-Lounge.zip
gh release create v0.1.0 build/429-Lounge.zip --title v0.1.0 --notes "..."
```

설치 스크립트는 항상 최신 릴리스의 `429-Lounge.zip`을 받는다. `--remote`만 주면 zip 없이 운영 서버용 앱을 만든다. 운영 서버는 `LoungeConfig.remote`, 배포 결정은 [ADR-0007](docs/madr/0007-remote-supabase-zip-distribution.md).

## 개발

```sh
swift build && swift test
swift run lounge-scan                                  # 토큰 로그 파싱 결과
.build/debug/Lounge429 --snapshot out.png [--locked] [--table readme|betting|reveal|crowd|crowd-reveal|crowd-won|live|slot-idle|slot-spinning|slot-glitch|slot-win|slot-big|slot-jackpot|slot-lose|slot-live|nickname|nickname-taken]
supabase db reset                                      # 마이그레이션 전체 재적용 (데이터 삭제)
```

| 환경변수                                     |                                          |
| -------------------------------------------- | ---------------------------------------- |
| `LOUNGE_FAKE_429=1`                          | 가짜 429 상태로 실행 (VIP HOUR, 황금 칩) |
| `LOUNGE_DEBUG=1`                             | Realtime 이벤트 로그                     |
| `LOUNGE_E2E_BET=golden\|chips`               | `--table live` 스냅샷에서 자동 베팅      |
| `LOUNGE_SERVER=remote`                       | 운영 서버(`LoungeConfig.remote`) 사용    |
| `LOUNGE_SUPABASE_URL`, `LOUNGE_SUPABASE_KEY` | 임의의 Supabase 사용 (가장 우선)         |

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
scripts/          .app 번들 / 배포 zip 빌드, 설치 스크립트
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

1. 스프라이트 시트 정식 제작, 황금 칩 획득 연출
2. 회원 잭팟 알림 (누가 터뜨리면 라운지에 방송)
3. 방 코드로 테이블 나누기, 회원 목록
4. 공개 배포 (Developer ID 서명, 공증, 자동 업데이트)
5. 블랙잭, 룰렛

## 크레딧

- 폰트: [Galmuri](https://github.com/quiple/galmuri) by Minseo Lee, SIL Open Font License 1.1
