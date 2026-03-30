#!/usr/bin/env bash
# stop.sh — Auto-commit threshold + milestone detection + merge/tag confirmation
# Hook: Stop
# P0-3: ONLY output point — all JSON goes through hookSpecificOutput

set -euo pipefail

source "$(dirname "$0")/logging.sh" 2>/dev/null || true
source "$(dirname "$0")/state-lib.sh"

acquire_lock "stop.sh"

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.claude/plugins/branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
CONFIG_FILE="$STATE_DIR/config.json"

[[ ! -f "$CONFIG_FILE" ]] && exit 0

local milestone_commits_threshold
milestone_commits_threshold=$(config_get "milestone_commits_threshold" "10")

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ ! -d "$PROJECT_DIR/.git" ]] && exit 0
cd "$PROJECT_DIR"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Auto-initialize state if missing
if [[ ! -f "$STATE_FILE" ]]; then
  init_state "$branch"
fi

# Guard: must not be on main
[[ "$branch" == "main" ]] && exit 0

# ─── Auto-commit threshold check ───────────────────────────────────────────────
local threshold_files
threshold_files=$(config_get "uncommitted_files_threshold" "5")
local threshold_lines
threshold_lines=$(config_get "uncommitted_lines_threshold" "1000")
local auto_commit_prefix
auto_commit_prefix=$(config_get "auto_commit_message_prefix" "checkpoint: auto-save")

local uncommitted_files
uncommitted_files=$(count_uncommitted_files)
local uncommitted_lines
uncommitted_lines=$(count_uncommitted_lines)

if [[ "$uncommitted_files" -ge "$threshold_files" ]] || \
   [[ "${uncommitted_lines:-0}" -ge "$threshold_lines" ]]; then
  local auto_msg="${auto_commit_prefix} $(date +%Y%m%d-%H%M%S)"
  git add -A && git commit -q -m "$auto_msg"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ')
  state_update "
    .last_commit_at = \"$now\" |
    .last_commit_message = \"$auto_msg\"
  "
  echo "stop.sh: auto-committed → $auto_msg"
  hook_log "stop" "auto_commit" branch="$branch" msg="$auto_msg" files="$uncommitted_files" lines="$uncommitted_lines"
fi

# ─── Load state flags ─────────────────────────────────────────────────────────
local awaiting_squash_push
awaiting_squash_push=$(jq -r '.awaiting_squash_push' "$STATE_FILE")
local awaiting_merge
awaiting_merge=$(jq -r '.awaiting_merge_confirmation' "$STATE_FILE")
local milestone_pending
milestone_pending=$(jq -r '.milestone_pending // false' "$STATE_FILE")
local test_passed
test_passed=$(jq -r '.test_passed' "$STATE_FILE")
local semantic_intent
semantic_intent=$(jq -r '.semantic_intent // false' "$STATE_FILE")

# ─── Interaction Point 2: Merge confirmation ──────────────────────────────────
if [[ "$awaiting_merge" == "true" ]]; then
  base=$(detect_base_ref)
  remote_ref="origin/${base}"
  if ! git rev-parse --verify "$remote_ref" &>/dev/null; then
    remote_ref="$base"
  fi
  local diff_stats
  diff_stats=$(git diff --stat "${remote_ref}..HEAD" 2>/dev/null | tail -1 || echo "")
  local current_tag
  current_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
  local major minor next_tag
  major=$(echo "$current_tag" | cut -d. -f1 | tr -d 'v')
  minor=$(echo "$current_tag" | cut -d. -f2)
  next_tag="v${major}.$((minor + 1)).0"

  echo "/merge confirm — squash 已完成，请回复 /merge 确认或 /merge cancel" >&2
  hook_log "stop" "merge_prompt" branch="$branch" next_tag="$next_tag"

  # P0-3: ONLY output through hookSpecificOutput
  jq -n \
    --arg branch "$branch" \
    --arg diff_stats "$diff_stats" \
    --arg current_tag "$current_tag" \
    --arg next_tag "$next_tag" \
    '{
      hookSpecificOutput: {
        hookEventName: "Stop",
        continueSuggestion: {
          prompt: "Merge 就绪！Branch: \($branch), Diff: \($diff_stats), Current tag: \($current_tag), Suggested tag: \($next_tag). 请告诉用户：「要确认 merge 吗？回复 /merge 确认，或 /merge cancel 取消」"
        },
        additionalContext: [
          {
            type: "reference",
            title: "Merge Ready",
            content: "awaiting_merge_confirmation=true | branch=\($branch) | current_tag=\($current_tag) | suggested_tag=\($next_tag)"
          }
        ]
      }
    }'
  exit 0
fi

# Skip if in squash workflow
[[ "$awaiting_squash_push" == "true" ]] && exit 0

# Reprompt if milestone pending
if [[ "$milestone_pending" == "true" ]]; then
  echo "/milestone confirm — 您有待确认的 milestone，请回复 /milestone 确认或 /milestone cancel" >&2
  hook_log "stop" "milestone_reprompt" branch="$branch"
  exit 0
fi

# Count commits since last tag
local last_tag
last_tag=$(get_last_tag)
local commits_since_tag
commits_since_tag=$(get_commits_since_tag "$last_tag")

# ─── Milestone detection ───────────────────────────────────────────────────────
local milestone="false"
local milestone_reason="null"
local semantic_reason=""

# Trigger 3 (priority): semantic intent
if [[ "$semantic_intent" == "true" ]]; then
  semantic_reason=$(jq -r '.semantic_intent_reason // "semantic_trigger"' "$STATE_FILE" 2>/dev/null || echo "semantic_trigger")
  milestone_reason="$semantic_reason"
  milestone="true"
