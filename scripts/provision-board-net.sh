#!/usr/bin/env bash
# =============================================================================
# Bring up the private segment between the build host and the KV260.
#
# Runs on the BUILD HOST. The board is cabled directly into the host's second
# NIC instead of taking a router port; docs/adr/0003-... has the reasoning. This
# script is the only place that configuration is written down, because the lab's
# network-as-code repo does not describe this link.
#
#   sudo bash scripts/provision-board-net.sh
#   sudo bash scripts/provision-board-net.sh --down
# =============================================================================
set -euo pipefail

NIC="${NIC:-eth0}"
HOST_ADDR="${HOST_ADDR:-192.168.100.1/24}"
BOARD_ADDR="${BOARD_ADDR:-192.168.100.2}"

if [[ "${1:-}" == "--down" ]]; then
  ip addr flush dev "$NIC" || true
  ip link set "$NIC" down || true
  echo ">> $NIC down, addresses flushed"
  exit 0
fi

if ! ip link show "$NIC" >/dev/null 2>&1; then
  echo "provision-board-net: no interface '$NIC' on this host" >&2
  exit 2
fi

# A NIC already carrying an address is almost certainly someone else's link —
# refuse rather than stamp on it.
existing="$(ip -4 -br addr show "$NIC" | awk '{print $3}')"
if [[ -n "$existing" && "$existing" != "${HOST_ADDR%%/*}"* ]]; then
  echo "provision-board-net: $NIC already has $existing — refusing to reconfigure." >&2
  echo "                     Set NIC= to the interface the board is cabled to." >&2
  exit 1
fi

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
