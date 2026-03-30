#!/usr/bin/env bash
# session-start.sh — Initialize state.json on SessionStart
# Hook: SessionStart

set -euo pipefail

source "$(dirname "$0")/logging.sh" 2>/dev/null || true
source "$(dirname "$0")/state-lib.sh"

acquire_lock "session-start.sh"

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.claude/plugins/branch-autonomous}"
STATE_FILE="$STATE_DIR/state.json"
CONFIG_FILE="$STATE_DIR/config.json"

# Create state dir first
mkdir -p "$STATE_DIR"

# Config defaults
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" << 'EOF'
{
  "uncommitted_files_threshold": 5,
  "uncommitted_lines_threshold": 1000,
  "milestone_commits_threshold": 10,
  "auto_commit_message_prefix": "checkpoint: auto-save",
  "merge_delete_branch": true,
  "release_tag_prefix": "v"
}
EOF
fi

# Detect project
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ ! -d "$PROJECT_DIR/.git" ]] && exit 0
cd "$PROJECT_DIR"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Initialize state (preserves workflow flags if resuming same branch)
init_state "$branch"

echo "session-start: branch=$branch"
hook_log "session-start" "session_init" branch="$branch"
exit 0
