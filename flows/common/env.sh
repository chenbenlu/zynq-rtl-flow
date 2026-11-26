#!/usr/bin/env bash
# Shared setup for every flow script: locate the repo, the AMD toolchain and
# the selected board, then put the tools on PATH.
#
# The AMD toolchain is the user's, installed wherever they put it. A shell that
# has already sourced its settings64.sh is used as it is; otherwise XILINX_ROOT
# names the install prefix and vivado_env sources settings64.sh from under it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

source flows/common/boards.sh
source scripts/rtl_sources.sh

XILINX_VERSION="${XILINX_VERSION:-2026.1}"
BOARD="${BOARD:-kv260}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

board_select "$BOARD"

# Vivado's settings64.sh is not -u clean.
#
# settings64.sh exports XILINX_VIVADO / XILINX_VITIS; either being set means the
# caller already chose an install, and sourcing another over it would mix two.
#
# 2026.1 nests as <prefix>/<version>/<Tool>/, where earlier releases used
# <prefix>/<Tool>/<version>/. Both are checked so a machine carrying an older
# install still works.
vivado_env() {
  local install_var="XILINX_${1^^}"
  if [[ -n "${!install_var:-}" ]]; then
    if [[ "${!install_var}" != *"$XILINX_VERSION"* ]]; then
      echo ">> warning: $install_var=${!install_var} does not look like $XILINX_VERSION" >&2
    fi
    _add_flexlm "${!install_var}"
    return 0
  fi
  if [[ -z "${XILINX_ROOT:-}" ]]; then
    cat >&2 <<MSG
$1 is not set up in this shell.

Either source the toolchain's settings64.sh before running make, or set
XILINX_ROOT to its install prefix (the directory holding $XILINX_VERSION/$1/).
MSG
    exit 127
  fi
  local settings="$XILINX_ROOT/$XILINX_VERSION/$1/settings64.sh"
  [[ -f "$settings" ]] || settings="$XILINX_ROOT/$1/$XILINX_VERSION/settings64.sh"
  if [[ ! -f "$settings" ]]; then
    echo "$1 $XILINX_VERSION not found under XILINX_ROOT=$XILINX_ROOT" >&2
    exit 127
  fi
  set +u
  # shellcheck disable=SC1090
  source "$settings"
  set -u
  _add_flexlm "${settings%/settings64.sh}"
}

_add_flexlm() {
  # settings64.sh does not put the bundled FlexLM tools on PATH, so xlicdiag —
  # the thing you reach for when a licence check fails — cannot find lmutil and
  # reports that instead of the licence problem you were diagnosing.
  #
  # Written as an `if` rather than `[[ ... ]] && ...` because that form's result
  # is the function's return value: on an install without this directory
  # the caller would return 1 and `set -e` would end the calling flow script
  # right here, with nothing printed to say why.
  local flexlm="$1/bin/unwrapped/lnx64.o"
  if [[ -d "$flexlm" ]]; then
    PATH="$PATH:$flexlm"
  fi
}
