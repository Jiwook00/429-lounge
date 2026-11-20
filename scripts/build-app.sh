#!/usr/bin/env bash
# 429 Lounge.app 번들 생성.
# 사용법: scripts/build-app.sh [--remote] [--dist] [--open]
#   --remote  운영 서버(LoungeConfig.remote)에 붙는 앱
#   --dist    배포용: --remote + 유니버설(arm64/x86_64) + build/429-Lounge.zip (릴리스 에셋 이름, 버전은 태그로)
#   --open    빌드 후 재실행
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.2.2"
SERVER="local"; DIST=0; OPEN=0
for arg in "$@"; do
    case "$arg" in
        --remote) SERVER="remote" ;;
        --dist)   SERVER="remote"; DIST=1 ;;
        --open)   OPEN=1 ;;
        *) echo "알 수 없는 옵션: $arg" >&2; exit 1 ;;
    esac
done

if [[ $DIST == 1 ]]; then
    ARCH=(--arch arm64 --arch x86_64)
else
    ARCH=()
fi
swift build -c release --product Lounge429 ${ARCH[@]+"${ARCH[@]}"}
BIN="$(swift build -c release --show-bin-path ${ARCH[@]+"${ARCH[@]}"})"
APP="build/429 Lounge.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Lounge429" "$APP/Contents/MacOS/"
cp -R "$BIN"/*_Lounge429.bundle "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>429 Lounge</string>
    <key>CFBundleDisplayName</key><string>429 Lounge</string>
    <key>CFBundleIdentifier</key><string>co.dwook.lounge429</string>
    <key>CFBundleExecutable</key><string>Lounge429</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LoungeServer</key><string>$SERVER</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "built: $APP ($SERVER, $(lipo -archs "$APP/Contents/MacOS/Lounge429"))"

if [[ $DIST == 1 ]]; then
    ZIP="build/429-Lounge.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "zip: $ZIP"
fi

if [[ $OPEN == 1 ]]; then
    pkill -x Lounge429 2>/dev/null || true
    open "$APP"
fi
