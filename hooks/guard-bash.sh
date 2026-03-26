#!/usr/bin/env bash
# guard-bash.sh — Block dangerous Bash commands on main branch
# Hook: PreToolUse (Bash)
# stdin: tool input JSON
# exit 0 + JSON deny = blocked; exit 0 (no JSON) = allowed
#
# ARCHITECTURE: Pure branch detection via git symbolic-ref --short HEAD
# No worktree logic — all development happens on feature/* branches only

set -euo pipefail

# Read tool input JSON
input=$(cat)
COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

[[ -z "$COMMAND" ]] && exit 0

# ─── Helper: Check if we are on the main branch ───────────────────────────────
is_on_main_branch() {
  local pwd_branch proj_dir proj_branch

  # Check PWD branch
  pwd_branch=$(git -C "$PWD" symbolic-ref --short HEAD 2>/dev/null || echo "unknown")

  # If PWD is already non-main, trust it
  [[ "$pwd_branch" != "main" ]] && [[ "$pwd_branch" != "unknown" ]] && return 1

  # PWD is main — check CLAUDE_PROJECT_DIR as fallback
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    proj_dir="${CLAUDE_PROJECT_DIR}"
    if git -C "$proj_dir" rev-parse --show-toplevel &>/dev/null; then
      proj_branch=$(git -C "$proj_dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
      [[ "$proj_branch" != "main" ]] && return 1
    fi
  fi

  # Both are main (or unknown)
  return 0
}

# ─── Helper: Check if command is dangerous ────────────────────────────────────
is_dangerous_bash() {
  local cmd="$1"

  # Rule 1: File-writing commands (>> or > with output, not to /dev/null)
  if echo "$cmd" | grep -qE '(\s>>|\s>)' && \
     ! echo "$cmd" | grep -qE '>(2\s*)?\s*/dev/null'; then
    return 0
  fi

  # Rule 2: git push to main or master (explicit ref)
  if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*(main|master|refs/heads/main|refs/heads/master)'; then
    return 0
  fi

  # Rule 3: bare --force (no --force-with-lease)
  if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*'"--force($| )" && \
     ! echo "$cmd" | grep -qE '--force-with-lease'; then
    return 0
  fi

  # Rule 3b: -f short form
  if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*'"-f($| )" && \
     ! echo "$cmd" | grep -qE '--force-with-lease'; then
    return 0
  fi

  # Rule 4: git reset --hard (bare form only)
  if echo "$cmd" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard$'; then
    return 0
  fi

  # Rule 5: git clean -x or -X
  if echo "$cmd" | grep -qE 'git[[:space:]]+clean[[:space:]]+-[fFxX]'; then
    return 0
  fi

  # Rule 6: delete main/master
  if echo "$cmd" | grep -qE 'git[[:space:]]+branch[[:space:]]+-[Dd][[:space:]]+(main|master)'; then
    return 0
  fi

  # Rule 7: merge onto main/master
  if echo "$cmd" | grep -qE 'git[[:space:]]+merge[[:space:]]+[^;]*(main|master)'; then
    return 0
  fi

  # Rule 8: rebase onto main/master
  if echo "$cmd" | grep -qE 'git[[:space:]]+rebase[[:space:]]+[^;]*(main|master)'; then
    return 0
  fi

  # Rule 9: refspec push to main/master (e.g. git push origin HEAD:refs/heads/main)
  if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*:[^;]*(main|master)'; then
    return 0
  fi

  return 1
}

# ─── Core Logic ────────────────────────────────────────────────────────────────
if ! is_on_main_branch; then
  # Inside a feature branch — always allow (isolated development)
  exit 0
fi

# In main branch — check for dangerous commands
if is_dangerous_bash "$COMMAND"; then
  DENY_REASON="Cannot run dangerous commands on main branch. Switch to a feature branch first."
  jq -n --arg r "$DENY_REASON" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi

exit 0
