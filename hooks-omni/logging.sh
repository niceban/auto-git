#!/usr/bin/env bash
# logging.sh — Shared logging for all branch-autonomous hooks
# Usage: source "$(dirname "$0")/logging.sh"

: "${BRANCH_AUTONOMOUS_DIR:=$HOME/.claude/plugins/branch-autonomous}"
LOG_DIR="$BRANCH_AUTONOMOUS_DIR/logs"
LOG_FILE="$LOG_DIR/hooks.log"

# Ensure log directory and file exist
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# Log rotation: keep last 10000 lines
if [ $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) -gt 10000 ]; then
  head -5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# hook_log — append a JSONL log entry
# Usage: hook_log "HookName" "message" [key=value ...]
hook_log() {
  local hook_name="$1"
  local msg="$2"
  shift 2
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local extras=""
  for pair in "$@"; do
    extras="$extras \"$(echo "$pair" | cut -d= -f1)\": \"$(echo "$pair" | cut -d= -f2)\","
  done
  extras="${extras%,}"
  if [ -n "$extras" ]; then
    echo "{\"ts\":\"$ts\",\"hook\":\"$hook_name\",\"msg\":\"$msg\",$extras}" >> "$LOG_FILE"
  else
    echo "{\"ts\":\"$ts\",\"hook\":\"$hook_name\",\"msg\":\"$msg\"}" >> "$LOG_FILE"
  fi
}
