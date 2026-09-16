#!/usr/bin/env bash
# Export the hardware handoff (XSA) from an implemented design. FSBL, the PMU
# firmware and the device tree are all generated from it, so it is the first
# artefact the PS-side boot flow needs.
#
#   make xsa BOARD=zcu104

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

OUT_DIR="${OUT_DIR:-$BUILD_DIR/$BOARD/impl}"
PRJ="$OUT_DIR/prj/impl_prj.xpr"

# The XSA comes from the project, not the checkpoint: it carries the block
# design's metadata — PS configuration, address map, IP parameters — and a
# routed checkpoint has none of that.
if [[ ! -f "$PRJ" ]]; then
  echo "xsa: no implemented project at $PRJ" >&2
  echo "     run: make impl BOARD=$BOARD" >&2
  exit 2
fi

vivado_env Vivado
export OUT_DIR BOARD
cd "$OUT_DIR"
vivado -mode batch -nojournal -log xsa.log \
       -source "$ROOT/flows/embedded/xsa.tcl"
