#!/usr/bin/env bash
# =============================================================
# PostToolUse hook: agent 改完 .sv 后自动 format + lint
# 由 Claude Code 在 Edit/Write 工具作用于 .sv 后触发。
# 行为: 1) verible-verilog-format 原地整理排版 (改外观, 不改逻辑)
#       2) verible-verilog-lint 静态检查 (只读, 输出问题给 agent)
# 注意: 本脚本要快, 不在此跑仿真等耗时操作。
# 退出码: format/lint 的问题不阻断 (lint 结果给 agent 看, 由它自己修);
#         如需"lint不过就阻断", 把最后的 exit 0 改为传递 lint 退出码。
# =============================================================
set -uo pipefail

# Claude Code 通过环境变量/stdin 传入被修改的文件路径。
# 不同版本传参方式可能不同, 这里做兼容: 优先环境变量, 否则扫 rtl/。
TARGET="${CLAUDE_TOOL_FILE_PATH:-}"

run_one() {
  local f="$1"
  [[ "$f" == *.sv || "$f" == *.svh || "$f" == *.v ]] || return 0
  [[ -f "$f" ]] || return 0
  echo "[hook] format: $f"
  verible-verilog-format --inplace "$f" 2>/dev/null \
    || echo "[hook][warn] format 跳过 (语法可能未完整, 正常)"
  echo "[hook] lint: $f"
  verible-verilog-lint "$f" || true   # 问题打印给 agent, 不阻断
}

if [[ -n "$TARGET" ]]; then
  run_one "$TARGET"
else
  # 兜底: 没拿到具体文件路径时, 检查 rtl/ 下所有 sv
  for f in rtl/*.sv; do
    [[ -e "$f" ]] && run_one "$f"
  done
fi

exit 0   # 不阻断 agent; lint 结果已输出供其自我修正
