#!/usr/bin/env bash
# Generate the PS-side boot components — FSBL, PMU firmware and the device tree
# — from the hardware handoff exported by `make xsa`. BOOT.BIN is assembled from
# these together with ATF, U-Boot and the bitstream.
#
#   make boot BOARD=zcu104

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

XSA="${XSA:-$BUILD_DIR/$BOARD/impl/$BOARD.xsa}"
BOOT_DIR="${BOOT_DIR:-$BUILD_DIR/$BOARD/boot}"
BOOT_WS="$BOOT_DIR/ws"

if [[ ! -f "$XSA" ]]; then
  echo "boot: no hardware handoff at $XSA" >&2
  echo "      run: make xsa BOARD=$BOARD" >&2
  exit 2
fi

BOOT_COMPONENT="${BOOT_COMPONENT:-${BOARD}_boot}"

vivado_env Vitis
export XSA BOOT_WS BOOT_DIR BOOT_COMPONENT BOARD
mkdir -p "$BOOT_DIR"

# Output goes to a file rather than the terminal because the Vitis tools start
# their own Xvfb, and a child holding the container's stdout keeps `docker run`
# alive long after the work is finished — a hang that looks like the tool's, not
# the plumbing's. Redirected to a file, the pipe closes and the container exits.
LOG="$BOOT_DIR/boot.log"
echo ">> boot components: $BOARD -> $BOOT_DIR (log: $LOG)"
if ! vitis -s "$ROOT/flows/embedded/boot.py" > "$LOG" 2>&1 < /dev/null; then
  tail -n 30 "$LOG" >&2
  echo "boot: generation failed — full log in $LOG" >&2
  exit 1
fi

grep '^component: ' "$LOG" | sed 's/^component: />> /'
