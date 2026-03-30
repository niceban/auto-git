---
name: hooks-omni
description: Branch-autonomous Git workflow hooks for Claude Code. Automates checkpoint commits, milestone squash, and merge-to-main with only two user confirmations. Use when working on feature branches and wanting autonomous git workflow — say "搞定"、"done", or push a conventional commit to trigger milestone. Not for users who prefer manual git control.
---

# hooks-omni: Branch-Autonomous Git Workflow

Branch-autonomous Git workflow for Claude Code — zero manual git operations, two confirmation points, everything else automatic.

## Overview

**Purpose**: Automate the tedious parts of Git workflow — checkpoint commits, squash, force-push, merge, tag — while keeping human approval at exactly two decision points.

**Core principle**: No worktrees. Only branches. All development on `feature/*` branches, main stays clean.

**Two confirmation points**:
1. **Squash confirmation** — triggered by semantic intent ("搞定"), conventional commit, or 10+ commits
2. **Merge confirmation** — after squash push succeeds

## Hook Architecture

7 hooks registered via `manifest.json`:

| Hook | Event | Matcher | Purpose |
|------|-------|---------|---------|
| session-start | SessionStart | — | Initialize state.json |
| semantic-trigger | UserPromptSubmit | — | Detect user "done" intent — completely silent |
| guard-bash | PreToolUse | Bash | Block dangerous commands on main |
| pre-push | PreToolUse | Bash | Execute squash push when milestone confirmed |
| post-tool | PostToolUse | Bash\|Write | Detect test PASS + auto-commit threshold |
| post-tool-fail | PostToolUseFailure | * | Detect test FAIL |
| stop | Stop | — | Milestone detection + interaction prompts |

## State Management

State file: `$HOME/.claude/plugins/branch-autonomous/state.json` (version 4.0)

**Key state flags**:
- `test_passed` — set by post-tool.sh when test PASS detected
- `awaiting_squash_push` — set after user confirms squash
- `awaiting_merge_confirmation` — set after squash push succeeds
- `milestone_pending` — set by stop.sh or semantic-trigger.sh
- `semantic_intent` — set by semantic-trigger.sh on Tier1/Tier2 keywords

## Shared Libraries

All hooks source these common libraries from `hooks-omni/`:

**logging.sh** — `hook_log()` function for structured JSONL logging
**state-lib.sh** — `init_state()`, `state_get()`, `state_update()`, `acquire_lock()`, `detect_base_ref()`

## Hook Specifications

### 1. session-start.sh

**Event**: SessionStart | **Async**: false

Initialize state.json on Claude session start:
- Detect branch, branch_type (feature/fix/hotfix)
- Set initial flags (test_passed=false, awaiting_*=false)
- Create config.json with defaults if missing

**Default thresholds**:
- `uncommitted_files_threshold`: 5
- `uncommitted_lines_threshold`: 1000
- `milestone_commits_threshold`: 10

### 2. semantic-trigger.sh

**Event**: UserPromptSubmit | **Async**: false | **P0-3: COMPLETELY SILENT**

Detect user semantic intent without any output. Updates state only.

**Tier 1 keywords** (immediate trigger):
`v1`, `v2`, `v3`, `release`, `搞定`, `搞定了`, `完成了`, `测试通过`, `✓`, `封板`, `milestone`, `done`, `finished`, `complete`

**Tier 2 keywords** (strong signal):
`差不多`, `快好了`, `感觉可以了`, `nearly done`, `almost done`, `almost there`, `good enough`

**Effect**: Sets `semantic_intent=true` + `milestone_pending=true` in state.json

### 3. guard-bash.sh

**Event**: PreToolUse (Bash) | **Async**: false

Block dangerous commands on main branch:
- File writes with redirection (`>>`, `>`, `tee`, `sed -i`)
- `git push` to main/master
- `git push --force` (without `--force-with-lease`)
- `git reset --hard`
- `git clean -x` or `-X`
- `git branch -d/-D main/master`
- `git merge` onto main/master
- `git rebase` onto main/master

**Special behavior**: If user tries `git commit` on main, auto-create a feature branch and commit there instead of blocking.

### 4. pre-push.sh

**Event**: PreToolUse (Bash) | **Async**: false

When `awaiting_squash_push=true`:
1. Detect remote main divergence (P1-1: force-push detection)
2. Create backup branch before squash
3. Build squash message (filter checkpoint commits)
4. Execute: `git reset --soft origin/main` → `git commit -m "squash(...): ..."` → `git push --force-with-lease`
5. On success: set `awaiting_merge_confirmation=true`

### 5. post-tool.sh

**Event**: PostToolUse (Bash|Write) | **Async**: true

After each Bash/Write tool execution:
1. Parse output for test PASS patterns: `PASS`, `ok `, `✓`, `All tests passed`, `passed`, `100%`
2. If PASS detected: set `test_passed=true`, `test_passed_at=now`
3. Check auto-commit threshold: if `uncommitted_files >= 5` OR `uncommitted_lines >= 1000`
4. Auto-commit with message: `checkpoint: auto-save YYYYMMDD-HHMMSS`

### 6. post-tool-fail.sh

**Event**: PostToolUseFailure | **Matcher**: * | **Async**: true

On any tool failure: set `test_passed=false`, `test_failed_at=now`

### 7. stop.sh

**Event**: Stop | **Async**: false

On session stop, check for milestone readiness:

**Milestone triggers** (any one):
1. `commits_since_tag >= 10`
2. Last commit matches `^(feat|fix|perf|ci):`
3. `semantic_intent == true` (from semantic-trigger.sh)

**Interaction Point 1 — Squash confirmation**:
```
=== Milestone Reached ===
Reason: <conventional_commit | commits_threshold | semantic_trigger>
Tests: PASSED / NOT YET
Commits to squash: N

Suggested squash message:
  squash(feature/x): feat: add search | fix: parser bug

/milestone confirm — 回复确认 squash，或 /milestone cancel 取消
```

**Interaction Point 2 — Merge confirmation**:
```
=== Merge Ready ===
Branch: feature/x (N commits ahead of main)
Diff: +XXX -XXX

/milestone confirm 后，执行 merge + tag + push + cleanup
```

## Quality Gates

All hook scripts MUST follow:

```bash
set -euo pipefail
source "$(dirname "$0")/logging.sh" 2>/dev/null || true
source "$(dirname "$0")/state-lib.sh"
acquire_lock "<hook-name>.sh"
```

**P0-3 compliance**:
- semantic-trigger.sh: ZERO stdout output, only state.json updates
- Other hooks: JSON output ONLY through `hookSpecificOutput` with `permissionDecision` or `continueSuggestion`

## Installation

```bash
cd hooks-omni
./install.sh
```

install.sh copies `hooks-omni/` to `$HOME/.claude/plugins/branch-autonomous/` and registers hooks via `manifest.json`.

## File Structure

```
$HOME/.claude/plugins/branch-autonomous/
├── manifest.json       # Hook registration
├── state.json          # v4.0 runtime state
├── config.json         # User thresholds
├── .lock              # Process lock
└── hooks/
    ├── logging.sh      # Shared logger
    ├── state-lib.sh    # Shared state helpers
    ├── session-start.sh
    ├── semantic-trigger.sh
    ├── guard-bash.sh
    ├── pre-push.sh
    ├── post-tool.sh
    ├── post-tool-fail.sh
    └── stop.sh
```

## Version History

| Version | Changes |
|---------|---------|
| v1.0 | Initial 6-hook design |
| v2.0 | +semantic-trigger.sh, state v4.0, $HOME/.claude/plugins/ path |
