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

# The toolchain is mounted at the SAME absolute path it was installed to, not a
# tidier one: Vivado's settings64.sh sources its sub-scripts by absolute path,
# baked in at install time. Mount it anywhere else and sourcing fails with a
# "No such file or directory" naming a path that plainly exists on the host.
args=(--rm -v "$ROOT":/workspace -w /workspace
      -v "$XILINX_PREFIX":"$XILINX_PREFIX":ro
      -e "XILINX_ROOT=$XILINX_PREFIX")

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
mkdir -p "$XILINX_PREFIX/.home/.Xilinx"
args+=(-v "$XILINX_PREFIX/.home":/home/dev -e HOME=/home/dev)

# From 2026.1 Vivado refuses to launch without a licence, free tier included.
# Pointed at explicitly rather than relying on the default search: the default
# depends on $HOME resolving the way we expect inside the container, and a
# licence that is merely *not found* fails identically to one that does not
# cover the part — which is the harder question to be debugging.
LICENSE_FILE="${LICENSE_FILE:-$XILINX_PREFIX/.home/.Xilinx/Xilinx.lic}"
if [[ -f "$LICENSE_FILE" ]]; then
  args+=(-e "XILINXD_LICENSE_FILE=$LICENSE_FILE")
else
  echo ">> warning: no licence at $LICENSE_FILE — Vivado will refuse to start" >&2
fi

if [[ -t 0 ]]; then args+=(-it); fi

exec "$DOCKER" run "${args[@]}" "$IMAGE" "${@:-bash}"
