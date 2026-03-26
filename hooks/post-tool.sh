#!/usr/bin/env bash
# post-tool.sh — Detect test PASS in Bash tool output
# Hook: PostToolUse (Bash) — async
# stdin: tool result JSON
# exit 0 always (informational only)

set -euo pipefail

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
LOCK_FILE="$STATE_DIR/.lock"

# No flock needed for async informational hook — use non-blocking check
if [[ -f "$LOCK_FILE" ]] && command -v flock &>/dev/null; then
  exec 200>"$LOCK_FILE"
  flock -n 200 || exit 0
elif [[ -f "$LOCK_FILE" ]]; then
  # macOS fallback
  local pid; pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi
fi

[[ ! -f "$STATE_FILE" ]] && exit 0

# Read tool result
input=$(cat)
output=$(echo "$input" | jq -r '.tool_result.output // ""' 2>/dev/null || echo "")

# Detect test PASS patterns
if echo "$output" | grep -qE '(PASS|ok |✓|All tests passed|passed|100%)'; then
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq \
    --arg now "$now" \
    '.test_passed = true |
     .test_passed_at = $now |
     .test_failed_at = null' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "post-tool: test PASS detected"
fi

exit 0
