#!/usr/bin/env bash
# Place & route the full system design for a board.
#
# Unlike `synth`, this needs a complete design: the AXI-wrapped accelerator, the
# block design that attaches it to the Zynq PS, and per-board constraints. All
# three exist; the check below keeps the failure legible if one is removed,
# rather than letting Vivado report it as something else entirely.
#
#   make impl BOARD=kv260

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

SYSTEM_TCL="$ROOT/flows/embedded/bd/system.tcl"
XDC_DIR="$ROOT/flows/embedded/xdc/$BOARD"

IMPL_TCL="$ROOT/flows/embedded/impl.tcl"

missing=()
[[ -f "$IMPL_TCL" ]] || missing+=("$IMPL_TCL — the implementation script, whose shape depends on the block design above")
[[ -f "$SYSTEM_TCL" ]] || missing+=("$SYSTEM_TCL — the block design (Zynq PS + AXI interconnect + the accelerator IP)")
[[ -d "$XDC_DIR" && -n "$(ls -A "$XDC_DIR" 2>/dev/null)" ]] || missing+=("$XDC_DIR/*.xdc — timing and pin constraints for $BOARD")
grep -q 'axi' "${RTL_SOURCES[@]}" 2>/dev/null || missing+=("an AXI-wrapped top level in scripts/rtl_sources.sh — implementation needs a design with a bus interface, not a bare PE")

if (( ${#missing[@]} )); then
  echo "impl: the system design is incomplete. Missing:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  cat >&2 <<'MSG'

Each of these is tracked in git; if one is gone the checkout is the problem.
`make synth` still works meanwhile — it measures one module out of context and
needs none of the above.
MSG
  exit 2
fi

vivado_env Vivado
OUT_DIR="${OUT_DIR:-$BUILD_DIR/$BOARD/impl}"
PL_CLK_MHZ="${PL_CLK_MHZ:-$BOARD_PL_CLK_MHZ}"
IMPL_JOBS="${IMPL_JOBS:-$(nproc)}"
export BOARD BOARD_PART BOARD_FILE OUT_DIR SYSTEM_TCL XDC_DIR PL_CLK_MHZ IMPL_JOBS
# The block design instantiates whichever top scripts/rtl_sources.sh names.
export RTL_TOP
abs_sources=()
for src in "${RTL_SOURCES[@]}"; do abs_sources+=("$ROOT/$src"); done
export RTL_SOURCE_LIST="${abs_sources[*]}"

echo ">> impl: $BOARD ($BOARD_PART) @ ${PL_CLK_MHZ} MHz"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"
vivado -mode batch -nojournal -log vivado.log \
       -source "$ROOT/flows/embedded/impl.tcl"
