#!/usr/bin/env bash
# =============================================================
# SessionStart hook: 会话开始/压缩恢复时, 把 PROGRESS.md 注入上下文
# 用途: 抗会话压缩 —— 不靠 agent 记得读 PROGRESS, 而是自动喂给它。
# 当前状态: 默认未在 settings.json 启用 (跑顺单agent后再开)。
# 输出到 stdout 的内容会被 Claude Code 加入会话上下文。
# =============================================================
set -uo pipefail

if [[ -f PROGRESS.md ]]; then
  echo "=== 自动恢复: PROGRESS.md (上次进度) ==="
  cat PROGRESS.md
  echo "=== 请基于以上进度继续, 勿重复已试方案 ==="
fi
exit 0
