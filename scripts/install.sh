#!/usr/bin/env bash
# 429 Lounge 설치: GitHub 최신 릴리스 zip을 받아 /Applications(쓸 수 없으면 ~/Applications)에 넣고 실행한다.
# 사용법: curl -fsSL https://raw.githubusercontent.com/Jiwook00/429-lounge/main/scripts/install.sh | bash
#   LOUNGE_INSTALL_DIR=<폴더>  설치 위치 지정
#   LOUNGE_NO_OPEN=1           설치만 하고 실행하지 않음
set -euo pipefail

URL="https://github.com/Jiwook00/429-lounge/releases/latest/download/429-Lounge.zip"

[[ "$(uname)" == "Darwin" ]] || { echo "429 Lounge는 macOS 전용이에요" >&2; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || { echo "macOS 14 이상이 필요해요 (지금 $(sw_vers -productVersion))" >&2; exit 1; }

DEST="${LOUNGE_INSTALL_DIR:-/Applications}"
if [[ ! -w "$DEST" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi
APP="$DEST/429 Lounge.app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ 최신 버전 내려받는 중"
curl -fsSL "$URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"

pkill -x Lounge429 2>/dev/null || true
rm -rf "$APP"
ditto "$TMP/429 Lounge.app" "$APP"
# ad-hoc 서명이라 격리 표시가 있으면 Gatekeeper가 막는다
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✓ 설치: $APP"
if [[ -z "${LOUNGE_NO_OPEN:-}" ]]; then
    open "$APP"
    echo "  메뉴바의 슬롯머신 아이콘을 눌러 입장하세요. (Bartender·Ice를 쓰면 숨김 영역에 있을 수 있어요)"
fi
