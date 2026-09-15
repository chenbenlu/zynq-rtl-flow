#!/usr/bin/env bash
# =============================================================================
# Behavioural tests for scripts/provision-board-net.sh.
#
# That script reconfigures network interfaces on the build host, and the host is
# administered over one of them — so the guards that matter most are exactly the
# ones that cannot be exercised by running it for real. Everything it observes
# and everything it changes goes through `ip`, so `ip` is stubbed: reads come
# from a fixture describing a fictional host, writes are appended to a log the
# assertions read back. No root, no real interface, no board.
#
#   bash tests/test-provision-board-net.sh
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$ROOT/scripts/provision-board-net.sh}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export FIXTURE="$WORK/interfaces" ACTIONS="$WORK/actions" PATH="$WORK/bin:$PATH"

cat > "$WORK/bin/ip" <<'STUB'
#!/usr/bin/env bash
args=("$@")
flat="${args[*]}"

emit() {
  local want="$1" line
  while read -r line; do
    [[ -z "$line" ]] && continue
    set -- $line
    if [[ -z "$want" || "$1" == "$want" ]]; then echo "$line"; fi
  done < "$FIXTURE"
}

case "$flat" in
  "-4 -br addr show")   emit "" ;;
  "-4 -br addr show "*) emit "${args[4]}" ;;
  "link show "*)        out="$(emit "${args[2]}")"; [[ -n "$out" ]] && echo "$out" || exit 1 ;;
  *)                    echo "$flat" >> "$ACTIONS" ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/ping"
chmod +x "$WORK/bin/ip" "$WORK/bin/ping"

LAB='eth0 UP 10.1.2.3/24'
BOARD='eth1 UP 192.168.100.1/24'
BOTH="$LAB"$'\n'"$BOARD"

pass=0 fail=0

# expect <name> <fixture> <NIC> <want-rc> <want-changes> <want-substring> [args...]
expect() {
  local name="$1" fixture="$2" nic="$3" want_rc="$4" want_changes="$5" want_text="$6"
  shift 6
  printf '%s\n' "$fixture" > "$FIXTURE"
  : > "$ACTIONS"

  local out rc changes problems=()
  out="$(NIC="$nic" bash "$SCRIPT" "$@" 2>&1)"
  rc=$?
  changes="$(paste -sd';' "$ACTIONS")"

  [[ "$rc" == "$want_rc" ]] || problems+=("exit $rc, wanted $want_rc")
  [[ "$changes" == "$want_changes" ]] || problems+=("changed '$changes', wanted '$want_changes'")
  [[ -z "$want_text" || "$out" == *"$want_text"* ]] || problems+=("output does not mention '$want_text'")

  if [[ "${#problems[@]}" -eq 0 ]]; then
    printf '  ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$name"
    printf '         %s\n' "${problems[@]}"
    printf '         output: %s\n' "${out//$'\n'/$'\n'                 }"
    fail=$((fail + 1))
  fi
}

echo "-- --down only ever touches the link carrying HOST_ADDR"
expect "picks the board link over the lab link" \
  "$BOTH" "" 0 "addr flush dev eth1;link set eth1 down" "eth1 down" --down
expect "no board link: touches nothing, says so" \
  "$LAB" "" 0 "" "already down" --down
expect "NIC= naming the lab link is refused" \
  "$BOTH" eth0 1 "" "does not carry 192.168.100.1" --down
expect "two candidates: refuses to guess" \
  "eth0 UP 192.168.100.1/24"$'\n'"eth1 UP 192.168.100.1/24" "" 1 "" "refusing to guess" --down
expect "a NIC shared with another address is refused" \
  "eth0 UP 10.1.2.3/24 192.168.100.1/24" "" 1 "" "carries 10.1.2.3/24" --down

echo "-- the real board link still tears down"
expect "found by address" "$BOARD" "" 0 "addr flush dev eth1;link set eth1 down" "" --down
expect "named explicitly" "$BOTH" eth1 0 "addr flush dev eth1;link set eth1 down" "" --down

echo "-- bringing the link up"
expect "no NIC=: refuses rather than guessing" "$BOTH" "" 2 "" "set NIC="
expect "NIC= naming the lab link is refused" "$BOTH" eth0 1 "" "carries 10.1.2.3/24"
expect "NIC= naming no interface at all" "$BOTH" eth9 2 "" "no interface 'eth9'"
expect "an unaddressed NIC is configured" \
  "$BOTH"$'\n'"eth2 DOWN" eth2 0 "link set eth2 up;addr replace 192.168.100.1/24 dev eth2" ""
expect "re-running on the board link is idempotent" \
  "$BOTH" eth1 0 "link set eth1 up;addr replace 192.168.100.1/24 dev eth1" ""

echo "-- arguments"
expect "a typo does not fall through to the up path" "$BOTH" "" 2 "" "unknown argument" --dowm
expect "--help" "$BOTH" "" 0 "" "provision-board-net.sh" --help

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
