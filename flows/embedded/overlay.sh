#!/usr/bin/env bash
# Package the bitstream and the generated PL device tree as a firmware overlay —
# what a running Linux loads through the ZynqMP FPGA manager. This is the
# deliverable for a board whose PS is already booted (ADR-0004); it replaces the
# boot image the KV260 will eventually need.
#
#   make overlay BOARD=zcu104

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

IMPL_DIR="${IMPL_DIR:-$BUILD_DIR/$BOARD/impl}"
BOOT_DIR="${BOOT_DIR:-$BUILD_DIR/$BOARD/boot}"
APP="${APP:-$BOARD-sparse-cnn}"
OVERLAY_DIR="${OVERLAY_DIR:-$BUILD_DIR/$BOARD/overlay/$APP}"

BIT="$IMPL_DIR/$BOARD.bit"
PL_DTSI="$BOOT_DIR/sdt/pl.dtsi"

missing=()
[[ -f "$BIT" ]] || missing+=("$BIT — run: make bitstream BOARD=$BOARD")
[[ -f "$PL_DTSI" ]] || missing+=("$PL_DTSI — run: make boot BOARD=$BOARD")
if (( ${#missing[@]} )); then
  echo "overlay: missing inputs:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

vivado_env Vivado
mkdir -p "$OVERLAY_DIR"

# The FPGA manager does not take write_bitstream's -bin_file output. That file is
# the raw configuration data; this one carries the header the driver expects, and
# the two are the same size, so the wrong one fails at load rather than at build.
cat > "$OVERLAY_DIR/$APP.bif" <<BIF
all:
{
  [destination_device = pl] $BIT
}
BIF
if ! bootgen -image "$OVERLAY_DIR/$APP.bif" -arch zynqmp -process_bitstream bin -w \
             > "$OVERLAY_DIR/bootgen.log" 2>&1; then
  tail -n 20 "$OVERLAY_DIR/bootgen.log" >&2
  echo "overlay: bootgen failed — full log in $OVERLAY_DIR/bootgen.log" >&2
  exit 1
fi
mv "$IMPL_DIR/$BOARD.bit.bin" "$OVERLAY_DIR/$APP.bit.bin"

python3 "$ROOT/flows/embedded/overlay.py" \
        "$PL_DTSI" "$OVERLAY_DIR/$APP.dtso" "xilinx/$APP/$APP.bit.bin"

# -@ keeps the __symbols__ node, without which the &amba and &fpga_full
# references have nothing to resolve against when the overlay is applied.
#
# dtc's status is checked rather than piped: a pipeline reports the last command,
# so filtering the warnings through grep would turn a failed compile into a
# successful run that quietly produced no .dtbo.
if ! dtc -@ -I dts -O dtb -o "$OVERLAY_DIR/$APP.dtbo" "$OVERLAY_DIR/$APP.dtso" \
         2> "$OVERLAY_DIR/dtc.log"; then
  cat "$OVERLAY_DIR/dtc.log" >&2
  echo "overlay: the device tree overlay did not compile" >&2
  exit 1
fi
grep -v 'unit_address_vs_reg' "$OVERLAY_DIR/dtc.log" >&2 || true

# dfx-mgr reads this to decide how to load the app. A design with no dynamic
# region is flat, whatever the acceleration flow will eventually need.
cat > "$OVERLAY_DIR/shell.json" <<'JSON'
{
  "shell_type": "XRT_FLAT",
  "num_slots": "1"
}
JSON

echo ">> overlay: $OVERLAY_DIR"
ls -1 "$OVERLAY_DIR"
