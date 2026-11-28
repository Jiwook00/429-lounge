#!/bin/sh
# 로컬과 CI가 같은 명령으로 검증한다.
#   scripts/ci.sh [base-ref]      기본 base: origin/main (변경 파일 = base...HEAD + 작업 트리)
# 1) swift build  2) swift test  3) 변경한 .md Prettier --check  4) 변경한 .swift 린트(swift format lint)
# 린트는 의미 규칙만 본다: 기존 코드와 안 맞는 서식 규칙(들여쓰기·줄바꿈 등)은 걸러서, 전체 재포맷 없이 도입한다.
set -eu
cd "$(dirname "$0")/.."
base=${1:-origin/main}

changed=$( { git diff --name-only --diff-filter=ACMR "$base"...HEAD; git diff --name-only --diff-filter=ACMR HEAD; } | sort -u)
md=$(printf '%s\n' "$changed" | grep '\.md$' || true)
sw=$(printf '%s\n' "$changed" | grep '\.swift$' || true)

echo "==> swift build"
swift build
echo "==> swift test"
swift test

echo "==> prettier --check (변경한 .md)"
if [ -n "$md" ]; then printf '%s\n' "$md" | xargs npx --yes prettier@3 --check; else echo "(없음)"; fi

echo "==> swift format lint (변경한 .swift)"
if [ -n "$sw" ]; then
    out=$(printf '%s\n' "$sw" | xargs swift format lint -s 2>&1 || true)
    bad=$(printf '%s\n' "$out" | grep -E 'error|warning' | grep -vE '\[(Indentation|AddLines|Spacing|LineLength|RemoveLine|TrailingComma)\]' || true)
    if [ -n "$bad" ]; then printf '%s\n' "$bad"; exit 1; fi
else echo "(없음)"; fi
echo "OK"
