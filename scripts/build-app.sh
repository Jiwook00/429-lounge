#!/usr/bin/env bash
# 429 Lounge.app 번들 생성.
# 사용법: scripts/build-app.sh [--remote] [--dist] [--open]
#   --remote  운영 서버(LoungeConfig.remote)에 붙는 앱
#   --dist    배포용: --remote + 유니버설(arm64/x86_64) + 서명된 zip·appcast
#   --open    빌드 후 재실행
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.15.0"
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
    : "${LOUNGE_SPARKLE_PUBLIC_KEY:?README 릴리스 절차에서 만든 Sparkle 공개키를 지정하세요}"
    ARCH=(--arch arm64 --arch x86_64)
else
    ARCH=()
fi
swift build -c release --product Lounge429 ${ARCH[@]+"${ARCH[@]}"}
BIN="$(swift build -c release --show-bin-path ${ARCH[@]+"${ARCH[@]}"})"
APP="build/429 Lounge.app"
REPO_URL="https://github.com/Jiwook00/429-lounge"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
SPARKLE_ACCOUNT="co.dwook.lounge429"

if [[ $DIST == 1 ]]; then
    if [[ ! "$LOUNGE_SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
       [[ "$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)" != "$LOUNGE_SPARKLE_PUBLIC_KEY" ]]; then
        echo "Sparkle 공개키와 키체인의 서명 키가 일치해야 합니다." >&2
        exit 1
    fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Lounge429" "$APP/Contents/MacOS/"
cp -R "$BIN"/*_Lounge429.bundle "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"

# 앱 아이콘: 앱이 코드로 그린 1024px 도트 아이콘을 .icns로. 1024 = 32칸 × 32px라 절반씩 줄이면 도트가 안 번진다 (16px 제외)
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/Lounge429" --app-icon "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    [[ $s == 512 ]] || sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>429 Lounge</string>
    <key>CFBundleDisplayName</key><string>429 Lounge</string>
    <key>CFBundleIdentifier</key><string>co.dwook.lounge429</string>
    <key>CFBundleExecutable</key><string>Lounge429</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LoungeServer</key><string>$SERVER</string>
</dict>
</plist>
PLIST

if [[ $DIST == 1 ]]; then
    PLIST="$APP/Contents/Info.plist"
    plutil -insert SUFeedURL -string "$REPO_URL/releases/latest/download/appcast.xml" "$PLIST"
    plutil -insert SUPublicEDKey -string "$LOUNGE_SPARKLE_PUBLIC_KEY" "$PLIST"
    plutil -insert SUEnableAutomaticChecks -bool NO "$PLIST"
    plutil -insert SUAllowsAutomaticUpdates -bool NO "$PLIST"
    plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$PLIST"
    plutil -insert SURequireSignedFeed -bool YES "$PLIST"
    plutil -insert SUSignedFeedFailureExpirationInterval -integer 0 "$PLIST"
    plutil -insert SUShowReleaseNotes -bool NO "$PLIST"
fi

codesign --force --deep --sign - "$APP" >/dev/null
echo "built: $APP ($SERVER, $(lipo -archs "$APP/Contents/MacOS/Lounge429"))"

if [[ $DIST == 1 ]]; then
    STAGING="$(mktemp -d build/sparkle.XXXXXX)"
    trap 'rm -rf "$STAGING"' EXIT
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/429-Lounge.zip"
    "$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" --maximum-deltas 0 \
        --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" "$STAGING"
    # ZIP·피드 서명과 버전이 모두 생성됐는지 확인한 뒤 옮긴다.
    /usr/bin/grep -q 'sparkle:edSignature=' "$STAGING/appcast.xml"
    /usr/bin/grep -q 'sparkle-signatures:' "$STAGING/appcast.xml"
    /usr/bin/grep -q -F "<sparkle:version>$VERSION</sparkle:version>" "$STAGING/appcast.xml"
    mv "$STAGING/429-Lounge.zip" "$STAGING/appcast.xml" build/
    echo "release: build/429-Lounge.zip + build/appcast.xml"
fi

if [[ $OPEN == 1 ]]; then
    pkill -x Lounge429 2>/dev/null || true
    open "$APP"
fi
