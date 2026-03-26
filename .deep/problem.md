# Problem: Open Source Installation for Claude Code Hooks Project

## Context
Project: https://github.com/niceban/auto-git
Type: Claude Code hook plugin (shell scripts)

## User Intent
用户要求把这个项目当成开源项目来写。别人 clone 后，应该能够按照清晰的文档一步一步部署。而不是：
- 当前 README 写的是"克隆到 ~/.branch-autonomous"（开发者视角）
- 没有说明前置依赖
- 没有说明 Claude Code 如何加载 hooks
- 没有说明 hooks.json 里的 ~ 路径是否被 Claude Code 支持
- 没有说明如何验证安装成功

## Research Questions
1. Claude Code hooks.json 的正确格式和路径写法（~是否支持？）
2. Claude Code hooks 官方文档在哪里
3. 是否有现成的 Claude Code hook 开源项目可以参考
4. 前置依赖（jq, flock等）如何检测和安装
5. 安装后如何验证

## 精确搜索目标
- "Claude Code hooks.json format" — hooks 配置文件规范
- "Claude Code PreToolUse hook" — hook 如何传递 JSON 给脚本
- "Claude Code hooks ~ path expansion" — ~ 路径是否展开
- "github Claude Code hooks open source" — 参考项目
