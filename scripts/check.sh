#!/usr/bin/env bash
# Every gate in one place: local runs, the Claude Code Stop hook and CI all call this.
set -euo pipefail
cd "$(dirname "$0")/.."

log=$(mktemp)
trap 'rm -f "$log"' EXIT

echo "==> Lint"
swift format lint --strict --recursive CocoNotch CocoNotchCore

echo "==> Test"
# xcodebuild, not `swift test`: it compiles the string catalogs on every toolchain, and the tests expect English.
if ! (cd CocoNotchCore && xcodebuild test -scheme CocoNotchCore -destination 'platform=macOS' \
    -derivedDataPath ../build/core -testLanguage en SWIFT_TREAT_WARNINGS_AS_ERRORS=YES) >"$log" 2>&1; then
    grep -E "error:|warning:|recorded an issue" "$log" | grep -v "^xcodebuild" || cat "$log"
    exit 1
fi
grep -E "Test run with" "$log"

echo "==> Build"
if ! xcodebuild -project CocoNotch.xcodeproj -scheme CocoNotch -destination 'platform=macOS' \
    -derivedDataPath build build -quiet >"$log" 2>&1; then
    grep -E "error:|warning:" "$log" | grep -v "^xcodebuild" || cat "$log"
    exit 1
fi

echo "All checks passed."
