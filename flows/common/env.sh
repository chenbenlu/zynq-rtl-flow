#!/usr/bin/env bash
# Shared setup for every flow script: locate the repo, the AMD toolchain and
# the selected board, then put the tools on PATH.
#
# The toolchain is NOT in the container image — it is bind-mounted from the
# build host's persistent disk (see docs/adr/0001-...). XILINX_ROOT is both the
# host path and the in-container path: they must match, because settings64.sh
# sources its sub-scripts by absolute path. The run wrapper sets it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

source flows/common/boards.sh
source scripts/rtl_sources.sh

XILINX_ROOT="${XILINX_ROOT:-/home/ubuntu/disk/lab/xilinx}"
XILINX_VERSION="${XILINX_VERSION:-2026.1}"
BOARD="${BOARD:-kv260}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

board_select "$BOARD"

# Vivado's settings64.sh is not -u clean.
#
# 2026.1 nests as <prefix>/<version>/<Tool>/, where earlier releases used
# <prefix>/<Tool>/<version>/. Both are checked so a machine carrying an older
# install still works.
vivado_env() {
  local settings="$XILINX_ROOT/$XILINX_VERSION/$1/settings64.sh"
  [[ -f "$settings" ]] || settings="$XILINX_ROOT/$1/$XILINX_VERSION/settings64.sh"
  if [[ ! -f "$settings" ]]; then
    cat >&2 <<MSG
$1 $XILINX_VERSION not found at $settings

The AMD toolchain lives on the build host's persistent disk and is mounted into
this container — it is deliberately not part of the image. If this is a fresh
build host, run scripts/provision-vivado.sh first. If it is installed
elsewhere, set XILINX_ROOT.
MSG
    exit 127
  fi
  set +u
  # shellcheck disable=SC1090
  source "$settings"
  set -u

  # settings64.sh does not put the bundled FlexLM tools on PATH, so xlicdiag —
  # the thing you reach for when a licence check fails — cannot find lmutil and
  # reports that instead of the licence problem you were diagnosing.
  local flexlm="${settings%/settings64.sh}/bin/unwrapped/lnx64.o"
  [[ -d "$flexlm" ]] && PATH="$PATH:$flexlm"
}
