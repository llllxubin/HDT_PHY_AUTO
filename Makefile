# =============================================================
# Makefile — HDT TX PHY 模块回归 (W4 动态验证)
#
# 铁律: 完成 = `make test` 退出码 0, 不可自行宣布完成。
# 工具链:
#   - VCS    O-2018.09-SP2  (/opt/synopsys/vcs, license 27000@localhost)
#   - Verible v0.0-4080      (~/.local/bin, lint 纳入闸门: 有 warning 即失败)
#   - python3 3.8            (gen_stim / compare, golden 比对 0 容差)
#
# make test 串联 (任一步非 0 即整体失败):
#   lint -> stim -> compile(vcs) -> sim(simv) -> compare(vs Python golden)
#
# 判定基准独立且禁改: ref/<mod>/ref_model.py, scripts/compare.py, spec。
# 多模块复用: 改 MODULE 即可 (默认 fec_encoder)。其余模块待其 W1 frozen 后启用。
# =============================================================

MODULE  ?= fec_encoder

RTL      := rtl/$(MODULE).sv
TB       := tb/tb_$(MODULE).sv
SIM_DIR  := sim
STIM     := $(SIM_DIR)/stim_bits.txt    # 注意: TB 内硬编码此相对路径
DUMP     := $(SIM_DIR)/rtl_dump.txt      # 注意: TB 内硬编码此相对路径
REF      := ref/$(MODULE)/ref_model.py
SIMV     := $(SIM_DIR)/simv

# VCS 编译: -assert svaext 启用 SVA; -cm 采集覆盖率(state/fsm 等), 供后续闸门
VCS        := vcs
VCS_FLAGS  := -full64 -sverilog -timescale=1ns/1ps -assert svaext \
              -cm line+cond+fsm+tgl+branch -cm_dir $(CURDIR)/$(SIM_DIR)/cov.vdb \
              -Mdir=$(SIM_DIR)/csrc -o $(SIMV) -l $(SIM_DIR)/compile.log +notimingcheck
SIM_FLAGS  := -cm line+cond+fsm+tgl+branch -cm_dir $(CURDIR)/$(SIM_DIR)/cov.vdb \
              -l $(SIM_DIR)/sim.log

.PHONY: test lint stim compile sim compare clean

# ---- 总回归 ----
test: lint stim compile sim compare
	@echo "[make test] ===== 全部步骤通过 (exit 0) ====="

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
	@mkdir -p $(SIM_DIR)
	$(VCS) $(VCS_FLAGS) $(RTL) $(TB)

# ---- 仿真: 从工程根运行, TB 用相对路径读 stim / 写 dump ----
sim:
	@test -x $(SIMV) || { echo "[sim][FATAL] 找不到 $(SIMV), 先 make compile"; exit 1; }
	./$(SIMV) $(SIM_FLAGS)

# ---- 离线比对 vs Python golden (0 容差, exit 0=PASS / 6=FAIL) ----
compare:
	python3 scripts/compare.py --module $(MODULE) --dump $(DUMP) --stim $(STIM) --ref $(REF)

# ---- 清理仿真产物 (不动 rtl/tb/ref/scripts/spec) ----
clean:
	rm -rf $(SIM_DIR)/simv $(SIM_DIR)/simv.daidir $(SIM_DIR)/csrc \
	       $(SIM_DIR)/cov.vdb $(SIM_DIR)/*.log $(STIM) $(DUMP) \
	       csrc *.daidir ucli.key vc_hdrs.h .vcs_lib_lock
