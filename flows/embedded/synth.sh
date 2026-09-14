#!/usr/bin/env bash
# Out-of-context synthesis of a single RTL module — resource and timing
# baseline. See flows/embedded/ooc_synth.tcl for what it actually measures.
#
#   make synth                              # sparse_mac_pe on kv260
#   make synth BOARD=zcu104
#   make synth RTL_TOP=sparse_mac_pe CLK_PERIOD=2.0

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"
vivado_env Vivado

OUT_DIR="${OUT_DIR:-$BUILD_DIR/$BOARD/ooc/$RTL_TOP}"
CLK_PERIOD="${CLK_PERIOD:-3.0}"
CLK_PORT="${CLK_PORT:-clk}"
export RTL_TOP BOARD_PART OUT_DIR CLK_PERIOD CLK_PORT
export RTL_SOURCES="${RTL_SOURCES[*]}"

echo ">> OOC synth: $RTL_TOP on $BOARD ($BOARD_PART) @ ${CLK_PERIOD}ns"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"
vivado -mode batch -nojournal -log vivado.log \
       -source "$ROOT/flows/embedded/ooc_synth.tcl"

echo
cat "$OUT_DIR/baseline.txt"
