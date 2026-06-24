#!/usr/bin/env bash
# =============================================================
# W1 PostToolUse hook: 检测 agent 有没有自己把 status 改成 frozen
# 这是"status 只有人能改 frozen"铁律的机制保证
# 触发: 每次 Write/Edit 操作后
# =============================================================
set -uo pipefail

TARGET="${CLAUDE_TOOL_FILE_PATH:-}"

check_file() {
  local f="$1"
  [[ "$f" == *.md ]] || return 0
  [[ -f "$f" ]] || return 0
  # 检查文件里有没有 "status: frozen"
  if grep -q "^- status: frozen" "$f" 2>/dev/null || \
     grep -q "^status: frozen" "$f" 2>/dev/null; then
    echo "[W1 hook][WARN] 检测到 $f 包含 'status: frozen'" >&2
    echo "[W1 hook][WARN] 铁律: status frozen 只能由人来改,不是 agent 改的请立刻撤销" >&2
    echo "[W1 hook][WARN] 请把 status 改回 draft 或 reviewed,等人 review 后由人改 frozen" >&2
    # 不阻断(exit 0),但警告输出给 agent 和人看
  fi
}

if [[ -n "$TARGET" ]]; then
  check_file "$TARGET"
else
  # 兜底: 扫描所有 W1/modules/*.md
  for f in W1/modules/*.md; do
    [[ -e "$f" ]] && check_file "$f"
  done
fi

exit 0
