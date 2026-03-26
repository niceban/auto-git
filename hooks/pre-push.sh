#!/usr/bin/env bash
# pre-push.sh — Intercept push, execute squash when awaiting_squash_push
# Hook: PreToolUse (Bash)
# stdin: tool input JSON
# Uses .tool_input.command (NOT .command — bug fix from archived version)

set -euo pipefail

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.claude/plugins/branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
LOCK_FILE="$STATE_DIR/.lock"

# Use flock if available (Linux), fall back to PID lock (macOS)
if command -v flock &>/dev/null; then
  exec 200>"$LOCK_FILE"
  flock -n 200 || { echo "pre-push.sh: already locked, skipping" >&2; exit 0; }
else
  if [[ -f "$LOCK_FILE" ]]; then
    local pid; pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "pre-push.sh: already locked (PID $pid), skipping" >&2
      exit 0
    fi
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
fi

[[ ! -f "$STATE_FILE" ]] && exit 0

# Read tool input — USE .tool_input.command (NOT .command)
input=$(cat)
COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

[[ -z "$COMMAND" ]] && exit 0

# Must be a git push command
if ! echo "$COMMAND" | grep -qE '^git[[:space:]]+push'; then
  exit 0
fi

# Check awaiting_squash_push flag
awaiting=$(jq -r '.awaiting_squash_push // false' "$STATE_FILE")
if [[ "$awaiting" != "true" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ ! -d "$PROJECT_DIR/.git" ]] && exit 0

cd "$PROJECT_DIR"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [[ -z "$branch" ]] || [[ "$branch" == "main" ]]; then
  echo "pre-push.sh: not on a feature branch, skipping squash" >&2
  exit 0
fi

# Verify there are commits to squash
commit_count=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
if [[ "$commit_count" -lt 1 ]]; then
  echo "pre-push.sh: no commits to push, skipping" >&2
  exit 0
fi

# Build squash message
msgs=$(git log --format="%s" origin/main..HEAD 2>/dev/null | tr '\n' '|' | sed 's/|$//')
branch_type=$(jq -r '.branch_type // "feature"' "$STATE_FILE")
squash_msg="squash(${branch}): ${msgs}"

echo ""
echo "=== Pre-Push Squash ==="
echo "Branch: $branch"
echo "Commits: $commit_count"
echo "Squash message: $squash_msg"
echo ""

# Execute squash: reset --soft to origin/main, then recommmit
if ! git reset --soft origin/main 2>/dev/null; then
  echo "pre-push.sh: reset --soft failed, skipping" >&2
  exit 0
fi

# Stage any remaining untracked changes (from checkpoint auto-saves)
git add -A

# Create squash commit
if ! git commit -q -m "$squash_msg"; then
  echo "pre-push.sh: squash commit failed, skipping" >&2
  git reset --soft HEAD~1 2>/dev/null || true
  exit 0
fi

# Force-push with lease
echo "Pushing with force-with-lease..."
if git push --force-with-lease origin "$branch" 2>/dev/null; then
  # Clear awaiting_squash_push, set awaiting_merge_confirmation
  jq '.awaiting_squash_push = false |
      .awaiting_merge_confirmation = true' \
     "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "Squash push successful. Awaiting merge confirmation."
else
  echo "pre-push.sh: force-push failed" >&2
  git reset --soft HEAD~1 2>/dev/null || true
  exit 0
fi

# Signal that the original push should NOT proceed (we already pushed)
DENY_REASON="Squash push already executed by pre-push.sh hook. Use 'git push' again if needed."
jq -n --arg r "$DENY_REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
