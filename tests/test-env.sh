#!/usr/bin/env bash
# =============================================================================
# Behavioural tests for vivado_env in flows/common/env.sh: how a flow script
# finds the user's AMD toolchain. Fake install trees stand in for the real one.
#
#   bash tests/test-env.sh
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/new/2026.1/Vivado" "$WORK/old/Vivado/2026.1"
echo 'echo sourced-new' > "$WORK/new/2026.1/Vivado/settings64.sh"
echo 'echo sourced-old' > "$WORK/old/Vivado/2026.1/settings64.sh"

pass=0 fail=0

check() {
  local name="$1" ok="$2"
  if [[ "$ok" == yes ]]; then
    echo "  ok   $name"
    pass=$((pass + 1))
  else
    echo "  FAIL $name"
    fail=$((fail + 1))
  fi
}

# Runs vivado_env in a clean environment plus the given assignments; leaves its
# combined output in $out and its exit status in $rc.
run_env() {
  out="$(env -u XILINX_VIVADO -u XILINX_VITIS -u XILINX_ROOT -u XILINX_VERSION \
           "$@" bash -c "source '$ROOT/flows/common/env.sh'; vivado_env Vivado; echo done" 2>&1)"
  rc=$?
}

echo "-- a shell that already sourced settings64.sh"

run_env XILINX_VIVADO="$WORK/new/2026.1/Vivado" XILINX_ROOT="$WORK/old"
check "the sourced install is used as it is" \
      "$([[ $rc -eq 0 && "$out" == *done* && "$out" != *sourced-* ]] && echo yes || echo no)"
check "no version warning for a matching install" \
      "$([[ "$out" != *warning* ]] && echo yes || echo no)"

run_env XILINX_VIVADO=/opt/Xilinx/Vivado/2025.2
check "a different version is warned about, not refused" \
      "$([[ $rc -eq 0 && "$out" == *warning* ]] && echo yes || echo no)"

echo "-- XILINX_ROOT"

run_env XILINX_ROOT="$WORK/new"
check "the 2026.1 layout is sourced" \
      "$([[ $rc -eq 0 && "$out" == *sourced-new*done* ]] && echo yes || echo no)"

run_env XILINX_ROOT="$WORK/old"
check "the pre-2026.1 layout is sourced" \
      "$([[ $rc -eq 0 && "$out" == *sourced-old*done* ]] && echo yes || echo no)"

run_env XILINX_ROOT="$WORK/nowhere"
check "a prefix without the toolchain is refused" \
      "$([[ $rc -eq 127 && "$out" != *done* && "$out" == *nowhere* ]] && echo yes || echo no)"

echo "-- neither"

run_env
check "nothing is assumed about where the toolchain is" \
      "$([[ $rc -eq 127 && "$out" == *settings64.sh* && "$out" == *XILINX_ROOT* ]] && echo yes || echo no)"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
