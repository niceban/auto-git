# Branch-Only Autonomous Git Workflow

**Date**: 2026-03-26
**Status**: Implemented as `hooks-omni/` (v2.0 with semantic-trigger)
**Supersedes**: worktree-first-plugin (archived at `../archive/worktree-first-plugin-20260326/`)

---

## 1. Core Principle

**No worktrees. Only branches.**

All development happens in a single working tree. Feature work lives on `feature/*` branches. main stays clean. Automation handles everything in between.

---

## 2. The Problem Being Solved

1. **Scattered commits**: Developers make many small commits without cleaning up before push
2. **Dirty main history**: Force pushes and messy histories land on main
3. **Manual intervention at every step**: Checkpoint, squash, rebase, merge, tag — all require separate manual commands
4. **No autonomous save**: Unsaved work is lost if session crashes

---

## 3. Design: Two Confirmation Points, Everything Else Automatic

The entire workflow has **exactly two moments** that require user input. Everything else is autonomous.

### Interaction Point 1 — Squash Message Confirmation

**When**: Milestone is detected:
- A conventional commit appears (`feat:`, `fix:`, `perf:`, `ci:`), OR
- 10+ commits have accumulated since the last tag

**What the user sees**:
```
=== Milestone Reached ===
Reason: conventional commit: feat: add search indexing
Tests: PASSED
Commits to squash: 5

Suggested squash message:
  squash(feature/search): feat: add search indexing | feat: parser refactor | ...

Accept this squash message? [Y/n]
```

**User action**: Press Enter to accept, or type a modified message.

**What happens on confirm**:
1. State updated: `milestone = false`, `awaiting_squash_push = true`
2. pre-push.sh intercepts next `git push`:
   - `git reset --soft origin/main` — all changes staged
   - `git commit -m "squash(feature/search): feat: add search indexing | ..."`
   - `git push --force-with-lease origin feature/search`
3. On squash-push success: `awaiting_squash_push = false`, `awaiting_merge_confirmation = true`

---

### Interaction Point 2 — Merge + Release Confirmation

**When**: Squash push succeeds, `awaiting_merge_confirmation = true`

**What the user sees**:
```
=== Merge Ready ===
Branch: feature/search (1 commit ahead of main)
Diff: +247 -89 (reasonable scope)

Current version: v1.2.0
Suggested tag:  v1.3.0

Merge to main and tag as v1.3.0? [Y/n]
```

**User action**: Press Enter or type a custom version number.

**What happens on confirm**:
1. `git checkout main && git merge --no-ff feature/search`
2. `git tag -a v1.3.0 -m "release: v1.3.0 $(date +%Y-%m-%d)"`
3. `git push origin main && git push --tags`
4. `git branch -d feature/search`
5. State updated: `awaiting_merge_confirmation = false`

---

## 4. Full Autonomous Flow

```
SessionStart
    │
    ▼
session-start.sh
    - Read/update state.json
    - Detect branch, branch_type
    │
    ▼
User writes code
    │
    ▼
【Auto】post-tool.sh — Test Detection + Auto-Commit
    - Parse Bash output for test PASS patterns
    - On PASS: test_passed = true, test_passed_at = now
    - On FAIL: test_passed = false, test_failed_at = now
    - Threshold check: if uncommitted_files >= 5 OR uncommitted_lines >= 100:
        → git add -A && git commit -m "checkpoint: auto-save YYYYMMDD-HHMMSS"
    │
    ▼
【Auto】stop.sh — Milestone Detection
    - commits_since_tag >= 10 → milestone = true
    - OR last commit matches ^feat:|^fix: → milestone = true
    - If test_passed = true && milestone = true:
        → Display Interaction Point 1 (WAITING for user)
    │
    ▼
【User Confirms】Interaction Point 1 — Squash
    - On confirm: awaiting_squash_push = true
    │
    ▼
【Auto】pre-push.sh — Squash + Force-Push
    - Detects awaiting_squash_push = true
    - Executes: git reset --soft origin/main → git commit -m "squash(...): ..." → git push --force-with-lease
    - On success: awaiting_squash_push = false, awaiting_merge_confirmation = true
    │
    ▼
【User Confirms】Interaction Point 2 — Merge + Tag
    │
    ▼
【Auto】stop.sh — Merge + Tag + Push + Cleanup
    - git checkout main && git merge --no-ff
    - git tag
    - git push origin main && git push --tags
    - git branch -d feature/branch
    - Update state: awaiting_merge_confirmation = false
```

---

## 5. State Management

### state.json — lives at `$HOME/.claude/plugins/branch-autonomous/state.json`

> **v2.0 变更**：State version 从 3.0 升级到 4.0，新增 `semantic_intent`、`milestone_pending_*`、`backup_branch` 等字段。

