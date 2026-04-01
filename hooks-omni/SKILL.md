---
name: hooks-omni
description: Branch-autonomous Git workflow hooks for Claude Code. Automates checkpoint commits (on 5+ files or 1000+ lines), milestone squash, and merge-to-main with only two user confirmations. Use when working on feature branches and wanting autonomous git workflow — say "搞定"、"差不多"、"done", push a conventional commit (feat:), or accumulate 10+ commits to trigger milestone. Also: says "done" or "差不多" (Tier2) for semantic trigger. Not for users who prefer manual git control.
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

---

## 故障自救指南 (Fault Self-Rescue Guide)

### State Corruption Recovery

**Symptom**: `state.json` is invalid or corrupted

**Recovery steps**:
1. Delete the corrupted state file:
   ```bash
   rm $HOME/.claude/plugins/branch-autonomous/state.json
   ```
2. Restart Claude Code — session-start.sh will reinitialize with safe defaults

**Prevention**: State updates use atomic flock locking to prevent corruption

---

### Lock Timeout Resolution

**Symptom**: Hook hangs with message "waiting for lock..." or `.lock` file exists from crashed process

**Recovery steps**:
1. Check for stale lock files:
   ```bash
   ls -la $HOME/.claude/plugins/branch-autonomous/.lock
   ```
2. If the lock is stale (process no longer running), remove it:
   ```bash
   rm $HOME/.claude/plugins/branch-autonomous/.lock
   ```

**Prevention**: Locks have built-in TTL detection, but force-killing Claude Code may leave stale locks

---

### Hook Failures

**Symptom**: Hook blocked a command incorrectly, or hook crashed

**Debug steps**:
1. Enable debug mode (see below)
2. Check hook log: `$HOME/.claude/plugins/branch-autonomous/hooks.log`
3. Run the blocked command manually to verify
4. If hook is broken, reinstall:
   ```bash
   cd auto-git && bash install.sh
   ```

---

## Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `deny: dangerous command on main` | guard-bash.sh blocked a risky command | Use feature branch instead of main |
| `jq: invalid JSON` | hooks.json generation failed | Re-run install.sh, check manifest.json syntax |
| `set -euo pipefail` error in hook | Hook has syntax error | Run `bash -n <hook>.sh` to diagnose |
| `acquire_lock: timeout` | Another hook is holding the lock | Wait or remove stale .lock file |
| `git push --force denied` | guard-bash.sh requires `--force-with-lease` | Use `git push --force-with-lease` instead |
| `semantic-trigger: no output` | This is CORRECT behavior | semantic-trigger.sh is designed to be silent |

---

## Debug Mode

**Enable verbose logging**:
```bash
# Set debug environment variable before starting Claude Code
export HOOKS_OMNI_DEBUG=1

# Or add to your shell profile (~/.zshrc or ~/.bashrc)
echo 'export HOOKS_OMNI_DEBUG=1' >> ~/.zshrc
```

**What debug mode shows**:
- Detailed hook execution traces in `hooks.log`
- State update operations with before/after values
- Lock acquisition/release events
- Semantic trigger detection with matched keywords

**Log location**: `$HOME/.claude/plugins/branch-autonomous/hooks.log`

**Log rotation**: Automatic at ~1MB threshold

---

## FAQ

**Q: Hooks are not firing at all**
A: Verify hooks are registered:
```bash
cat ~/.claude/hooks/branch-autonomous/hooks.json | jq '.hooks | length'
```
Should show 7 hooks. If not, reinstall:
```bash
cd auto-git && bash install.sh
```

**Q: Semantic trigger ("搞定") not working**
A: semantic-trigger.sh is completely silent — it only updates state.json. Check state.json:
```bash
cat $HOME/.claude/plugins/branch-autonomous/state.json | jq '.semantic_intent'
```
Should be `true` after saying "搞定".

**Q: Auto-commit not triggering**
A: Check thresholds in config.json:
- `uncommitted_files_threshold`: default 5
- `uncommitted_lines_threshold`: default 1000

**Q: "waiting for lock" forever**
A: Remove stale lock file:
```bash
rm -f $HOME/.claude/plugins/branch-autonomous/.lock
```

**Q: How to disable hooks temporarily**
A: Uninstall the plugin:
```bash
rm -rf ~/.claude/plugins/branch-autonomous
rm -f ~/.claude/hooks/branch-autonomous/hooks.json
```
Restart Claude Code to take effect.

---

## Verification Commands

```bash
# Count test cases in evals
jq '.evals | length' hooks-omni/evals/evals.json

# Run stress test
cd hooks-omni/evals && bash stress-test.sh --sessions 100

# Verify install
bash install.sh 2>&1 | grep -E '(OK|FAILED|complete)'

# Check SKILL.md sections
grep -c '故障\|Troubleshoot\|FAQ\|Debug' hooks-omni/SKILL.md
```
