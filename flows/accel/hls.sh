#!/usr/bin/env bash
# Vitis HLS: C++ kernel -> .xo, the acceleration flow's compile step.
#
# 2026.1 has no `vitis_hls` binary — HLS is a mode of v++ (`v++ -c --mode hls`)
# driven by a config file rather than a Tcl script. The per-kernel config lives
# with the kernel, in flows/accel/hls/<kernel>/hls.cfg.
#
# This flow exists to produce an HLS-derived comparison point against the
# hand-written RTL of the embedded flow; the two are never mixed (see
# CONTEXT.md). Its artefact is a .xo, consumed by `make xclbin`.
#
#   make hls BOARD=kv260 KERNEL=sparse_conv

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

KERNEL="${KERNEL:-sparse_conv}"
SRC_DIR="$ROOT/flows/accel/hls/$KERNEL"
CFG="$SRC_DIR/hls.cfg"
OUT_DIR="${OUT_DIR:-$BUILD_DIR/$BOARD/accel/$KERNEL}"

missing=()
[[ -d "$SRC_DIR" ]] || missing+=("$SRC_DIR — the kernel's directory")
[[ -f "$CFG" ]] || missing+=("$CFG — the kernel's v++ HLS config (syn.file, syn.top, tb.file, clock)")

if (( ${#missing[@]} )); then
  echo "hls: no kernel to compile. Missing:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  cat >&2 <<'MSG'

The acceleration flow needs an HLS C++ kernel — one directory per kernel,
holding the kernel source, its testbench and an hls.cfg. None have been
written yet. See flows/accel/hls/README.md for the config's shape.
MSG
  exit 2
fi

vivado_env Vitis

echo ">> HLS: $KERNEL for $BOARD ($BOARD_PART)"
mkdir -p "$OUT_DIR"
cd "$SRC_DIR"

# --part is a general v++ option, not an [hls] one, so it is passed here rather
# than written into the per-kernel config — that keeps the config board-agnostic
# and lets BOARD select the silicon, as it does in every other flow.
v++ --compile --mode hls \
    --config "$CFG" \
    --part "$BOARD_PART" \
    --work_dir "$OUT_DIR"

xo="$(find "$OUT_DIR" -name '*.xo' -newer "$CFG" | head -1)"
if [[ -n "$xo" && "$xo" != "$OUT_DIR/$KERNEL.xo" ]]; then
  cp "$xo" "$OUT_DIR/$KERNEL.xo"
fi
echo ">> $OUT_DIR/$KERNEL.xo"
