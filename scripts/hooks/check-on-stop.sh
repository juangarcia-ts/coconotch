#!/usr/bin/env bash
# Claude Code Stop hook: block the turn from ending while scripts/check.sh fails.
set -uo pipefail
# Already blocked once this turn; let it end so a stubborn failure can't loop forever.
[[ $(jq -r '.stop_hook_active') == "true" ]] && exit 0

if ! output=$("$(dirname "$0")/../check.sh" 2>&1); then
    echo "scripts/check.sh failed. Fix it before finishing:" >&2
    echo "$output" | tail -40 >&2
    exit 2
fi
