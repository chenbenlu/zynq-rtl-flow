#!/usr/bin/env bash
# Out-of-context synthesis of a single RTL module — resource and timing
# baseline. See flows/embedded/ooc_synth.tcl for what it actually measures.
#
#   make synth                              # sparse_cnn_axi on kv260
#   make synth BOARD=zcu104
#   make synth RTL_TOP=sparse_mac_pe CLK_PERIOD=2.0

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"
vivado_env Vivado

OUT_DIR="${OUT_DIR:-$BUILD_DIR/$BOARD/ooc/$RTL_TOP}"
CLK_PERIOD="${CLK_PERIOD:-3.0}"
CLK_PORT="${CLK_PORT:-$(rtl_clk_port "$RTL_TOP")}"
export RTL_TOP BOARD_PART OUT_DIR CLK_PERIOD CLK_PORT

# bash cannot export an array, and Vivado runs from OUT_DIR rather than the repo
# root, so the source list is flattened into a scalar of ABSOLUTE paths. Both
# halves matter: exporting the array name silently passes only its first element,
# and relative paths resolve against the wrong directory.
abs_sources=()
for src in "${RTL_SOURCES[@]}"; do abs_sources+=("$ROOT/$src"); done
export RTL_SOURCE_LIST="${abs_sources[*]}"

echo ">> OOC synth: $RTL_TOP on $BOARD ($BOARD_PART) @ ${CLK_PERIOD}ns"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"
vivado -mode batch -nojournal -log vivado.log \
       -source "$ROOT/flows/embedded/ooc_synth.tcl"

echo
cat "$OUT_DIR/baseline.txt"
