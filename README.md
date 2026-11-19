# 429 Lounge

> HTTP 429 Too Many Requests. 개발자들만 알아보는 VIP 카지노 라운지.

Claude Code 토큰 사용량을 칩으로 바꿔 친구들과 짧은 카지노 게임을 즐기는 macOS 메뉴바 앱.
빌드를 기다리거나 Claude 답변을 기다리는 동안 한 판. 리밋(429)에 걸리면 황금 칩 타임.

## 구조

```
Sources/
  LoungeCore/   Claude Code 로그(~/.claude/projects) 파싱 → 오늘/5시간 사용량, 429 감지
  LoungeNet/    Supabase 연동: 익명 로그인, 홀짝 RPC, Realtime(라운드/베팅/착석)
  Lounge429/    메뉴바 앱 (SwiftUI, Galmuri 도트 폰트, 격자 스프라이트)
  lounge-scan/  디버그 CLI: 지금 읽히는 사용량/리밋 상태
  lounge-bot/   개발용 봇: 테이블에 앉아서 랜덤 베팅
supabase/
  migrations/   스키마 + 게임 로직(정산은 전부 서버 함수에서)
```

## 개발

```sh
supabase start                      # 로컬 백엔드 (Docker). 스키마 바꾸면: supabase db reset
scripts/build-app.sh --open         # 429 Lounge.app 빌드 후 실행 (메뉴바에 칩 아이콘)
swift run lounge-bot --name 철수     # 혼자서 멀티 테스트할 때 상대 봇
swift run lounge-scan               # 토큰 로그 파싱 결과 확인
swift test
```

화면 확인용 스냅샷 (실행 없이 PNG로 렌더링):

```sh
.build/debug/Lounge429 --snapshot out.png                  # 라운지
.build/debug/Lounge429 --snapshot out.png --locked         # 429 VIP 상태
.build/debug/Lounge429 --snapshot out.png --table betting  # 홀짝 (가짜 데이터)
.build/debug/Lounge429 --snapshot out.png --table live     # 홀짝 (실서버 접속 8초 후)
```

개발용 환경변수:

- `LOUNGE_FAKE_429=1`: 가짜 429 상태로 실행 (VIP HOUR, 황금 칩 지급 확인용)
- `LOUNGE_DEBUG=1`: Realtime 이벤트 로그
- `LOUNGE_E2E_BET=golden|chips`: `--table live` 스냅샷에서 베팅 자동 실행

칩 규칙은 [docs/chip-economy.md](docs/chip-economy.md).

원격 Supabase를 쓰려면 `LOUNGE_SUPABASE_URL`, `LOUNGE_SUPABASE_KEY` 환경변수.

## 크레딧

- 폰트: [Galmuri](https://github.com/quiple/galmuri) by Minseo Lee, SIL Open Font License 1.1
