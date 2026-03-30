#!/usr/bin/env bash
# state-lib.sh — Shared state management for all branch-autonomous hooks
# SINGLE init_state() — P1-6: no triple-copy

# Guard against double-sourcing
[[ -n "${STATE_LIB_SOURCED:-}" ]] && return 0
STATE_LIB_SOURCED=1

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.claude/plugins/branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
CONFIG_FILE="$STATE_DIR/config.json"
LOCK_FILE="$STATE_DIR/.lock"

# ─── Lock acquisition ──────────────────────────────────────────────────────────
acquire_lock() {
  local lock_name="${1:-hook}"
  local lock_file="${LOCK_FILE}"

  if command -v flock &>/dev/null; then
    exec 200>"$lock_file"
    flock -n 200 || {
      echo "$lock_name: already locked, skipping" >&2
      exit 0
    }
  else
    if [[ -f "$lock_file" ]]; then
      local oldpid
      oldpid=$(cat "$lock_file" 2>/dev/null || echo "")
      if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
        echo "$lock_name: already locked (PID $oldpid), skipping" >&2
        exit 0
      fi
    fi
    echo $$ > "$lock_file"
    trap 'rm -f "$lock_file"' EXIT
  fi
}

# ─── Config helpers ────────────────────────────────────────────────────────────
config_get() {
  local key="$1"
  local default="${2:-}"
  jq -r ".${key} // \"$default\"" "$CONFIG_FILE" 2>/dev/null || echo "$default"
}

# ─── State helpers ─────────────────────────────────────────────────────────────
state_get() {
  local key="$1"
  jq -r ".${key} // empty" "$STATE_FILE" 2>/dev/null || echo ""
}

