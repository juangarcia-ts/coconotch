#!/usr/bin/env bash
# Every gate in one place: local runs, the Claude Code Stop hook and CI all call this.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Lint"
swift format lint --strict --recursive CocoNotch CocoNotchCore

echo "==> Test"
swift test --package-path CocoNotchCore --quiet -Xswiftc -warnings-as-errors

echo "==> Build"
log=$(mktemp)
if ! xcodebuild -project CocoNotch.xcodeproj -scheme CocoNotch -destination 'platform=macOS' \
    -derivedDataPath build build -quiet >"$log" 2>&1; then
    grep -E "error:|warning:" "$log" | grep -v "^xcodebuild" || cat "$log"
    exit 1
fi

echo "All checks passed."
