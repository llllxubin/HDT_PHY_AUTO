#!/usr/bin/env bash
# =============================================================
# PostToolUse hook: agent 改完 .sv 后自动 format + syntax + lint
# 由 Claude Code 在 Edit/Write 工具作用于 .sv 后触发。
#
# 行为:
#   1) verible-verilog-format  原地整理排版(改外观,不改逻辑)
#   2) verible-verilog-syntax  纯语法检查(漏分号/括号/未声明信号)
#   3) verible-verilog-lint    编码规范检查(命名/位宽/对齐等)
#
# 文件路径读取:
#   Claude Code 通过 stdin 传入 JSON: {"tool_input": {"file_path": "..."}, ...}
#   优先从 stdin JSON 取路径;若取不到则兜底扫 rtl/。
#   (旧的 CLAUDE_TOOL_FILE_PATH 环境变量在子 agent 场景下不可靠,已弃用)
#
# 退出码:
#   format/syntax/lint 的问题均不阻断(结果输出给 agent 自行修正)。
#   如需"syntax 不过就阻断",把 syntax 段的 exit 0 改为 exit $SYNTAX_RC。
# =============================================================
set -uo pipefail

# ---- 1. 从 stdin JSON 取被编辑的文件路径 ----
HOOK_INPUT=$(cat)
FILE_PATH=$(echo "$HOOK_INPUT" | python3 -c \
  "import sys,json
d=json.load(sys.stdin)
# 兼容 Write / Edit 两种工具的字段名
ti=d.get('tool_input',{})
print(ti.get('file_path', ti.get('path','')))" 2>/dev/null)

# 兜底:stdin 取不到时扫 rtl/ 所有 sv(保留原有兜底逻辑)
if [[ -z "$FILE_PATH" ]]; then
  for f in rtl/*.sv; do
    [[ -e "$f" ]] && bash "$0" <<< "{\"tool_input\":{\"file_path\":\"$f\"}}"
  done
  exit 0
fi

# 只处理 SystemVerilog/Verilog 文件
case "$FILE_PATH" in
  *.sv|*.svh|*.v) ;;
  *) exit 0 ;;
esac
[[ -f "$FILE_PATH" ]] || exit 0

echo "=================================================================="
echo "[hook] 触发文件: $FILE_PATH"
echo "=================================================================="

# ---- 2. format: 原地整理排版(改外观,不改逻辑) ----
echo "----- [1/3] format (verible-verilog-format) -----"
verible-verilog-format --inplace "$FILE_PATH" 2>/dev/null \
  && echo "✅ format 完成" \
  || echo "⚠️  format 跳过(语法可能未完整,正常)"

# ---- 3. syntax: 纯语法检查 ----
# 先跑 syntax:语法有误时 lint 输出嘈杂且无意义,先排掉语法错误更干净。
echo "----- [2/3] 语法检查 (verible-verilog-syntax) -----"
SYNTAX_OUT=$(verible-verilog-syntax "$FILE_PATH" 2>&1)
SYNTAX_RC=$?
if [[ $SYNTAX_RC -eq 0 ]]; then
  echo "✅ 语法通过"
else
  echo "❌ 语法错误 (exit=$SYNTAX_RC):"
  echo "$SYNTAX_OUT"
  echo ""
  echo ">>> agent 注意:存在语法错误,请逐条修正后再继续。<<<"
  # 语法有误时跳过 lint(lint 结果在语法错时无意义)
  echo "=================================================================="
  exit 0
fi

# ---- 4. lint: 编码规范检查 ----
echo "----- [3/3] 编码规范 (verible-verilog-lint) -----"
RULES_FLAG=""
[[ -f ".rules.verible_lint" ]] && RULES_FLAG="--rules_config=.rules.verible_lint"
LINT_OUT=$(verible-verilog-lint $RULES_FLAG "$FILE_PATH" 2>&1)
LINT_RC=$?
if [[ $LINT_RC -eq 0 ]]; then
  echo "✅ Lint 通过"
else
  echo "⚠️  Lint 违规 (exit=$LINT_RC):"
  echo "$LINT_OUT"
  echo ""
  echo ">>> agent 注意:以上为编码规范违规,请修正以符合工程 lint 标准。<<<"
fi

echo "=================================================================="
exit 0   # 不阻断;lint 结果已输出供 agent 自我修正
