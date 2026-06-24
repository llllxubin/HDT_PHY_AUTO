# =============================================================
# Makefile — HDT TX PHY 模块回归 (W4 动态验证)
#
# 铁律: 完成 = `make test` 退出码 0, 不可自行宣布完成。
# 工具链:
#   - VCS    O-2018.09-SP2  (/opt/synopsys/vcs, license 27000@localhost)
#   - Verible v0.0-4080      (~/.local/bin, lint 纳入闸门: 有 warning 即失败)
#   - python3 3.8            (gen_stim / compare / check_cov / mutate)
#
# 两道回归:
#   make test   = 快门: lint -> stim -> compile -> sim -> compare -> coverage
#   make verify = 全门: test + mutation (变异杀伤率 >=90%, 较慢: 多次编译仿真)
#
# 判定基准独立且禁改: ref/<mod>/ref_model.py, scripts/compare.py, spec。
# 多模块复用: 改 MODULE 即可 (默认 fec_encoder)。其余模块待其 W1 frozen 后启用。
#
# 可覆盖变量 (供 mutation 等隔离构建用, 不污染默认 sim/<MODULE>/):
#   RTL=<路径>    被编译的 RTL (默认 rtl/$(MODULE).sv)
#   BUILD=<目录>  构建产物目录 (simv/csrc/cov.vdb/log, 默认 sim/$(MODULE))
# 数据产物 (stim/dump/cov_summary/...) 按模块隔离于 sim/$(MODULE)/, 多模块不互相覆盖。
# 注意: TB 内硬编码上述数据路径于 sim/$(MODULE)/, 与 SIM_DIR 一致, 不随 BUILD 变。
# =============================================================

MODULE  ?= fec_encoder

RTL      ?= rtl/$(MODULE).sv
TB       := tb/tb_$(MODULE).sv
SVA      := $(wildcard tb/$(MODULE)_sva.sv)   # 接口断言 checker (可选, 经 bind 绑定)
SIM_DIR  := sim/$(MODULE)
BUILD    ?= $(SIM_DIR)
# 以下数据路径 TB 内硬编码于 sim/$(MODULE)/, 与 SIM_DIR 一致, 不随 BUILD 变 (注释独立成行, 避免尾随空格混入变量值)
STIM     := $(SIM_DIR)/stim_bits.txt
DUMP     := $(SIM_DIR)/rtl_dump.txt
COV_SUM  := $(SIM_DIR)/cov_summary.txt
SELFCHK  := $(SIM_DIR)/selfcheck.txt
SVA_STAT := $(SIM_DIR)/sva_status.txt
REF      := ref/$(MODULE)/ref_model.py
SIMV     := $(BUILD)/simv

# VCS 编译: -assert svaext 启用 SVA; -cm 采集代码覆盖率; 功能覆盖率由 TB covergroup 收集
VCS        := vcs
VCS_FLAGS  := -full64 -sverilog -timescale=1ns/1ps -assert svaext \
              -cm line+cond+fsm+tgl+branch -cm_dir $(CURDIR)/$(BUILD)/cov.vdb \
              -Mdir=$(BUILD)/csrc -o $(SIMV) -l $(BUILD)/compile.log +notimingcheck
SIM_FLAGS  := -cm line+cond+fsm+tgl+branch -cm_dir $(CURDIR)/$(BUILD)/cov.vdb \
              -l $(BUILD)/sim.log

.PHONY: help test verify lint stim compile sim compare coverage sva selfcheck mutation clean

.DEFAULT_GOAL := help

# ---- 帮助: 列出可调用 target (裸 make 默认到此) ----
help:
	@echo "HDT TX PHY 回归 (MODULE=$(MODULE))"
	@echo ""
	@echo "聚合目标:"
	@echo "  make test     快门: lint->stim->compile->sim->compare->coverage (日常迭代)"
	@echo "  make verify   全门: test + mutation (含变异杀伤率, 较慢; 收尾/里程碑跑)"
	@echo ""
	@echo "单步目标:"
	@echo "  make lint     verible 静态检查 (有 warning 即失败)"
	@echo "  make stim     生成激励 -> $(STIM)"
	@echo "  make compile  VCS 编译 RTL+TB -> $(SIMV)"
	@echo "  make sim      运行仿真, 产出 dump 与覆盖率汇总"
	@echo "  make compare  vs Python golden 逐bit比对 (0容差)"
	@echo "  make coverage 功能覆盖率闸门 (cp_state/x_state_bit 100%)"
	@echo "  make sva      接口断言闸门 (spec §4.4 四条 SVA)"
	@echo "  make selfcheck seq_start 清零不变量闸门"
	@echo "  make mutation 变异杀伤率闸门 (kill rate >=90%)"
	@echo "  make clean    清理仿真产物 (不动 rtl/tb/ref/scripts/spec)"
	@echo ""
	@echo "常用变量: MODULE=<模块名>  RTL=<路径>  BUILD=<构建目录>"

