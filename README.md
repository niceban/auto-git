# Branch-Autonomous Git Workflow

Hook-driven branch-only Git workflow for Claude Code. No worktrees — all development on `feature/*` branches.

## 安装

```bash
# 1. 克隆仓库
git clone https://github.com/niceban/auto-git.git ~/.branch-autonomous

# 2. 注册 hooks
cp ~/.branch-autonomous/hooks.json ~/.claude/hooks/hooks.json

# 3. 重启 Claude Code session 使 hooks 生效
```

## 工作流程

```
SessionStart → session-start.sh（初始化 state.json）
    ↓
用户写代码 + 运行测试
    ↓
post-tool.sh — 检测测试 PASS/FAIL
stop.sh — 阈值自动提交（≥5个未提交文件 或 ≥100行变更）
    ↓
【Milestone 触发】→ 用户确认 squash 消息
    ↓
pre-push.sh — squash + force-with-lease push
    ↓
【Merge 确认】→ 用户确认 merge + tag
    ↓
stop.sh — merge + tag + push + 删除分支
```

## 文件结构

```
~/.branch-autonomous/
├── config.json         # 阈值配置
├── state.json          # 运行时状态（自动生成）
└── hooks/
    ├── session-start.sh
    ├── guard-bash.sh    # 阻止 main 分支危险操作
    ├── pre-push.sh      # squash + force-push
    ├── post-tool.sh      # 测试 PASS 检测
    ├── post-tool-fail.sh # 测试 FAIL 检测
    └── stop.sh           # auto-commit + milestone + merge

hooks.json              # Claude Code hooks 注册（复制到 ~/.claude/hooks/）
```

## 阈值配置（config.json）

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `uncommitted_files_threshold` | 5 | 自动提交文件数阈值 |
| `uncommitted_lines_threshold` | 100 | 自动提交行数阈值 |
| `milestone_commits_threshold` | 10 | milestone 触发 commit 数 |
| `auto_commit_message_prefix` | `checkpoint: auto-save` | 自动提交前缀 |
| `merge_delete_branch` | true | merge 后删除分支 |
| `release_tag_prefix` | `v` | tag 前缀 |

## 危险命令防护（guard-bash）

main 分支上阻止：
- 文件重定向写入（`>`, `>>`）
- `git push` 到 main/master
- `git push --force`（不含 `--force-with-lease`）
- `git reset --hard`
- `git clean -x / -X`
- 删除 main/master
- merge/rebase onto main/master
- refspec push `HEAD:refs/heads/main`

## 两条人工交互点

1. **Milestone squash 确认** — `feat:`/`fix:` commit 或 10+ commits 后
2. **Merge + Release tag 确认** — squash push 成功后

## 本地开发

```bash
# 测试 hooks
bash test-hooks.sh          # 70 tests, 0 failures

# 手动触发 session-start
bash hooks/session-start.sh
```
