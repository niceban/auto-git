#!/usr/bin/env bash
# stop.sh — Auto-commit threshold + milestone detection + merge/tag confirmation
# Hook: Stop  (fires every time Claude finishes responding, user can input)
# Location: ~/.claude/plugins/branch-autonomous/hooks/stop.sh

set -euo pipefail

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-~/.claude/plugins/branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
CONFIG_FILE="$STATE_DIR/config.json"
LOCK_FILE="$STATE_DIR/.lock"

# Use flock if available (Linux), fall back to PID lock (macOS)
if command -v flock &>/dev/null; then
  exec 200>"$LOCK_FILE"
  flock -n 200 || { echo "stop.sh: already locked, skipping" >&2; exit 0; }
else
  if [[ -f "$LOCK_FILE" ]]; then
    local pid; pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "stop.sh: already locked (PID $pid), skipping" >&2
      exit 0
    fi
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
fi

# ─── Load config ──────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "stop.sh: config.json not found, skipping" >&2
  exit 0
fi

MILESTONE_COMMITS=$(jq -r '.milestone_commits_threshold // 10' "$CONFIG_FILE")

# ─── Detect project ───────────────────────────────────────────────────────────
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ ! -d "$PROJECT_DIR/.git" ]] && exit 0

cd "$PROJECT_DIR"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# ─── Auto-initialize state.json if missing (no restart needed) ───────────────
if [[ ! -f "$STATE_FILE" ]]; then
  echo "stop.sh: state.json missing, auto-initializing for branch=$branch..."
  session_id="${CLAUDE_SESSION_ID:-session-$(date +%s)}"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  branch_type="other"
  [[ "$branch" == feature/* ]] && branch_type="feature"
  [[ "$branch" == fix/* ]]     && branch_type="fix"
  [[ "$branch" == hotfix/* ]]   && branch_type="hotfix"

  last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  commits_since_tag=$([[ -n "$last_tag" ]] && git rev-list --count HEAD ^"$last_tag" 2>/dev/null || echo "0")

  last_commit_at="$now"
  last_commit_message=""
  if git rev-parse HEAD &>/dev/null; then
    last_commit_at=$(git log -1 --format="%aI" 2>/dev/null | head -1 || echo "$now")
    last_commit_message=$(git log -1 --format="%s" 2>/dev/null | head -1 || echo "")
  fi

  jq -n \
    --arg branch "$branch" \
    --arg session_id "$session_id" \
    --arg branch_type "$branch_type" \
    --arg now "$now" \
    --arg last_commit_at "$last_commit_at" \
    --arg last_commit_message "$last_commit_message" \
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
      awaiting_squash_push: false,
      awaiting_merge_confirmation: false,
      commits_since_last_tag: $commits_since_tag,
      created_at: $now
    }' > "$STATE_FILE"
  echo "stop.sh: state initialized → $STATE_FILE"
fi

# ─── Guard: must not be on main ──────────────────────────────────────────────
if [[ "$branch" == "main" ]]; then
  echo "stop.sh: on main, skipping" >&2
  exit 0
fi

# ─── Auto-commit threshold check (fires every Stop = every Claude response) ──
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
    '.last_commit_at = $now |
     .last_commit_message = $msg' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "stop.sh: auto-committed → $auto_msg"
fi

# ─── Milestone detection ───────────────────────────────────────────────────────
milestone="false"
milestone_reason="null"
awaiting_squash_push=$(jq -r '.awaiting_squash_push' "$STATE_FILE")
awaiting_merge=$(jq -r '.awaiting_merge_confirmation' "$STATE_FILE")
test_passed=$(jq -r '.test_passed' "$STATE_FILE")

# Skip if already in a workflow
if [[ "$awaiting_squash_push" == "true" ]] || [[ "$awaiting_merge" == "true" ]]; then
  exit 0
fi

# Count commits since last tag
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [[ -n "$last_tag" ]]; then
  commits_since_tag=$(git rev-list --count HEAD ^"$last_tag" 2>/dev/null || echo "0")
else
  commits_since_tag=0
fi

# Trigger 1: commit count threshold
if [[ "$commits_since_tag" -ge "$MILESTONE_COMMITS" ]]; then
  milestone="true"
  milestone_reason="commits_threshold"
fi

# Trigger 2: conventional commit prefix
if [[ "$milestone" == "false" ]]; then
  last_commit_msg=$(git log -1 --format="%s" 2>/dev/null || echo "")
  if echo "$last_commit_msg" | grep -qE "^(feat|fix|perf|ci):"; then
    milestone="true"
    milestone_reason="conventional_commit"
  fi
fi

# ─── Interaction Point 1: Milestone confirmed with passing tests ──────────────
if [[ "$milestone" == "true" ]] && [[ "$test_passed" == "true" ]]; then
  # Generate squash message suggestion
  msgs=$(git log --format="%s" origin/main..HEAD 2>/dev/null | tr '\n' '|' | sed 's/|$//')
  branch_type=$(jq -r '.branch_type' "$STATE_FILE")
  squash_suggestion="squash(${branch}): ${msgs}"
  echo ""
  echo "========================================"
  echo "=== Milestone Reached ==="
  echo "Reason: $milestone_reason"
  echo "Tests: PASSED"
  echo "Commits to squash: $commits_since_tag"
  echo ""
  echo "Suggested squash message:"
  echo "  $squash_suggestion"
  echo ""
  echo -n "Accept this squash message? [Y/n] "
  read -r response </dev/tty || response="y"
  case "$response" in
    [nN]*) echo "Milestone acknowledged but squash deferred." ;;
    *)
      # User confirmed: set awaiting_squash_push = true
      jq \
        --arg reason "$milestone_reason" \
        '.milestone = false |
         .milestone_reason = $reason |
         .awaiting_squash_push = true' \
        "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
      echo "Confirmed. Next 'git push' will squash and force-push."
      ;;
  esac
  exit 0
fi

# ─── Interaction Point 2: Merge + Tag confirmation ────────────────────────────
if [[ "$awaiting_merge" == "true" ]]; then
  diff_stats=$(git diff --stat origin/main..HEAD 2>/dev/null | tail -1 || echo "")
  current_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
  # Simple version bump
  major=$(echo "$current_tag" | cut -d. -f1 | tr -d 'v')
  minor=$(echo "$current_tag" | cut -d. -f2)
  patch=$(echo "$current_tag" | cut -d. -f3)
  next_tag="v${major}.$((minor + 1)).0"

  echo ""
  echo "========================================"
  echo "=== Merge Ready ==="
  echo "Branch: $branch (1 commit ahead of main)"
  echo "Diff: $diff_stats"
  echo ""
  echo "Current version: $current_tag"
  echo "Suggested tag:   $next_tag"
  echo ""
  echo -n "Merge to main and tag as $next_tag? [Y/n] "
  read -r response </dev/tty || response="y"
  case "$response" in
    [nN]*) echo "Merge deferred." ;;
    *)
      # Execute merge + tag + push + cleanup
      git checkout main && git merge --no-ff "$branch"
      git tag -a "$next_tag" -m "release: $next_tag $(date +%Y-%m-%d)"
      git push origin main && git push --tags
      if jq -r '.merge_delete_branch // true' "$CONFIG_FILE" | grep -q "true"; then
        git branch -d "$branch"
      fi
      jq '.awaiting_merge_confirmation = false |
          .awaiting_squash_push = false' \
         "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
      echo "Merged and tagged as $next_tag."
      ;;
  esac
  exit 0
fi

exit 0
