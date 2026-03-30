#!/usr/bin/env bash
# post-tool.sh — Test PASS detection
# Hook: PostToolUse (Bash|Write)
# stdin: tool result JSON
# exit 0 always

set -euo pipefail

source "$(dirname "$0")/logging.sh" 2>/dev/null || true
source "$(dirname "$0")/state-lib.sh"

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.claude/plugins/branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
CONFIG_FILE="$STATE_DIR/config.json"

# Non-blocking lock — skip if stop.sh is running
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
[[ ! -f "$CONFIG_FILE" ]] && exit 0

# Read tool result
input=$(cat)
local output
output=$(echo "$input" | jq -r '.tool_result.output // ""' 2>/dev/null || echo "")

# Test PASS detection
if echo "$output" | grep -qE '(PASS|ok |✓|All tests passed|passed|100%)'; then
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ')
  state_update "
    .test_passed = true |
    .test_passed_at = \"$now\" |
    .test_failed_at = null
  "
  echo "post-tool: test PASS detected"
  hook_log "post-tool" "test_pass"
fi

exit 0
