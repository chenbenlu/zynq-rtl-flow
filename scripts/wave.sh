#!/usr/bin/env bash
# Open the most recent simulation waveform in GTKWave.
# Handles either FST or VCD (cocotb's Verilator backend decides the format).
# GTKWave is a GUI; inside a container you need X11 forwarding (see README).
# For headless / day-to-day use, open the FST/VCD with the WaveTrace or
# TerosHDL VS Code extension instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WAVE="$(find sim -type f \( -name '*.fst' -o -name '*.vcd' \) -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -1 | cut -d' ' -f2-)"

if [[ -z "${WAVE:-}" ]]; then
  echo "No waveform found under sim/. Run 'make sim' first."
  exit 1
fi

echo ">> Opening ${WAVE}"
exec gtkwave "${WAVE}"
