#!/usr/bin/env bash
# 429 Lounge.app 번들 생성. 사용법: scripts/build-app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Lounge429
BIN="$(swift build -c release --show-bin-path)"
APP="build/429 Lounge.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Lounge429" "$APP/Contents/MacOS/"
cp -R "$BIN"/*_Lounge429.bundle "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>429 Lounge</string>
    <key>CFBundleDisplayName</key><string>429 Lounge</string>
    <key>CFBundleIdentifier</key><string>co.dwook.lounge429</string>
    <key>CFBundleExecutable</key><string>Lounge429</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "built: $APP"

if [[ "${1:-}" == "--open" ]]; then
    pkill -x Lounge429 2>/dev/null || true
    open "$APP"
fi
