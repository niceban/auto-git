# Skill Plan: branch-autonomous-workflow-hooks

## Overview

- **Domain**: Git hooks for Claude Code branch-autonomous workflow
- **Tier**: 2 (Skill + Scripts — shared libraries + hooks)
- **Sub-skills**: 0 (single skill, no sub-skills)
- **Scripts**: 2 shared libraries (logging.sh, state-lib.sh)

## Problem Statement

Current hooks have triple-copy code (P1-6 fix):
- `session-start.sh`, `post-tool.sh`, `post-tool-fail.sh`, `pre-push.sh`, `stop.sh` each duplicate:
  - Lock file handling
  - State file paths
  - Project dir detection
  - Config loading

Additionally:
- P0-3: `semantic-trigger.sh` outputs to stdout, contaminating hook JSON output
- P1-3: `count_uncommitted_lines()` has unreliable `git diff HEAD --stat` parsing

## Architecture

```
hooks-skill-forge/
├── logging.sh          # Shared JSONL logging (hook_log function)
├── state-lib.sh        # Shared state management (init_state, state_get, state_update, detect_base_ref, count_uncommitted_lines)
├── session-start.sh    # Hook: SessionStart (uses logging + state-lib)
├── semantic-trigger.sh  # Hook: UserPromptSubmit (uses logging + state-lib, NO stdout)
├── guard-bash.sh       # Hook: PreToolUse Bash (uses logging, R0-R9 detection)
├── pre-push.sh         # Hook: PreToolUse Bash (uses logging + state-lib, P1-1 remote divergence)
├── post-tool.sh        # Hook: PostToolUse (uses logging + state-lib, test PASS)
├── post-tool-fail.sh   # Hook: PostToolUseFailure (uses logging + state-lib, test FAIL)
├── stop.sh             # Hook: Stop (uses logging + state-lib, single output point)
├── hooks.json          # Plugin hook registration
├── SKILL.md            # Skill documentation
└── README.md           # Version comparison notes
```

## Shared Libraries

### logging.sh

```bash
hook_log() {
  local _level="$1"
  local _hook_name="$2"
  local _message="$3"
  local _branch="${4:-}"
  local _session_id="${5:-}"
  # Outputs JSONL to $LOG_FILE
}
```

Variables prefixed with `_` to avoid namespace collision.

### state-lib.sh

| Function | Purpose |
|----------|---------|
| `init_state()` | Initialize state.json, handle locking, load/create config |
| `state_get()` | Get value from state.json by key |
| `state_update()` | Update state.json with key-value pairs |
| `detect_base_ref()` | Detect base branch (origin/main or main) |
| `count_uncommitted_lines()` | Count uncommitted lines (FIXED: grep "files changed" pattern) |

### P1-3 Fix: count_uncommitted_lines()

**OLD (broken)**:
```bash
git diff HEAD --stat | tail -1 | awk '{print $4}'
```

**NEW (fixed)**:
```bash
git diff HEAD --stat 2>/dev/null | grep "files changed" | awk '{print $NF}' || echo "0"
```

## Hook Specifications

### session-start.sh (SessionStart)

- Initialize state.json with branch info
- Detect branch_type from naming convention
- Calculate commits_since_last_tag
- Preserve awaiting_* flags on same branch

### semantic-trigger.sh (UserPromptSubmit)

**P0-3 FIX**: NO stdout output — all output to stderr or log file only.

- Trigger on semantic commit keywords
- No JSON to stdout (prevents hook contamination)

### guard-bash.sh (PreToolUse Bash)

R0-R9 dangerous command detection:
- R0: File-writing redirects (not to /dev/null)
- R1: git push to main/master
- R2-R3: git push --force / -f (without --force-with-lease)
- R4: git reset --hard
- R5: git clean -x / -X
- R6: git branch -d main/master
- R7: git merge main/master
- R8: git rebase main/master
- R9: git push refspec to main/master

### pre-push.sh (PreToolUse Bash)

- Execute squash when awaiting_squash_push=true
- **P1-1 FIX**: Detect remote main divergence before force-push
  - Check if origin/main moved since last known SHA
  - Warn/abort if remote diverged

### post-tool.sh (PostToolUse Bash|Write)

- Test PASS detection (PASS, ok, passed, 100%)
- Auto-commit threshold check
- Update state.json

### post-tool-fail.sh (PostToolUseFailure)

- Test FAIL detection (FAIL, FAILED, ERROR, 0 passed)
- Update state.json

### stop.sh (Stop)

**P0-3**: Single output point — only this hook outputs to stdout.

- Milestone detection (commits threshold + conventional commits)
- Auto-commit on exit
- Merge/tag confirmation workflow
- Squash push workflow (when awaiting_squash_push)

## Priority Fixes

| Priority | Issue | Fix |
|----------|-------|-----|
| P0-3 | semantic-trigger.sh stdout contamination | Remove all stdout, use stderr/log only |
| P1-1 | pre-push.sh remote divergence | Add `git fetch origin main` + divergence check |
| P1-3 | count_uncommitted_lines() unreliability | Use grep "files changed" pattern |
| P1-6 | Triple-copy code | Extract to state-lib.sh + logging.sh |

## Quality Gates

- All scripts: `set -euo pipefail`
- All shell scripts: `chmod +x`
- No triple-copy — use source for libs
- No stdout from semantic-trigger.sh
- Hooks return proper JSON output format

## Version Comparison

| Aspect | v1.0.0 (Current) | v2.0.0 (Planned) |
|--------|-------------------|------------------|
| Shared libs | None (triple-copy) | logging.sh + state-lib.sh |
| semantic-trigger.sh stdout | Yes (P0-3 bug) | No (fixed) |
| count_uncommitted_lines | Unreliable | Fixed pattern |
| Remote divergence | No check | P1-1 check added |
| Shell safety | Partial | Full (set -euo pipefail) |

## Next Steps

Run `/skill-forge build hooks-skill-forge` to scaffold the skill.
