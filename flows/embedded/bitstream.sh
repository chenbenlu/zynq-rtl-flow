#!/usr/bin/env bash
# Write the bitstream (and, for KV260, the firmware overlay that Linux loads at
# runtime) from a routed checkpoint. Runs impl first if there is none.
#
#   make bitstream BOARD=kv260

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

OUT_DIR="${OUT_DIR:-$BUILD_DIR/$BOARD/impl}"
if [[ ! -f "$OUT_DIR/post_route.dcp" ]]; then
  echo ">> no routed checkpoint — running impl first"
  BOARD="$BOARD" OUT_DIR="$OUT_DIR" bash "$ROOT/flows/embedded/impl.sh"
fi

vivado_env Vivado
export OUT_DIR BOARD
cd "$OUT_DIR"
vivado -mode batch -nojournal -log bitstream.log \
       -source "$ROOT/flows/embedded/bitstream.tcl"

# KV260 is programmed by loading a firmware overlay from Linux, not over JTAG
# (see docs/adr/0003-...), so the bitstream alone is not the deliverable.
if [[ "$BOARD" == "kv260" ]]; then
  echo ">> note: KV260 needs the .bit packaged with a device-tree overlay before"
  echo "   xmutil can load it. That packaging step is not implemented yet."
fi
