#!/usr/bin/env bash
# Place & route the full system design for a board.
#
# Unlike `synth`, this needs a complete design: the accelerator wrapped in an
# AXI interface, connected to the Zynq PS, with pin/timing constraints. That
# wrapper does not exist yet — this script tells you exactly what is missing
# rather than silently producing something unimplementable.
#
#   make impl BOARD=kv260

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

SYSTEM_TCL="$ROOT/flows/embedded/bd/system.tcl"
XDC_DIR="$ROOT/flows/embedded/xdc/$BOARD"

missing=()
[[ -f "$SYSTEM_TCL" ]] || missing+=("$SYSTEM_TCL — the block design (Zynq PS + AXI interconnect + the accelerator IP)")
[[ -d "$XDC_DIR" && -n "$(ls -A "$XDC_DIR" 2>/dev/null)" ]] || missing+=("$XDC_DIR/*.xdc — timing and pin constraints for $BOARD")
grep -q 'axi' "${RTL_SOURCES[@]}" 2>/dev/null || missing+=("an AXI-wrapped top level in rtl/ — sparse_mac_pe is a bare PE with no bus interface")

if (( ${#missing[@]} )); then
  echo "impl: the system design is not ready yet. Missing:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  cat >&2 <<'MSG'

`make synth` is the target that works today: it gives the out-of-context
resource and timing baseline for a single module, which is the measurement this
stage of the project needs. Implementation becomes meaningful once the PE is
wrapped in AXI and attached to the PS.
MSG
  exit 2
fi

vivado_env Vivado
OUT_DIR="${OUT_DIR:-$BUILD_DIR/$BOARD/impl}"
export BOARD BOARD_PART BOARD_FILE OUT_DIR SYSTEM_TCL XDC_DIR
export RTL_SOURCES="${RTL_SOURCES[*]}"

echo ">> impl: $BOARD ($BOARD_PART)"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"
vivado -mode batch -nojournal -log vivado.log \
       -source "$ROOT/flows/embedded/impl.tcl"
