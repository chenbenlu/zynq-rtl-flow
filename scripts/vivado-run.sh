#!/usr/bin/env bash
# =============================================================================
# Run a command inside the Vivado container on the build host.
#
#   bash scripts/vivado-run.sh build          # build the image
#   bash scripts/vivado-run.sh                # interactive shell
#   bash scripts/vivado-run.sh make synth     # one-shot
#   bash scripts/vivado-run.sh vivado         # the GUI (see below)
#
# The toolchain is bind-mounted from the host rather than living in the image
# (docs/adr/0001-...), and the host's X socket is shared so the GUI draws onto
# the host desktop — which is what RustDesk mirrors (docs/adr/0002-...).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="${IMAGE:-zynq_cnn-vivado:latest}"
XILINX_PREFIX="${XILINX_PREFIX:-/home/ubuntu/disk/lab/xilinx}"
DOCKER="${DOCKER:-docker}"

if [[ "${1:-}" == "build" ]]; then
  exec "$DOCKER" build -f "$ROOT/docker/vivado.Dockerfile" \
       --build-arg USER_UID="$(id -u)" \
       --build-arg USER_GID="$(id -g)" \
       -t "$IMAGE" "$ROOT"
fi

if [[ ! -d "$XILINX_PREFIX" ]]; then
  echo "vivado-run: no toolchain at $XILINX_PREFIX" >&2
  echo "            run: bash scripts/provision-vivado.sh" >&2
  exit 2
fi

args=(--rm -v "$ROOT":/workspace -w /workspace
      -v "$XILINX_PREFIX":/tools/Xilinx:ro)

# Host networking: the KV260 sits on a private segment behind this host's second
# NIC (docs/adr/0003-...), so the container needs the host's routing table to
# reach it. It also spares us mapping any ports for hw_server.
args+=(--network host)

# The GUI draws on the host's display. The X server runs with -nolisten tcp, so
# this is the unix socket and nothing else; xhost is what lets the container's
# user through, and it is a deliberate concession (docs/adr/0002-...).
if [[ -n "${DISPLAY:-}" && -d /tmp/.X11-unix ]]; then
  args+=(-v /tmp/.X11-unix:/tmp/.X11-unix -e "DISPLAY=$DISPLAY")
  if command -v xhost >/dev/null 2>&1; then
    xhost +local: >/dev/null 2>&1 || \
      echo ">> warning: xhost failed; the GUI will not be able to open a window" >&2
  fi
else
  echo ">> no DISPLAY — running without GUI support" >&2
fi

# Vivado writes licence and preference state under $HOME; keep it on the host so
# it survives the container, and out of the workspace so it never reaches git.
mkdir -p "$XILINX_PREFIX/.home"
args+=(-v "$XILINX_PREFIX/.home":/home/dev -e HOME=/home/dev)

if [[ -t 0 ]]; then args+=(-it); fi

exec "$DOCKER" run "${args[@]}" "$IMAGE" "${@:-bash}"
