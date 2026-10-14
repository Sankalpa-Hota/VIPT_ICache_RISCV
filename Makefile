# make            -> run every testbench (Verilator)
# make SIM=icarus -> run with Icarus Verilog
# make top | mshr | tag | data | plru | itlb | sram
# make lint       -> Verilator -Wall on the RTL
# make vectors    -> regenerate tests/*.txt (python3 scripts/gen_tests.py)
# Waveforms: build/<tb>.fst
SIM    ?= verilator
SEED   ?= 1
export PATH := /opt/homebrew/bin:$(PATH)
BREW   := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
VFLAGS := --binary --timing --trace-fst -Wno-fatal -Wno-lint -Wno-style -j 0 \
          -CFLAGS -I$(BREW)/include -LDFLAGS -L$(BREW)/lib

PKG := rtl/icache_pkg.sv
RTL := $(PKG) rtl/sram_1rw.sv rtl/icache_tag_array.sv rtl/icache_data_array.sv \
       rtl/plru_tree.sv rtl/itlb.sv rtl/icache_mshr.sv rtl/icache_top.sv

all: sram tag data plru itlb mshr top

sram: ; @$(MAKE) --no-print-directory run TOP=tb_sram_1rw         SRCS="rtl/sram_1rw.sv tb/tb_sram_1rw.sv"
tag:  ; @$(MAKE) --no-print-directory run TOP=tb_icache_tag_array SRCS="$(PKG) rtl/sram_1rw.sv rtl/icache_tag_array.sv tb/tb_icache_tag_array.sv"
data: ; @$(MAKE) --no-print-directory run TOP=tb_icache_data_array SRCS="$(PKG) rtl/sram_1rw.sv rtl/icache_data_array.sv tb/tb_icache_data_array.sv"
plru: ; @$(MAKE) --no-print-directory run TOP=tb_plru_tree        SRCS="$(PKG) rtl/plru_tree.sv tb/tb_plru_tree.sv"
itlb: ; @$(MAKE) --no-print-directory run TOP=tb_itlb             SRCS="$(PKG) rtl/itlb.sv tb/tb_itlb.sv"
mshr: ; @$(MAKE) --no-print-directory run TOP=tb_icache_mshr      SRCS="$(PKG) rtl/icache_mshr.sv tb/tb_icache_mshr.sv"
top:  ; @$(MAKE) --no-print-directory run TOP=tb_icache_top       SRCS="$(RTL) tb/tb_icache_top.sv"

run:
	@mkdir -p build
ifeq ($(SIM),icarus)
	iverilog -g2012 -o build/$(TOP).vvp -s $(TOP) $(SRCS)
	vvp -n build/$(TOP).vvp -fst
else
	verilator $(VFLAGS) --Mdir build/$(TOP) --top-module $(TOP) $(SRCS) -o sim
	./build/$(TOP)/sim +verilator+seed+$(SEED) +verilator+error+limit+20
endif

lint:
	verilator --lint-only -Wall --top-module icache_top $(RTL)

vectors:
	python3 scripts/gen_tests.py $(SEED)

clean:
	rm -rf build

.PHONY: all sram tag data plru itlb mshr top run lint vectors clean
