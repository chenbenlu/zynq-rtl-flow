# =============================================================================
# Sparse CNN simulation skeleton — unified entry point.
# All targets assume the toolchain (Verilator, Verible, cocotb) is on PATH,
# i.e. you are inside the Dev Container / toolchain image.
# =============================================================================

SHELL       := /bin/bash
PYTEST      ?= pytest
SIM         ?= verilator
SIM_DIR     := sim
COV_DIR     := $(SIM_DIR)/coverage
COV_DAT     := $(shell find $(SIM_DIR) -name 'coverage.dat' 2>/dev/null)

# Synthesis flows. BOARD selects the silicon (see flows/common/boards.sh);
# KERNEL selects an HLS kernel in the acceleration flow. The flows run inside
# the Vivado container — see scripts/vivado-run.sh.
BOARD       ?= kv260
KERNEL      ?= sparse_conv
CLK_PERIOD  ?= 3.0
export BOARD KERNEL CLK_PERIOD

# Sequential equivalence check. GOLDEN is the reference design (a git revision
# or a directory containing rtl/); REVISED defaults to the working tree.
GOLDEN      ?=
REVISED     ?=
SEC_ENGINE  ?= eqy
SEC_DEPTH   ?= 20
export GOLDEN REVISED SEC_ENGINE SEC_DEPTH

.PHONY: all lint sim wave coverage sec format format-check regress clean clean-synth help \
        synth impl bitstream hls xclbin vivado-shell vivado-gui vivado-image

all: regress

## lint: Verilator strict lint + Verible style lint
lint:
	@bash scripts/lint.sh

## sim: build + run the cocotb simulation via pytest
sim:
	SIM=$(SIM) $(PYTEST) tb

## wave: open the most recent waveform in GTKWave
wave:
	@bash scripts/wave.sh

## coverage: Python (pytest-cov) + RTL (verilator_coverage) reports -> sim/coverage
coverage:
	@mkdir -p $(COV_DIR)
	SIM=$(SIM) $(PYTEST) tb \
		--cov=tb --cov-report=term \
		--cov-report=html:$(COV_DIR)/python \
		--cov-report=lcov:$(COV_DIR)/python.info
	@dat="$$(find $(SIM_DIR) -name 'coverage.dat' 2>/dev/null | head -1)"; \
	if [[ -n "$$dat" ]]; then \
		echo ">> RTL coverage from $$dat"; \
		verilator_coverage --write-info $(COV_DIR)/rtl.info "$$dat"; \
		verilator_coverage --annotate $(COV_DIR)/rtl_annotated "$$dat"; \
		echo ">> RTL coverage written to $(COV_DIR)/"; \
	else \
		echo ">> No coverage.dat found (built with --coverage?). Skipping RTL coverage."; \
	fi
	@infos="$$(ls $(COV_DIR)/rtl.info $(COV_DIR)/python.info 2>/dev/null)"; \
	if command -v genhtml >/dev/null 2>&1 && [[ -n "$$infos" ]]; then \
		echo ">> genhtml unified HTML report"; \
		genhtml --quiet --output-directory $(COV_DIR)/html \
			--title "zynq_cnn coverage" --legend $$infos; \
		echo ">> Open $(COV_DIR)/html/index.html"; \
	elif ! command -v genhtml >/dev/null 2>&1; then \
		echo ">> genhtml not found (install lcov) — skipping unified HTML report."; \
	fi

## sec: sequential equivalence check vs GOLDEN=<git-rev|dir> (see scripts/sec.sh)
sec:
	@bash scripts/sec.sh

## --- Synthesis: embedded flow (hand-written RTL -> bitstream) ---

## synth: out-of-context synthesis of one module — resource + timing baseline
synth:
	@bash flows/embedded/synth.sh

## impl: place & route the full system design for BOARD
impl:
	@bash flows/embedded/impl.sh

## bitstream: write the bitstream from the routed checkpoint
bitstream:
	@bash flows/embedded/bitstream.sh

## --- Synthesis: acceleration flow (HLS kernel -> xclbin) ---

## hls: compile the HLS kernel KERNEL into a .xo
hls:
	@bash flows/accel/hls.sh

## xclbin: link KERNEL's .xo against the platform for BOARD
xclbin:
	@bash flows/accel/xclbin.sh

## --- The Vivado container (run these on the build host, outside it) ---

## vivado-image: build the Vivado container image
vivado-image:
	@bash scripts/vivado-run.sh build

## vivado-shell: interactive shell in the Vivado container
vivado-shell:
	@bash scripts/vivado-run.sh

## vivado-gui: launch the Vivado GUI on the build host's display
vivado-gui:
	@bash scripts/vivado-run.sh vivado

## format: rewrite SystemVerilog in place with Verible
format:
	@bash scripts/format.sh

## format-check: fail if any SystemVerilog is unformatted (CI)
format-check:
	@bash scripts/format.sh check

## regress: lint -> sim -> coverage
regress:
	@bash scripts/regress.sh

## clean: remove simulation build + run artifacts
clean:
	rm -rf $(SIM_DIR) obj_dir
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
	find . -name '*.vcd' -o -name '*.fst' | xargs -r rm -f

## clean-synth: remove synthesis + implementation artifacts
clean-synth:
	rm -rf build

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'
