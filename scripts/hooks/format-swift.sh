#!/usr/bin/env bash
# Claude Code PostToolUse hook: format the Swift file that was just edited.
set -euo pipefail
file=$(jq -r '.tool_input.file_path // empty')
[[ "$file" == *.swift && -f "$file" ]] || exit 0
swift format --in-place --configuration "$(dirname "$0")/../../.swift-format" "$file"
