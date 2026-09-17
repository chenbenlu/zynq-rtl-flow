#!/usr/bin/env bash
# =============================================================================
# Behavioural tests for flows/embedded/boot.sh.
#
# That script needs the AMD toolchain and half an hour of Vitis to run for real,
# so what it does to the workspace before Vitis starts cannot be checked by
# running it. Everything it acts through is stubbed: a fake toolchain tree that
# vivado_env will accept via XILINX_ROOT, and a `vitis` that records the state of
# the workspace it was handed instead of building anything. No toolchain, no
# container, no board.
#
#   bash tests/test-boot.sh
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$ROOT/flows/embedded/boot.sh}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/xilinx/2026.1/Vitis"

# vivado_env sources this; it only has to exist and be sourceable. It is sourced
# with `set +u` around it precisely because the real one is not -u clean.
echo ':' > "$WORK/xilinx/2026.1/Vitis/settings64.sh"

# Stands in for Vitis. Reports what it found rather than building: whether the
# workspace it was pointed at already held a component is the whole question.
cat > "$WORK/bin/vitis" <<'STUB'
#!/usr/bin/env bash
echo "vitis $*" >> "$ACTIONS"
if [[ -e "$BOOT_WS" ]]; then
  echo "workspace-dirty: $(find "$BOOT_WS" -mindepth 1 | wc -l) entries" >> "$ACTIONS"
else
  echo "workspace-absent" >> "$ACTIONS"
fi
# The real one is what produces these lines; boot.sh greps the log for them.
mkdir -p "$BOOT_WS"
echo "component: $BOOT_DIR/fsbl.elf"
echo "component: $BOOT_DIR/pmufw.elf"
STUB
chmod +x "$WORK/bin/vitis"

export PATH="$WORK/bin:$PATH"
export XILINX_ROOT="$WORK/xilinx" XILINX_VERSION=2026.1
export BOARD=zcu104 BUILD_DIR="$WORK/build"
export ACTIONS="$WORK/actions"

BOOT_DIR="$WORK/build/zcu104/boot"
XSA="$WORK/build/zcu104/impl/zcu104.xsa"

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

run_boot() {
  : > "$ACTIONS"
  (cd "$ROOT" && bash "$SCRIPT" >/dev/null 2>&1)
}

echo "-- a hardware handoff that is not there"

rm -rf "$WORK/build"
run_boot
rc=$?
check "the missing XSA is reported, not passed to Vitis" \
      "$([[ $rc -eq 2 && ! -s "$ACTIONS" ]] && echo yes || echo no)"

echo "-- re-running the target"

mkdir -p "$(dirname "$XSA")"
: > "$XSA"

run_boot
rc=$?
check "the first run succeeds" "$([[ $rc -eq 0 ]] && echo yes || echo no)"
check "Vitis is handed an empty workspace" \
      "$(grep -q '^workspace-absent$' "$ACTIONS" && echo yes || echo no)"

# What actually happened on the build host: the workspace the first run left
# behind made every later run stop at StatusCode.ALREADY_EXISTS.
mkdir -p "$BOOT_DIR/ws/zcu104_boot"
: > "$BOOT_DIR/ws/zcu104_boot/marker"

run_boot
rc=$?
check "a second run is not stopped by the first one's workspace" \
      "$([[ $rc -eq 0 ]] && echo yes || echo no)"
check "the leftover workspace is gone before Vitis starts" \
      "$(grep -q '^workspace-absent$' "$ACTIONS" && echo yes || echo no)"
check "the leftover component does not survive into the new workspace" \
      "$([[ ! -e "$BOOT_DIR/ws/zcu104_boot/marker" ]] && echo yes || echo no)"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