fi

# Trigger 1: commit count threshold
if [[ "$milestone" == "false" ]] && [[ "$commits_since_tag" -ge "$milestone_commits_threshold" ]]; then
  milestone="true"
  milestone_reason="commits_threshold"
fi

# Trigger 2: conventional commit prefix
if [[ "$milestone" == "false" ]]; then
  local last_commit_msg
  last_commit_msg=$(git log -1 --format="%s" 2>/dev/null || echo "")
  if echo "$last_commit_msg" | grep -qE "^(feat|fix|perf|ci):"; then
    milestone="true"
    milestone_reason="conventional_commit"
  fi
fi

# ─── Interaction Point 1b: Semantic intent milestone (no test required) ───────
if [[ "$milestone" == "true" ]] && [[ "$test_passed" != "true" ]] && [[ "$semantic_reason" != "" ]] && [[ "$semantic_reason" != "null" ]]; then
  hook_log "stop" "semantic_milestone" reason="$milestone_reason" branch="$branch" commits="$commits_since_tag"

  base=$(detect_base_ref)
  remote_ref="origin/${base}"
  if ! git rev-parse --verify "$remote_ref" &>/dev/null; then
    remote_ref="$base"
  fi
  local msgs
  msgs=$(git log --format="%s" "${remote_ref}..HEAD" 2>/dev/null | \
    grep -vE "^checkpoint: auto-save" | \
    grep -vE "^checkpoint:" | \
    head -10 | \
    tr '\n' '|' | sed 's/|$//' || echo "")
  if [[ -z "$msgs" ]]; then
    msgs=$(git log --format="%s" "${remote_ref}..HEAD" 2>/dev/null | tr '\n' '|' | sed 's/|$//' || echo "")
  fi
  local squash_suggestion="squash(${branch}): ${msgs}"

  state_update "
    .milestone_pending = true |
    .milestone_pending_reason = \"$milestone_reason\" |
    .milestone_pending_squash_suggestion = \"$squash_suggestion\" |
    .milestone_pending_branch = \"$branch\" |
    .milestone_pending_commits = $commits_since_tag
  "

  echo "/milestone confirm — 语义触发已满足，请回复 /milestone 确认或 /milestone cancel" >&2

  # P0-3: ONLY output through hookSpecificOutput
  jq -n \
    --arg reason "$milestone_reason" \
    --arg suggestion "$squash_suggestion" \
    --arg semantic_reason "$semantic_reason" \
    --argjson commits "$commits_since_tag" \
    --arg branch "$branch" \
    '{
      hookSpecificOutput: {
        hookEventName: "Stop",
        continueSuggestion: {
          prompt: "Milestone reached!语义触发已满足 — Reason: \($reason), Trigger: \($semantic_reason). 已生成 squash 建议: \($suggestion). 请告诉用户：「要确认 squash 吗？回复 /milestone 确认，或 /milestone cancel 取消」"
        },
        additionalContext: [
          {
            type: "reference",
            title: "Milestone Pending",
            content: "milestone_pending=true | reason=\($reason) | commits=\($commits) | branch=\($branch)"
          }
        ]
      }
    }'
  exit 0
fi

# ─── Interaction Point 1: Milestone confirmed with passing tests ──────────────
if [[ "$milestone" == "true" ]] && [[ "$test_passed" == "true" ]]; then
  hook_log "stop" "test_passed_milestone" reason="$milestone_reason" branch="$branch" commits="$commits_since_tag"

  base=$(detect_base_ref)
  remote_ref="origin/${base}"
  if ! git rev-parse --verify "$remote_ref" &>/dev/null; then
    remote_ref="$base"
  fi
  local msgs
  msgs=$(git log --format="%s" "${remote_ref}..HEAD" 2>/dev/null | \
    grep -vE "^checkpoint: auto-save" | \
    grep -vE "^checkpoint:" | \
    head -10 | \
    tr '\n' '|' | sed 's/|$//' || echo "")
  if [[ -z "$msgs" ]]; then
    msgs=$(git log --format="%s" "${remote_ref}..HEAD" 2>/dev/null | tr '\n' '|' | sed 's/|$//' || echo "")
  fi
  local squash_suggestion="squash(${branch}): ${msgs}"

  state_update "
    .milestone_pending = true |
    .milestone_pending_reason = \"$milestone_reason\" |
    .milestone_pending_squash_suggestion = \"$squash_suggestion\" |
    .milestone_pending_branch = \"$branch\" |
    .milestone_pending_commits = $commits_since_tag
  "

  echo "/milestone confirm — milestone 已就绪，请回复 /milestone 确认或 /milestone cancel" >&2

  # P0-3: ONLY output through hookSpecificOutput
  jq -n \
    --arg reason "$milestone_reason" \
    --arg suggestion "$squash_suggestion" \
    --arg semantic_reason "$semantic_reason" \
    --argjson commits "$commits_since_tag" \
    --arg branch "$branch" \
    '{
      hookSpecificOutput: {
        hookEventName: "Stop",
        continueSuggestion: {
          prompt: "Milestone reached! 测试已通过 — Reason: \($reason), Commits: \($commits). Squash 建议: \($suggestion). 请告诉用户：「要确认 squash 吗？回复 /milestone 确认，或 /milestone cancel 取消」"
        },
        additionalContext: [
          {
            type: "reference",
            title: "Milestone Pending (Tests Passed)",
            content: "milestone_pending=true | reason=\($reason) | commits=\($commits) | branch=\($branch)"
          }
        ]
      }
    }'
  exit 0
fi

exit 0
