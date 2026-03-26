#!/usr/bin/env bash
# post-tool.sh — Test PASS detection + auto-commit threshold check
# Hook: PostToolUse (Bash)
# stdin: tool result JSON
# exit 0 always

set -euo pipefail

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
CONFIG_FILE="$STATE_DIR/config.json"
LOCK_FILE="$STATE_DIR/.lock"

# Non-blocking lock — skip if stop.sh is running
if [[ -f "$LOCK_FILE" ]] && command -v flock &>/dev/null; then
  exec 200>"$LOCK_FILE"
  flock -n 200 || exit 0
elif [[ -f "$LOCK_FILE" ]]; then
  local pid; pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi
fi

[[ ! -f "$STATE_FILE" ]] && exit 0
[[ ! -f "$CONFIG_FILE" ]] && exit 0

# Read tool result (for test PASS detection)
input=$(cat)
output=$(echo "$input" | jq -r '.tool_result.output // ""' 2>/dev/null || echo "")

# ─── Test PASS detection ─────────────────────────────────────────────────────
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

# ─── Auto-commit threshold check ─────────────────────────────────────────────
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ ! -d "$PROJECT_DIR/.git" ]] && exit 0

cd "$PROJECT_DIR"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
[[ "$branch" == "main" ]] && exit 0

THRESHOLD_FILES=$(jq -r '.uncommitted_files_threshold // 5' "$CONFIG_FILE")
THRESHOLD_LINES=$(jq -r '.uncommitted_lines_threshold // 100' "$CONFIG_FILE")
AUTO_COMMIT_PREFIX=$(jq -r '.auto_commit_message_prefix // "checkpoint: auto-save"' "$CONFIG_FILE")

uncommitted_files=$(git status --porcelain | wc -l | tr -d ' ')
# Use diff HEAD to count ALL uncommitted changes (staged + unstaged)
uncommitted_lines=$(git diff HEAD --stat 2>/dev/null | tail -1 | awk '{print $4}' | tr -d ' ' || echo "0")

if [[ "$uncommitted_files" -ge "$THRESHOLD_FILES" ]] || \
   [[ "${uncommitted_lines:-0}" -ge "$THRESHOLD_LINES" ]]; then
  auto_msg="${AUTO_COMMIT_PREFIX} $(date +%Y%m%d-%H%M%S)"
  git add -A && git commit -q -m "$auto_msg"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq \
    --arg now "$now" \
    --arg msg "$auto_msg" \
    --argjson uncommitted_files 0 \
    --argjson uncommitted_lines 0 \
    '.last_commit_at = $now |
     .last_commit_message = $msg |
     .uncommitted_files = $uncommitted_files |
     .uncommitted_lines = $uncommitted_lines' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "post-tool: auto-committed → $auto_msg"
fi

exit 0
