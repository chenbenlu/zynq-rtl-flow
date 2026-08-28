#!/usr/bin/env bash
# Static checks for the RTL: Verilator strict lint + Verible style lint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source scripts/rtl_sources.sh

echo ">> Verilator lint (--lint-only -Wall)"
verilator --lint-only -Wall --top-module "$RTL_TOP" "${RTL_SOURCES[@]}"

echo ">> Verible lint"
verible-verilog-lint --rules_config .verible.lint.rules "${RTL_SOURCES[@]}"

echo "Lint OK."
