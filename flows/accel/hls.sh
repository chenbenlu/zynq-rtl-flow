#!/usr/bin/env bash
# Vitis HLS: C++ kernel -> .xo, the acceleration flow's compile step.
#
# This flow exists to produce an HLS-derived comparison point against the
# hand-written RTL of the embedded flow; the two are never mixed (see
# CONTEXT.md). Its artefact is a .xo, consumed by `make xclbin`.
#
#   make hls BOARD=kv260 KERNEL=sparse_conv

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

KERNEL="${KERNEL:-sparse_conv}"
SRC_DIR="$ROOT/flows/accel/hls/$KERNEL"
OUT_DIR="${OUT_DIR:-$BUILD_DIR/$BOARD/accel/$KERNEL}"

if [[ ! -d "$SRC_DIR" ]]; then
  cat >&2 <<MSG
hls: no kernel sources at $SRC_DIR

The acceleration flow needs an HLS C++ kernel — one directory per kernel,
holding the kernel source and its testbench. None have been written yet.
MSG
  exit 2
fi

vivado_env Vitis_HLS
export KERNEL BOARD_PART OUT_DIR SRC_DIR
echo ">> HLS: $KERNEL for $BOARD ($BOARD_PART)"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"
vitis_hls -f "$ROOT/flows/accel/hls.tcl"
