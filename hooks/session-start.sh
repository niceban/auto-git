#!/usr/bin/env bash
# session-start.sh — Initialize state.json on SessionStart
# Hook: session-start (async: false)
# Location: ~/.branch-autonomous/hooks/session-start.sh

set -euo pipefail

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
CONFIG_FILE="$STATE_DIR/config.json"
LOCK_FILE="$STATE_DIR/.lock"

# ─── Create state dir first ────────────────────────────────────────────────────
mkdir -p "$STATE_DIR"

# ─── Lock for concurrency safety ────────────────────────────────────────────────
if command -v flock &>/dev/null; then
  exec 200>"$LOCK_FILE"
  flock -n 200 || { echo "session-start.sh: already locked" >&2; exit 0; }
else
  # macOS/Linux fallback: simple exclusive lock via trap
  if [[ -f "$LOCK_FILE" ]]; then
    local oldpid
    oldpid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
      echo "session-start.sh: already locked (PID $oldpid)" >&2
      exit 0
    fi
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
fi

# ─── Config defaults ───────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" << 'EOF'
{
  "uncommitted_files_threshold": 5,
  "uncommitted_lines_threshold": 100,
  "milestone_commits_threshold": 10,
  "auto_commit_message_prefix": "checkpoint: auto-save",
  "merge_delete_branch": true,
  "release_tag_prefix": "v"
}
EOF
fi

# ─── Detect branch ────────────────────────────────────────────────────────────
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  echo "session-start.sh: not in a git repository, skipping" >&2
  exit 0
fi

cd "$PROJECT_DIR"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")
session_id="${CLAUDE_SESSION_ID:-session-$(date +%s)}"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ─── Derive branch_type ───────────────────────────────────────────────────────
branch_type="other"
if [[ "$branch" == feature/* ]]; then
  branch_type="feature"
elif [[ "$branch" == fix/* ]]; then
  branch_type="fix"
elif [[ "$branch" == hotfix/* ]]; then
  branch_type="hotfix"
fi

# ─── Calculate commits_since_last_tag ─────────────────────────────────────────
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [[ -n "$last_tag" ]]; then
  commits_since_tag=$(git rev-list --count HEAD ^"$last_tag" 2>/dev/null || echo "0")
else
  commits_since_tag=0
fi

# ─── Get last commit info ─────────────────────────────────────────────────────
last_commit_at="$now"
last_commit_message=""

if git rev-parse HEAD &>/dev/null; then
  last_commit_at=$(git log -1 --format="%aI" 2>/dev/null | head -1 || echo "$now")
  last_commit_message=$(git log -1 --format="%s" 2>/dev/null | head -1 || echo "")
fi

# ─── Load existing state (preserve awaiting_* flags on same branch) ─────────────
awaiting_squash_push="false"
awaiting_merge_confirmation="false"

if [[ -f "$STATE_FILE" ]]; then
  existing_branch=$(jq -r '.branch // ""' "$STATE_FILE" 2>/dev/null || echo "")
  if [[ "$existing_branch" == "$branch" ]]; then
    # Preserve flags when resuming same branch
    awaiting_squash_push=$(jq -r '.awaiting_squash_push // false' "$STATE_FILE" 2>/dev/null || echo "false")
    awaiting_merge_confirmation=$(jq -r '.awaiting_merge_confirmation // false' "$STATE_FILE" 2>/dev/null || echo "false")
  fi
fi

# ─── Write state.json ─────────────────────────────────────────────────────────
jq -n \
  --arg branch "$branch" \
  --arg session_id "$session_id" \
  --arg branch_type "$branch_type" \
  --arg now "$now" \
  --arg last_commit_at "$last_commit_at" \
  --arg last_commit_message "$last_commit_message" \
  --arg awaiting_squash_push "$awaiting_squash_push" \
  --arg awaiting_merge_confirmation "$awaiting_merge_confirmation" \
  --argjson commits_since_tag "$commits_since_tag" \
  '{
    version: "3.0",
    session_id: $session_id,
    branch: $branch,
    branch_type: $branch_type,
    test_passed: false,
    test_passed_at: null,
    test_failed_at: null,
    uncommitted_files: 0,
    uncommitted_lines: 0,
    last_commit_at: $last_commit_at,
    last_commit_message: $last_commit_message,
    milestone: false,
    milestone_reason: null,
    awaiting_squash_push: ($awaiting_squash_push == "true"),
    awaiting_merge_confirmation: ($awaiting_merge_confirmation == "true"),
    commits_since_last_tag: $commits_since_tag,
    created_at: $now
  }' > "$STATE_FILE"

echo "session-start: branch=$branch type=$branch_type"
exit 0
