#!/usr/bin/env bash
# SystemVerilog formatting via Verible.
#   scripts/format.sh           # rewrite files in place
#   scripts/format.sh check     # fail if any file is not already formatted (CI)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-inplace}"
mapfile -t RTL_SOURCES < <(find rtl -name '*.sv' -o -name '*.svh' | sort)

if [[ ${#RTL_SOURCES[@]} -eq 0 ]]; then
  echo "No SystemVerilog sources found under rtl/."
  exit 0
fi

if [[ "$MODE" == "check" ]]; then
  echo ">> Verible format check"
  # --verify processes one file at a time; iterate so a single bad file fails.
  rc=0
  for f in "${RTL_SOURCES[@]}"; do
    if ! verible-verilog-format --verify "$f"; then
      echo "  not formatted: $f"
      rc=1
    fi
  done
  [[ $rc -eq 0 ]] && echo "Formatting OK."
  exit $rc
else
  echo ">> Verible format (in place)"
  verible-verilog-format --inplace "${RTL_SOURCES[@]}"
  echo "Formatted ${#RTL_SOURCES[@]} file(s)."
fi
