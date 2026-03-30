#!/usr/bin/env bash
# guard-bash.sh — Main branch protection + dangerous command blocking
# Hook: PreToolUse (Bash)
# stdin: tool input JSON
# exit 0 + JSON deny = blocked; exit 0 (no JSON) = allowed

set -euo pipefail

source "$(dirname "$0")/logging.sh" 2>/dev/null || true

STATE_DIR="${BRANCH_AUTONOMOUS_DIR:-$HOME/.claude/plugins/branch-autonomous}"
LOCK_FILE="$STATE_DIR/.lock"

acquire_lock "guard-bash.sh"

# Read tool input JSON
input=$(cat)
COMMAND=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

[[ -z "$COMMAND" ]] && exit 0

# Helper: check if on main branch
is_on_main_branch() {
  local pwd_branch
  pwd_branch=$(git -C "$PWD" symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
  [[ "$pwd_branch" != "main" ]] && [[ "$pwd_branch" != "unknown" ]] && return 1

  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    local proj_dir="${CLAUDE_PROJECT_DIR}"
    if git -C "$proj_dir" rev-parse --show-toplevel &>/dev/null; then
      local proj_branch
      proj_branch=$(git -C "$proj_dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
      [[ "$proj_branch" != "main" ]] && return 1
    fi
  fi
  return 0
}

# Helper: check if dangerous
is_dangerous_bash() {
  local cmd="$1"

  # R1: File-writing redirection (> or >>)
  if echo "$cmd" | grep -qE '(\s>>|\s>)' && \
     ! echo "$cmd" | grep -qE '>(2\s*)?\s*/dev/null'; then
    return 0
  fi

  # R2: git push to main/master
  if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*(main|master|refs/heads/main|refs/heads/master)'; then
    return 0
  fi

  # R3: bare --force (no --force-with-lease)
  if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*'"--force($| )" && \
     ! echo "$cmd" | grep -qE '--force-with-lease'; then
    return 0
  fi

  # R3b: -f short form
  if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*'"-f($| )" && \
     ! echo "$cmd" | grep -qE '--force-with-lease'; then
    return 0
  fi

  # R4: git reset --hard
  if echo "$cmd" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard$'; then
    return 0
  fi

  # R5: git clean -x or -X
  if echo "$cmd" | grep -qE 'git[[:space:]]+clean[[:space:]]+-[fFxX]'; then
    return 0
  fi

  # R6: delete main/master
  if echo "$cmd" | grep -qE 'git[[:space:]]+branch[[:space:]]+-[Dd][[:space:]]+(main|master)'; then
    return 0
  fi

  # R7: merge onto main/master
  if echo "$cmd" | grep -qE 'git[[:space:]]+merge[[:space:]]+[^;]*(main|master)'; then
    return 0
  fi

  # R8: rebase onto main/master
  if echo "$cmd" | grep -qE 'git[[:space:]]+rebase[[:space:]]+[^;]*(main|master)'; then
    return 0
  fi

  # R9: refspec push to main/master
  if echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+[^;]*:[^;]*(main|master)'; then
    return 0
  fi

  return 1
}

# Helper: git commit on main
is_commit_on_main() {
  local cmd="$1"
  if echo "$cmd" | grep -qE '^git[[:space:]]+commit[[:space:]]' && \
     ! echo "$cmd" | grep -qE 'git[[:space:]]+commit[[:space:]]+--abort'; then
    return 0
  fi
  return 1
}

# Core logic
if ! is_on_main_branch; then
  # Inside feature branch — always allow
  exit 0
fi

# On main branch
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
[[ ! -d "$PROJECT_DIR/.git" ]] && exit 0

# R0: git commit on main → auto-create branch and commit there
if is_commit_on_main "$COMMAND"; then
  local commit_msg
  commit_msg=$(echo "$COMMAND" | sed -n 's/.*-m[[:space:]]*'"'"'\([^'"'"']*\)'"'"'.*/\1/p' | head -1 || echo "")
  if [[ -z "$commit_msg" ]]; then
    commit_msg=$(echo "$COMMAND" | sed -n 's/.*-m[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || echo "")
  fi
  if [[ -z "$commit_msg" ]]; then
    commit_msg="checkpoint: auto-save $(date +%Y%m%d-%H%M%S)"
  fi

  local branch_name="feature/auto-$(date +%Y%m%d-%H%M%S)"

  cd "$PROJECT_DIR" && \
    git checkout -b "$branch_name" 2>&1 && \
    eval "$COMMAND" 2>&1
  local checkout_status=$?

  if [[ $checkout_status -eq 0 ]]; then
    exec_result="BRANCH_AUTONOMOUS_BRANCH_CREATED:$branch_name"
  else
    exec_result="BRANCH_AUTONOMOUS_ERROR:command failed with exit $checkout_status"
  fi

  if echo "$exec_result" | grep -q "BRANCH_AUTONOMOUS_BRANCH_CREATED"; then
    local created_branch
    created_branch=$(echo "$exec_result" | sed 's/.*BRANCH_AUTONOMOUS_BRANCH_CREATED://')
    DENY_REASON="main branch: auto-created $created_branch and committed on it. Original command denied."
    jq -n --arg r "$DENY_REASON" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
  else
    DENY_REASON="Cannot commit on main branch: $exec_result"
    jq -n --arg r "$DENY_REASON" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
  fi
  exit 0
fi

# Dangerous command on main → block
if is_dangerous_bash "$COMMAND"; then
  hook_log "guard-bash" "dangerous_blocked" branch="main" command="$COMMAND"
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
