#!/usr/bin/env bash
# Static checks for the RTL: Verilator strict lint + Verible style lint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Order matters: the package must precede the module that imports it.
RTL_SOURCES=(rtl/sparse_cnn_pkg.sv rtl/sparse_mac_pe.sv)

echo ">> Verilator lint (--lint-only -Wall)"
verilator --lint-only -Wall --top-module sparse_mac_pe "${RTL_SOURCES[@]}"

echo ">> Verible lint"
verible-verilog-lint --rules_config .verible.lint.rules "${RTL_SOURCES[@]}"

echo "Lint OK."
