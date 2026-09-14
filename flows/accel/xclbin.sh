#!/usr/bin/env bash
# v++ link: .xo + platform -> .xclbin, the acceleration flow's deliverable.
#
#   make xclbin BOARD=kv260 KERNEL=sparse_conv

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

KERNEL="${KERNEL:-sparse_conv}"
OUT_DIR="${OUT_DIR:-$BUILD_DIR/$BOARD/accel/$KERNEL}"
XO="$OUT_DIR/$KERNEL.xo"
PLATFORM_DIR="$ROOT/flows/accel/platform/$BOARD"

missing=()
[[ -f "$XO" ]] || missing+=("$XO — run 'make hls KERNEL=$KERNEL' first")
[[ -d "$PLATFORM_DIR" && -n "$(ls -A "$PLATFORM_DIR" 2>/dev/null)" ]] || \
  missing+=("$PLATFORM_DIR — the Vitis platform to link against (exported .xsa, packaged with the board's runtime)")

if (( ${#missing[@]} )); then
  echo "xclbin: not ready. Missing:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

vivado_env Vitis
PLATFORM="$(find "$PLATFORM_DIR" -name '*.xpfm' | head -1)"
echo ">> v++ link: $KERNEL against $(basename "$PLATFORM")"
cd "$OUT_DIR"
v++ --link --target hw --platform "$PLATFORM" \
    --config "$ROOT/flows/accel/link.cfg" \
    --output "$OUT_DIR/$KERNEL.xclbin" "$XO"