```json
{
  "version": "4.0",
  "session_id": "12345",
  "branch": "feature/search",
  "branch_type": "feature",
  "test_passed": false,
  "test_passed_at": null,
  "test_failed_at": null,
  "uncommitted_files": 0,
  "uncommitted_lines": 0,
  "last_commit_at": null,
  "last_commit_message": null,
  "milestone": false,
  "milestone_reason": null,
  "awaiting_squash_push": false,
  "awaiting_merge_confirmation": false,
  "commits_since_last_tag": 0,
  "created_at": "2026-03-26T00:00:00Z",
  "semantic_intent": false,
  "semantic_intent_reason": null,
  "last_prompt": "",
  "last_intent_at": null,
  "milestone_pending": false,
  "milestone_pending_reason": null,
  "milestone_pending_squash_suggestion": null,
  "milestone_pending_branch": null,
  "milestone_pending_commits": 0,
  "backup_branch": null,
  "backup_created_at": null
}
```

**Field lifecycle for `awaiting_squash_push`**:
- `false` (default) — normal coding
- `true` — set by stop.sh immediately after user confirms Interaction Point 1
- `false` — cleared by pre-push.sh when squash-push succeeds
- On squash-push failure: remains `true` (retry on next push)

### config.json — lives at `$HOME/.claude/plugins/branch-autonomous/config.json`

> **v2.0 变更**：`uncommitted_lines_threshold` 默认值从 100 调整为 1000。

```json
{
  "uncommitted_files_threshold": 5,
  "uncommitted_lines_threshold": 1000,
  "milestone_commits_threshold": 10,
  "auto_commit_message_prefix": "checkpoint: auto-save",
  "merge_delete_branch": true,
  "release_tag_prefix": "v"
}
```

---

## 6. Hook Architecture

> **v2.0 变更**：Hook 从 6 个增加到 7 个，新增 `semantic-trigger.sh` 用于监听用户语义意图。

All hooks live at `$HOME/.claude/plugins/branch-autonomous/hooks/`, registered in `manifest.json`.

| Hook | Event | Matcher | Async | Purpose |
|------|-------|---------|-------|---------|
| session-start | SessionStart | — | false | Initialize state.json |
| semantic-trigger | UserPromptSubmit | — | false | Detect user semantic intent (e.g., "搞定了", "done") — completely silent |
| guard-bash | PreToolUse | Bash | false | Block dangerous commands on main |
| pre-push | PreToolUse | Bash | false | Intercept push, execute squash |
| post-tool | PostToolUse | Bash\|Write | true | Detect test PASS/FAIL + auto-commit threshold |
| post-tool-fail | PostToolUseFailure | * | true | Detect test failure |
| stop | Stop | — | false | Milestone detection + merge/tag confirmation |

### semantic-trigger.sh — User Semantic Intent Detection (v2.0 New)

**完全静默设计** — P0-3 修复：不向 stdout 输出任何内容，仅更新 state.json。

**触发词 Tier 1（立即触发）**：
- `v1`, `v2`, `v3`, `release`, `搞定`, `搞定了`, `完成了`, `测试通过`, `✓`, `封板`, `milestone`, `done`, `finished`, `complete`

**触发词 Tier 2（强信号）**：
- `差不多`, `快好了`, `感觉可以了`, `nearly done`, `almost done`, `almost there`, `good enough`

**效果**：设置 `semantic_intent=true` + `milestone_pending=true`，让用户在自然表达时触发 milestone 确认。

### guard-bash.sh — Dangerous Commands on main

Blocks on main branch:
1. File writes with redirection (`>>`, `>`, `tee`, `sed -i`, etc.)
2. `git push` to main
3. `git push --force` (without `--force-with-lease`)
4. `git reset --hard` (bare form)
5. `git clean -x` or `-X`
6. `git branch -d main` or `-D main`
7. `git merge` anything into main (i.e. merge onto main)
8. `git rebase` anything onto main

**Note**: This is a complete rewrite from the archived worktree-based guard-bash.sh.
The archived version used `git worktree list` + PWD logic to detect "inside worktree vs main".
This version uses pure branch detection (`git symbolic-ref --short HEAD`) — the two approaches
are architecturally incompatible; do not try to adapt the archived version.

---

## 7. Milestone Detection Logic

Located in `stop.sh`:

> **v2.0 变更**：新增 Trigger 3 — semantic intent（来自 semantic-trigger.sh）

```bash
# Trigger 1: commit count threshold (guard against no tags)
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [[ -n "$last_tag" ]]; then
  commits_since_tag=$(git rev-list --count HEAD ^"$last_tag")
else
  commits_since_tag=0  # no tags yet; start counting from zero
fi
[[ $commits_since_tag -ge $MILESTONE_COMMITS_THRESHOLD ]]

# Trigger 2: conventional commit prefix
last_commit_msg=$(git log -1 --format="%s")
echo "$last_commit_msg" | grep -qE "^(feat|fix|perf|ci):"

# Trigger 3: semantic intent (from semantic-trigger.sh)
# semantic_intent == true → milestone_pending already set
```

