#!/usr/bin/env bash
# pre-push.sh — Intercept push, execute squash when awaiting_squash_push
# Hook: PreToolUse (Bash)
# P1-1: Detects remote main divergence before squash push

set -euo pipefail

source "$(dirname "$0")/logging.sh" 2>/dev/null || true
source "$(dirname "$0")/state-lib.sh"

acquire_lock "pre-push.sh"

[[ ! -f "$STATE_FILE" ]] && exit 0

# Read tool input — USE .tool_input.command
input=$(cat)
COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

[[ -z "$COMMAND" ]] && exit 0

# Must be a git push command
if ! echo "$COMMAND" | grep -qE '^git[[:space:]]+push'; then
  exit 0
fi

# Check awaiting_squash_push flag
local awaiting
awaiting=$(jq -r '.awaiting_squash_push // false' "$STATE_FILE")
[[ "$awaiting" != "true" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ ! -d "$PROJECT_DIR/.git" ]] && exit 0
cd "$PROJECT_DIR"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
[[ -z "$branch" ]] || [[ "$branch" == "main" ]] && exit 0

# Detect base ref
base=$(detect_base_ref)
remote_ref="origin/${base}"
if ! git rev-parse --verify "$remote_ref" &>/dev/null; then
  remote_ref="$base"
fi

# Verify commits to push
local commit_count
commit_count=$(git rev-list --count "${remote_ref}..HEAD" 2>/dev/null || echo "0")
[[ "$commit_count" -lt 1 ]] && exit 0

# Single commit — no squash needed
if [[ "$commit_count" -eq 1 ]]; then
  jq '.awaiting_squash_push = false' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  exit 0
fi

# P1-1: Remote main force-push detection
if git rev-parse --verify "origin/${base}" &>/dev/null; then
  local remote_main_old
  remote_main_old=$(git rev-parse "origin/${base}")
  git fetch origin main 2>/dev/null || true
  local remote_main_new
  remote_main_new=$(git rev-parse "origin/${base}")
  if [[ "$remote_main_old" != "$remote_main_new" ]]; then
    echo "pre-push.sh: ERROR: remote main has been force-updated (detected divergence)" >&2
    hook_log "pre-push" "remote_main_diverged" old="$remote_main_old" new="$remote_main_new"
    exit 1
  fi
fi

# Create backup branch
local backup_branch="backup/${branch}-$(date +%Y%m%d-%H%M%S)"
if ! git branch "$backup_branch" HEAD 2>/dev/null; then
  backup_branch=""
fi
if [[ -n "$backup_branch" ]]; then
  echo "pre-push.sh: backup branch created: $backup_branch"
  hook_log "pre-push" "backup_created" backup_branch="$backup_branch" feature_branch="$branch"
fi

# Build squash message (filter checkpoint commits)
local msgs
msgs=$(git log --format="%s" "${remote_ref}..HEAD" 2>/dev/null | \
  grep -vE "^checkpoint: auto-save" | \
  grep -vE "^checkpoint:" | \
  head -10 | \
  tr '\n' '|' | sed 's/|$//')
if [[ -z "$msgs" ]]; then
  msgs=$(git log --format="%s" "${remote_ref}..HEAD" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
fi

local branch_type
branch_type=$(jq -r '.branch_type // "feature"' "$STATE_FILE")
local squash_msg="squash(${branch}): ${msgs}"

echo ""
echo "=== Pre-Push Squash ==="
echo "Branch: $branch"
echo "Commits: $commit_count"
echo "Squash message: $squash_msg"
echo ""

# Execute squash: reset --soft to base, then recommit
if ! git reset --soft "$remote_ref" 2>/dev/null; then
  echo "pre-push.sh: reset --soft failed, skipping" >&2
  exit 0
fi

git add -A

if ! git commit -q -m "$squash_msg"; then
  echo "pre-push.sh: squash commit failed, skipping" >&2
  git reset --soft HEAD~1 2>/dev/null || true
  exit 0
fi

# Force-push with lease
echo "Pushing with force-with-lease..."
if git push --force-with-lease origin "$branch" 2>/dev/null; then
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq \
    --arg backup "$backup_branch" \
    --arg now "$now" \
    ".awaiting_squash_push = false |
     .awaiting_merge_confirmation = true |
     .backup_branch = (if \"$backup_branch\" != \"\" then \"$backup_branch\" else .backup_branch end) |
     .backup_created_at = (if \"$backup_branch\" != \"\" then \"$now\" else .backup_created_at end)" \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "Squash push successful. Awaiting merge confirmation."
  hook_log "pre-push" "squash_complete" branch="$branch" commits="$commit_count" squash_msg="$squash_msg"
else
  echo "pre-push.sh: force-push failed" >&2
  if [[ -n "$backup_branch" ]]; then
    git reset --soft "$backup_branch" 2>/dev/null || true
    echo "pre-push.sh: restored from backup branch $backup_branch"
  fi
  exit 0
fi

# Block original push (already pushed)
DENY_REASON="Squash push already executed by pre-push.sh hook. Use 'git push' again if needed."
echo "squash push 已由 hook 自动完成，请继续正常操作" >&2
jq -n --arg r "$DENY_REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
