#!/usr/bin/env bash
# =============================================================================
# Bring up, or tear down, the private segment between the build host and the
# KV260.
#
# Runs on the BUILD HOST. The board is cabled directly into one of the host's
# NICs instead of taking a router port; docs/adr/0003-... has the reasoning. This
# script is the only place that configuration is written down, because the lab's
# network-as-code repo does not describe this link.
#
#   sudo NIC=<nic> bash scripts/provision-board-net.sh
#   sudo bash scripts/provision-board-net.sh --down
#
# An interface name does not identify the board link; the address on it does.
# There is therefore no default NIC. Bringing the link up needs NIC= naming the
# interface the board is cabled to; tearing it down finds that interface by the
# address it carries, and refuses to touch anything else. Both directions cost
# the same mistake: this host is administered over its lab link, so flushing the
# wrong NIC takes the host off the network until someone walks to it.
# =============================================================================
set -euo pipefail

NIC="${NIC:-}"
HOST_ADDR="${HOST_ADDR:-192.168.100.1/24}"
BOARD_ADDR="${BOARD_ADDR:-192.168.100.2}"

HOST_IP="${HOST_ADDR%%/*}"

usage() {
  cat <<'MSG'
provision-board-net.sh [--down]

  (no args)  bring the board link up: put HOST_ADDR on NIC, then look for the board
  --down     flush and down the board link — the interface carrying HOST_ADDR

Environment:
  NIC          the interface the board is cabled to. Required to bring the link
               up. For --down it is discovered from HOST_ADDR; set it there only
               to be explicit, and it is still checked before anything is touched.
  HOST_ADDR    this host's address on the link  (default 192.168.100.1/24)
  BOARD_ADDR   the board's address on the link  (default 192.168.100.2)
MSG
}

addrs_on() {
  ip -4 -br addr show "$1" 2>/dev/null | awk '{ for (i = 3; i <= NF; i++) print $i }'
}

foreign_addrs() {
  addrs_on "$1" | awk -v ip="$HOST_IP" '{ split($0, a, "/"); if (a[1] != ip) print }'
}

nics_carrying_host_addr() {
  ip -4 -br addr show | awk -v ip="$HOST_IP" '
    { sub(/@.*/, "", $1)
      for (i = 3; i <= NF; i++) { split($i, a, "/"); if (a[1] == ip) { print $1; next } } }'
}

# HOST_ADDR is the only address that belongs on the board link. Anything else
# means the NIC is carrying a link that is not ours, in either direction: on the
# way up we would stamp on it, on the way down we would flush it away.
assert_not_shared() {
  local nic="$1" refusal="$2" foreign
  foreign="$(foreign_addrs "$nic")"
  if [[ -n "$foreign" ]]; then
    echo "provision-board-net: $nic carries ${foreign//$'\n'/, } — $refusal." >&2
    echo "                     That is not the board link. Set NIC= to the interface" >&2
    echo "                     the board is cabled to ('ip -4 -br addr' lists them)." >&2
    exit 1
  fi
}

case "${1:-}" in
  --down) MODE=down ;;
  -h | --help)
    usage
    exit 0
    ;;
  "") MODE=up ;;
  *)
    echo "provision-board-net: unknown argument '$1'" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ "$MODE" == down ]]; then
  if [[ -z "$NIC" ]]; then
    mapfile -t found < <(nics_carrying_host_addr)
    if [[ "${#found[@]}" -eq 0 ]]; then
      echo ">> no interface carries $HOST_IP — the board link is already down."
      exit 0
    fi
    if [[ "${#found[@]}" -gt 1 ]]; then
      echo "provision-board-net: ${found[*]} all carry $HOST_IP — refusing to guess." >&2
      echo "                     Set NIC= to the one the board is cabled to." >&2
      exit 1
    fi
    NIC="${found[0]}"
  elif ! nics_carrying_host_addr | grep -qxF "$NIC"; then
    echo "provision-board-net: $NIC does not carry $HOST_IP — refusing to tear it down." >&2
    echo "                     Only the board link is this script's to flush." >&2
    exit 1
  fi

  assert_not_shared "$NIC" "refusing to tear it down"

  ip addr flush dev "$NIC"
  ip link set "$NIC" down
  echo ">> $NIC down, addresses flushed"
  exit 0
fi

if [[ -z "$NIC" ]]; then
  echo "provision-board-net: set NIC= to the interface the board is cabled to." >&2
  echo "                     There is no default: the wrong name here reconfigures" >&2
  echo "                     a live link ('ip -4 -br addr' lists them)." >&2
  exit 2
fi

if ! ip link show "$NIC" >/dev/null 2>&1; then
  echo "provision-board-net: no interface '$NIC' on this host" >&2
  exit 2
fi

assert_not_shared "$NIC" "refusing to reconfigure it"

ip link set "$NIC" up
ip addr replace "$HOST_ADDR" dev "$NIC"
echo ">> $NIC up with $HOST_ADDR"

echo ">> expecting the board at $BOARD_ADDR"
if ping -c 2 -W 2 "$BOARD_ADDR" >/dev/null 2>&1; then
  echo ">> board responds."
else
  cat <<MSG
>> board does not respond yet. That is expected until it is cabled and booted.
   The board has no DHCP server on this segment, so it needs a static address —
   set it to $BOARD_ADDR/24 with no default route (this link has no route to
   anywhere else; see docs/adr/0003-...).
MSG
fi