---

## 8. What Is NOT Part of This Design

The following were part of the archived worktree-first approach and are excluded:

- **Worktree creation/management**: No `git worktree add/remove`
- **Interactive worktree selector**: No session-start worktree picker
- **Per-worktree metadata**: No `.worktree-first/worktrees/*.json`
- **Multiple concurrent tasks via worktrees**: Single branch at a time
- **prepare-push.sh as manual workflow**: Replaced by autonomous pre-push.sh
- **checkpoint.sh as separate skill**: Auto-commit happens in stop.sh
- **AI checkpoint advisor at checkpoint time**: Not needed; auto-save is uninterpreted
- **PR creation flow**: No PR; direct merge to main

---

## 9. Implementation Checklist

> **v2.0 Architecture**: Entirely hook-driven. No external agent invocation during the workflow.
> All 7 hooks are registered in `manifest.json`; no CLI tools, no MCP servers needed.

**Batch 1 — State infrastructure** (all other hooks depend on this):
- [x] `$HOME/.claude/plugins/branch-autonomous/` directory + state.json (v4.0) + config.json
- [x] `$HOME/.claude/plugins/branch-autonomous/hooks/session-start.sh`

**Batch 2 — Safety + detection** (parallel, no interdependencies):
- [x] `$HOME/.claude/plugins/branch-autonomous/hooks/guard-bash.sh`
- [x] `$HOME/.claude/plugins/branch-autonomous/hooks/post-tool.sh`
- [x] `$HOME/.claude/plugins/branch-autonomous/hooks/post-tool-fail.sh`

**Batch 3 — Semantic intent** (v2.0 new):
- [x] `$HOME/.claude/plugins/branch-autonomous/hooks/semantic-trigger.sh`

**Batch 4 — Core state machine** (depends on state.json existing):
- [x] `$HOME/.claude/plugins/branch-autonomous/hooks/stop.sh`
- [x] `$HOME/.claude/plugins/branch-autonomous/hooks/pre-push.sh` (with `.tool_input.command` fix)

**Registration**:
- [x] `manifest.json` — register all 7 hooks in `hooks-omni/`

---

## 10. File Locations

> **v2.0**：目录迁移到 `$HOME/.claude/plugins/branch-autonomous/`（原 `~/.branch-autonomous/` 已废弃）

```
$HOME/.claude/plugins/branch-autonomous/
├── state.json              # v4.0
├── config.json
├── .lock                   # 进程锁
└── hooks/
    ├── logging.sh          # 共享日志库
    ├── state-lib.sh        # 共享状态管理
    ├── session-start.sh    # SessionStart
    ├── semantic-trigger.sh # UserPromptSubmit (v2.0 新增)
    ├── guard-bash.sh       # PreToolUse (Bash)
    ├── pre-push.sh         # PreToolUse (Bash)
    ├── post-tool.sh        # PostToolUse (Bash|Write)
    ├── post-tool-fail.sh   # PostToolUseFailure (*)
    └── stop.sh             # Stop
```

**install.sh** 安装时将 `hooks-omni/` 复制到 `$HOME/.claude/plugins/branch-autonomous/`。

---

## 11. Bug Fixes From Previous Implementation

| Bug | Location | Fix |
|-----|----------|-----|
| pre-push.sh JSON path `.command` instead of `.tool_input.command` | pre-push.sh L33 (archived version L19) | Use `.tool_input.command` |
| `git push origin HEAD:master` bypasses all hooks | guard-bash.sh | Add rule to block refspec push to main/master |

---

## 12. v2.0 Changelog

> Design updated to reflect actual implementation in `hooks-omni/`.

| Change | Description | Date |
|--------|-------------|------|
| **semantic-trigger.sh** | New 7th hook for user semantic intent detection | 2026-03-30 |
| **State v4.0** | New fields: `semantic_intent`, `milestone_pending_*`, `backup_branch` | 2026-03-30 |
| **Directory migration** | `~/.branch-autonomous/` → `$HOME/.claude/plugins/branch-autonomous/` | 2026-03-28 |
| **PostToolUse Matcher** | Changed from `Bash` to `Bash\|Write` to cover Write tool | 2026-03-28 |
| **uncommitted_lines_threshold** | Default changed from 100 to 1000 | 2026-03-30 |
| **Shared libraries** | `logging.sh` and `state-lib.sh` extracted as common dependencies | 2026-03-30 |
| **Backup branch** | `pre-push.sh` creates backup branch before squash | 2026-03-30 |
| **manifest.json** | Hook registration via manifest.json instead of hooks.json | 2026-03-30 |
