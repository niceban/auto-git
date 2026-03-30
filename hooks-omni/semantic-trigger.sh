#!/usr/bin/env bash
# semantic-trigger.sh — Semantic trigger detection (completely silent)
# Hook: UserPromptSubmit
# P0-3: MUST be completely silent (no stdout output)
#       All state changes go to state.json only

set -euo pipefail

source "$(dirname "$0")/logging.sh" 2>/dev/null || true
source "$(dirname "$0")/state-lib.sh"

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.claude/plugins/branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
CONFIG_FILE="$STATE_DIR/config.json"

# Non-blocking lock
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

# Read prompt from stdin
USER_PROMPT=""
PROJECT_DIR=""

if [[ ! -t 0 ]]; then
  local stdin_data
  stdin_data=$(cat 2>/dev/null || echo "{}")
  USER_PROMPT=$(echo "$stdin_data" | jq -r '.prompt // ""' 2>/dev/null || echo "")
  local stdin_cwd
  stdin_cwd=$(echo "$stdin_data" | jq -r '.cwd // ""' 2>/dev/null || echo "")
  if [[ -n "$stdin_cwd" ]] && [[ -d "$stdin_cwd/.git" ]]; then
    PROJECT_DIR="$stdin_cwd"
  fi
fi

PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
USER_PROMPT="${USER_PROMPT:-${USER_PROMPT_ENV:-}}"

[[ ! -d "$PROJECT_DIR/.git" ]] && exit 0
cd "$PROJECT_DIR"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")
[[ -z "$USER_PROMPT" || "$USER_PROMPT" == "null" || "$USER_PROMPT" == "{}" ]] && exit 0

# Ensure state exists
if [[ ! -f "$STATE_FILE" ]]; then
  init_state "$branch"
fi

# Tier1: immediate semantic intent keywords
TIER1_PATTERNS="v1|v2|v3|release|搞定|搞定了|完成了|测试通过|✓|封板|milestone|done|finished|complete"

# Tier2: strong signal keywords
TIER2_PATTERNS="差不多|快好了|感觉可以了|nearly done|almost done|almost there|good enough"

local tier1_triggered="false"
local tier2_signal_detected="false"

if echo "$USER_PROMPT" | grep -qiE "$TIER1_PATTERNS"; then
  tier1_triggered="true"
fi

if echo "$USER_PROMPT" | grep -qiE "$TIER2_PATTERNS"; then
  tier2_signal_detected="true"
fi

# Skip if semantic_intent already true
local already_intent
already_intent=$(jq -r '.semantic_intent // false' "$STATE_FILE" 2>/dev/null || echo "false")
[[ "$already_intent" == "true" ]] && exit 0

# Helper: build squash suggestion
build_squash_suggestion() {
  local base
  base=$(detect_base_ref)
  local msgs
  msgs=$(git log --format="%s" "${base}..HEAD" 2>/dev/null | \
    grep -vE "^checkpoint: auto-save" | \
    grep -vE "^checkpoint:" | \
    head -10 | \
    tr '\n' '|' | sed 's/|$//')
  if [[ -z "$msgs" ]]; then
    msgs=$(git log --format="%s" "${base}..HEAD" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
  fi
  echo "squash(${branch}): ${msgs}"
}

count_commits_ahead() {
  local base
  base=$(detect_base_ref)
  git rev-list --count "${base}..HEAD" 2>/dev/null || echo "0"
}

# Phase 1: Tier1 immediate trigger → set semantic_intent=true AND milestone_pending=true
if [[ "$tier1_triggered" == "true" ]]; then
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local squash_suggestion
  squash_suggestion=$(build_squash_suggestion)
  local commits
  commits=$(count_commits_ahead)

  state_update "
    .semantic_intent = true |
    .semantic_intent_reason = \"tier1_keyword\" |
    .last_prompt = \"$USER_PROMPT\" |
    .last_intent_at = \"$now\" |
    .milestone_pending = true |
    .milestone_pending_reason = \"semantic_tier1_keyword\" |
    .milestone_pending_squash_suggestion = \"$squash_suggestion\" |
    .milestone_pending_branch = \"$branch\" |
    .milestone_pending_commits = $commits
  "
  # P0-3: COMPLETELY SILENT — no echo to stdout
  exit 0
fi

# Phase 2: Tier2 → set semantic_intent=true
if [[ "$tier2_signal_detected" == "true" ]]; then
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local squash_suggestion
  squash_suggestion=$(build_squash_suggestion)
  local commits
  commits=$(count_commits_ahead)

  state_update "
    .semantic_intent = true |
    .semantic_intent_reason = \"tier2_keyword\" |
    .last_prompt = \"$USER_PROMPT\" |
    .last_intent_at = \"$now\" |
    .milestone_pending = true |
    .milestone_pending_reason = \"semantic_tier2_keyword\" |
    .milestone_pending_squash_suggestion = \"$squash_suggestion\" |
    .milestone_pending_branch = \"$branch\" |
    .milestone_pending_commits = $commits
  "
  # P0-3: COMPLETELY SILENT — no echo to stdout
  exit 0
fi

# Update last_prompt for context tracking (no semantic intent)
jq --arg prompt "$USER_PROMPT" '.last_prompt = $prompt' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# P0-3: COMPLETELY SILENT — no echo to stdout
exit 0
