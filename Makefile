# Run from the repo root.
#   make sim          every testbench in Icarus Verilog
#   make tb_mod_mul   one testbench
#   make test         Python tests, then every testbench
# DEFS passes defines to the testbenches, e.g. make tb_mod_mul DEFS="-DEXHAUSTIVE -DVCD"

IVERILOG ?= iverilog
VVP      ?= vvp
DEFS     ?=

RTL := $(wildcard rtl/*.v)
TBS := $(basename $(notdir $(wildcard tb/tb_*.v)))

.PHONY: sim test clean $(TBS)

sim: $(TBS)

test:
	uv run pytest -q
	$(MAKE) sim

$(TBS): %: tb/%.v $(RTL) rtl/pqc_params.vh
	@mkdir -p build
	$(IVERILOG) -g2001 -Wall -Wno-timescale -I rtl $(DEFS) -o build/$@.vvp $< $(RTL)
	$(VVP) -n build/$@.vvp | tee build/$@.log
	@grep -q '^PASS' build/$@.log

clean:
	rm -rf build
