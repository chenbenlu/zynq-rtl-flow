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

.PHONY: all lint sim wave coverage format format-check regress clean help

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
		--cov-report=html:$(COV_DIR)/python
	@dat="$$(find $(SIM_DIR) -name 'coverage.dat' 2>/dev/null | head -1)"; \
	if [[ -n "$$dat" ]]; then \
		echo ">> RTL coverage from $$dat"; \
		verilator_coverage --write-info $(COV_DIR)/rtl.info "$$dat"; \
		verilator_coverage --annotate $(COV_DIR)/rtl_annotated "$$dat"; \
		echo ">> RTL coverage written to $(COV_DIR)/"; \
	else \
		echo ">> No coverage.dat found (built with --coverage?). Skipping RTL coverage."; \
	fi

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

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'
