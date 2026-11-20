# 429 Lounge 설치 (AI 에이전트용)

사용자가 429 Lounge 설치를 요청했다. 아래 순서대로 진행한다.
레포를 클론하거나 소스를 빌드하지 않는다. 그건 개발용이다.

## 1. 확인

- macOS 14 이상인지: `sw_vers -productVersion`. 아니면 중단하고 알린다
- `~/.claude/projects`가 있는지. 없어도 설치는 되지만, Claude Code를 써야 칩이 쌓인다고 알려 준다

## 2. 설치

```sh
curl -fsSL https://raw.githubusercontent.com/Jiwook00/429-lounge/main/scripts/install.sh | bash
```

- 최신 릴리스를 받아 `/Applications`(쓸 수 없으면 `~/Applications`)에 넣고 실행한다
- 이미 설치돼 있으면 최신 버전으로 덮어쓴다 (= 업데이트)

## 3. 확인

- `pgrep -x Lounge429`로 실행 중인지 확인
- 안 열리고 Apple 경고가 뜨면: `xattr -dr com.apple.quarantine "<설치 경로>/429 Lounge.app"` 후 다시 `open`

## 4. 사용자에게 알려 줄 것

- 메뉴바의 슬롯머신 아이콘을 눌러 입장. 처음엔 닉네임부터 정한다
- 아이콘이 안 보이면 Bartender·Ice 같은 메뉴바 관리 앱의 숨김 영역 확인
- 칩은 Claude Code 로그의 토큰 수만 읽어서 계산한다. 대화 내용은 서버로 보내지 않는다
- 지우기: `rm -rf "/Applications/429 Lounge.app" ~/Library/Application\ Support/429Lounge`