state_update() {
  local jq_args="$1"
  jq "$jq_args" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# ─── P1-6: SINGLE init_state() — no triple-copy ────────────────────────────────
init_state() {
  local branch="$1"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local branch_type="other"
  [[ "$branch" == feature/* ]] && branch_type="feature"
  [[ "$branch" == fix/* ]]     && branch_type="fix"
  [[ "$branch" == hotfix/* ]]  && branch_type="hotfix"

  local last_tag
  last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  local commits_since_tag=0
  if [[ -n "$last_tag" ]]; then
    commits_since_tag=$(git rev-list --count HEAD ^"$last_tag" 2>/dev/null || echo "0")
  fi

  local last_commit_at="$now"
  local last_commit_message=""
  if git rev-parse HEAD &>/dev/null; then
    last_commit_at=$(git log -1 --format="%aI" 2>/dev/null | head -1 || echo "$now")
    last_commit_message=$(git log -1 --format="%s" 2>/dev/null | head -1 || echo "")
  fi

  # Preserve workflow flags if resuming same branch
  local existing_branch
  existing_branch=$(jq -r '.branch // ""' "$STATE_FILE" 2>/dev/null || echo "")
  local awaiting_squash_push="false"
  local awaiting_merge_confirmation="false"
  local milestone_pending="false"
  local milestone_pending_reason="null"
  local milestone_pending_squash_suggestion="null"
  local milestone_pending_branch="null"
  local milestone_pending_commits="0"
  local semantic_intent="false"
  local semantic_intent_reason="null"
  local milestone_reason="null"
  local test_passed="false"
  local test_passed_at="null"
  local test_failed_at="null"

  if [[ "$existing_branch" == "$branch" ]] && [[ -f "$STATE_FILE" ]]; then
    awaiting_squash_push=$(jq -r '.awaiting_squash_push // false' "$STATE_FILE" 2>/dev/null || echo "false")
    awaiting_merge_confirmation=$(jq -r '.awaiting_merge_confirmation // false' "$STATE_FILE" 2>/dev/null || echo "false")
    milestone_pending=$(jq -r '.milestone_pending // false' "$STATE_FILE" 2>/dev/null || echo "false")
    milestone_pending_reason=$(jq -r '.milestone_pending_reason // null' "$STATE_FILE" 2>/dev/null || echo "null")
    milestone_pending_squash_suggestion=$(jq -r '.milestone_pending_squash_suggestion // null' "$STATE_FILE" 2>/dev/null || echo "null")
    milestone_pending_branch=$(jq -r '.milestone_pending_branch // null' "$STATE_FILE" 2>/dev/null || echo "null")
    milestone_pending_commits=$(jq -r '.milestone_pending_commits // 0' "$STATE_FILE" 2>/dev/null || echo "0")
    semantic_intent=$(jq -r '.semantic_intent // false' "$STATE_FILE" 2>/dev/null || echo "false")
    semantic_intent_reason=$(jq -r '.semantic_intent_reason // null' "$STATE_FILE" 2>/dev/null || echo "null")
    milestone_reason=$(jq -r '.milestone_reason // null' "$STATE_FILE" 2>/dev/null || echo "null")
    test_passed=$(jq -r '.test_passed // false' "$STATE_FILE" 2>/dev/null || echo "false")
    test_passed_at=$(jq -r '.test_passed_at // null' "$STATE_FILE" 2>/dev/null || echo "null")
    test_failed_at=$(jq -r '.test_failed_at // null' "$STATE_FILE" 2>/dev/null || echo "null")
  fi

  jq -n \
    --arg branch "$branch" \
    --arg branch_type "$branch_type" \
    --arg now "$now" \
    --arg last_commit_at "$last_commit_at" \
    --arg last_commit_message "$last_commit_message" \
    --argjson commits_since_tag "$commits_since_tag" \
    --argjson awaiting_squash_push "$awaiting_squash_push" \
    --argjson awaiting_merge_confirmation "$awaiting_merge_confirmation" \
    --argjson milestone_pending "$milestone_pending" \
    --arg milestone_pending_reason "$milestone_pending_reason" \
    --arg milestone_pending_squash_suggestion "$milestone_pending_squash_suggestion" \
    --arg milestone_pending_branch "$milestone_pending_branch" \
    --argjson milestone_pending_commits "$milestone_pending_commits" \
    --argjson semantic_intent "$semantic_intent" \
    --arg semantic_intent_reason "$semantic_intent_reason" \
    --arg milestone_reason "$milestone_reason" \
    --argjson test_passed "$test_passed" \
    --arg test_passed_at "$test_passed_at" \
    --arg test_failed_at "$test_failed_at" \
    '{
      version: "4.0",
      branch: $branch,
      branch_type: $branch_type,
      test_passed: $test_passed,
      test_passed_at: $test_passed_at,
      test_failed_at: $test_failed_at,
      uncommitted_files: 0,
      uncommitted_lines: 0,
      last_commit_at: $last_commit_at,
      last_commit_message: $last_commit_message,
      milestone: false,
      milestone_reason: $milestone_reason,
      awaiting_squash_push: $awaiting_squash_push,
      awaiting_merge_confirmation: $awaiting_merge_confirmation,
      commits_since_last_tag: $commits_since_tag,
      created_at: $now,
      semantic_intent: $semantic_intent,
      semantic_intent_reason: $semantic_intent_reason,
      last_prompt: "",
      last_intent_at: null,
      milestone_command_invoked: false,
      milestone_command_msg: null,
      milestone_pending: $milestone_pending,
      milestone_pending_reason: $milestone_pending_reason,
      milestone_pending_squash_suggestion: $milestone_pending_squash_suggestion,
      milestone_pending_branch: $milestone_pending_branch,
      milestone_pending_commits: $milestone_pending_commits,
      backup_branch: null,
      backup_created_at: null
    }' > "$STATE_FILE"
}

# ─── Git helpers ───────────────────────────────────────────────────────────────
detect_base_ref() {
  local base="main"
  if ! git rev-parse --verify "origin/${base}" &>/dev/null; then
    if git rev-parse --verify "$base" &>/dev/null; then
      base="main"
    else
      base="HEAD"
    fi
  fi
  echo "$base"
}

get_last_tag() {
  git describe --tags --abbrev=0 2>/dev/null || echo ""
}

get_commits_since_tag() {
  local last_tag="$1"
  if [[ -n "$last_tag" ]]; then
    git rev-list --count HEAD ^"$last_tag" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# ─── P1-3: count_uncommitted_lines with correct grep pattern ──────────────────
count_uncommitted_lines() {
  local summary
  summary=$(git diff HEAD --stat 2>/dev/null | grep "files changed" | awk '{print $NF}' || true)
  echo "${summary//[^0-9]/}"
}

count_uncommitted_files() {
  git status --porcelain 2>/dev/null | wc -l | tr -d ' '
}