# ---- 快门: 日常迭代 (lint + 0容差比对 + 功能覆盖率 + 接口SVA + 定向自检) ----
test: lint stim compile sim compare coverage sva selfcheck
	@echo "[make test] ===== 全部步骤通过 (exit 0) ====="

# ---- 全门: 快门 + mutation 杀伤率闸门 ----
verify: test mutation
	@echo "[make verify] ===== 含 mutation 全部通过 (exit 0) ====="

# ---- 静态 lint (闸门: verible 有 warning 即非0; 工具缺失也视为失败) ----
lint:
	@command -v verible-verilog-lint >/dev/null 2>&1 || \
	  { echo "[lint][FATAL] 未找到 verible-verilog-lint, lint 闸门无法执行"; exit 1; }
	@echo "[lint] verible-verilog-lint $(RTL)"
	verible-verilog-lint $(RTL)
	@echo "[lint] 0 warning"

# ---- 激励生成 (Python, 与 TB 硬编码路径对齐) ----
stim:
	@mkdir -p $(SIM_DIR)
	python3 scripts/gen_stim.py --module $(MODULE) --out $(STIM)

# ---- VCS 编译 RTL + TB -> simv ----
compile: $(RTL) $(TB)
	@mkdir -p $(BUILD)
	$(VCS) $(VCS_FLAGS) $(RTL) $(TB) $(SVA)

# ---- 仿真: 从工程根运行, TB 用相对路径读 stim / 写 dump+cov_summary ----
sim:
	@test -x $(SIMV) || { echo "[sim][FATAL] 找不到 $(SIMV), 先 make compile"; exit 1; }
	./$(SIMV) $(SIM_FLAGS)

# ---- 离线比对 vs Python golden (0 容差, exit 0=PASS / 6=FAIL) ----
compare:
	python3 scripts/compare.py --module $(MODULE) --dump $(DUMP) --stim $(STIM) --ref $(REF)

# ---- 功能覆盖率闸门 (spec §4.3: cp_state/x_state_bit 100%) ----
coverage:
	python3 scripts/check_cov.py --summary $(COV_SUM) --min 100.0

# ---- 接口 SVA 闸门 (spec §4.4): checker 自计错误数写状态文件, 此处以退出码闸门 ----
sva:
	@if [ -z "$(SVA)" ]; then echo "[sva] 无 SVA 文件, 跳过"; \
	 elif [ ! -f $(SVA_STAT) ]; then echo "[FAIL] sva: 缺 $(SVA_STAT) (sim 没跑?)"; exit 1; \
	 elif ! grep -q '^PASS' $(SVA_STAT); then echo "[FAIL] sva: $$(cat $(SVA_STAT))"; exit 1; \
	 else echo "[PASS] sva: $$(cat $(SVA_STAT))"; fi

# ---- 定向自检闸门: seq_start 清零不变量 (TB 写, 此处以退出码闸门) ----
selfcheck:
	@test -f $(SELFCHK) || { echo "[FAIL] selfcheck: 缺 $(SELFCHK) (sim 没跑?)"; exit 1; }
	@grep -q '^PASS' $(SELFCHK) || { echo "[FAIL] selfcheck: $$(cat $(SELFCHK))"; exit 1; }
	@echo "[PASS] selfcheck: $$(cat $(SELFCHK))"

# ---- 变异杀伤率闸门 (spec §4.5: kill rate >=90%) ----
# mutate.py 复制 RTL 注入变异 -> 用本 Makefile 隔离构建跑 -> 断言 compare 失败=杀死。
# 绝不动 rtl/ 本体与判定基准; 构建落在 sim/mut/, 不碰 sim/simv。
mutation:
	python3 scripts/mutate.py --module $(MODULE) --rtl $(RTL) --min-kill 90.0

# ---- 清理仿真产物 (不动 rtl/tb/ref/scripts/spec) ----
# 按模块隔离后, 整个 sim/$(MODULE)/ 都是产物, 直接整目录删除; 再清根目录 VCS 残留。
clean:
	rm -rf $(SIM_DIR) \
	       csrc *.daidir ucli.key vc_hdrs.h .vcs_lib_lock
