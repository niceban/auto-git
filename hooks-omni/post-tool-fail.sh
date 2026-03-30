#!/usr/bin/env bash
# post-tool-fail.sh — Detect test FAIL in Bash tool output
# Hook: PostToolUseFailure
# stdin: tool result JSON
# exit 0 always (informational only)

set -euo pipefail

source "$(dirname "$0")/logging.sh" 2>/dev/null || true
source "$(dirname "$0")/state-lib.sh"

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.claude/plugins/branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"

# No blocking lock needed for informational hook
if [[ -f "$LOCK_FILE" ]] && command -v flock &>/dev/null; then
  exec 200>"$LOCK_FILE"
  flock -n 200 || exit 0
elif [[ -f "$LOCK_FILE" ]]; then
  local oldpid
  oldpid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
    exit 0
  fi
fi

[[ ! -f "$STATE_FILE" ]] && exit 0

# Read tool result
input=$(cat)
local output
output=$(echo "$input" | jq -r '.tool_result.output // ""' 2>/dev/null || echo "")

# Detect test FAIL patterns
if echo "$output" | grep -qE '(FAIL|FAILED|ERROR|✗|tests failed|0 passed)'; then
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ')
  state_update "
    .test_passed = false |
    .test_failed_at = \"$now\"
  "
  echo "post-tool-fail: test FAIL detected"
  hook_log "post-tool-fail" "test_fail"
fi

exit 0
