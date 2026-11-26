#!/usr/bin/env bash
# =============================================================================
# Run a command inside the Vivado container.
#
# Optional: only for a host whose OS the AMD toolchain does not support. On a
# supported OS, source settings64.sh and run make directly.
#
#   bash scripts/vivado-run.sh build          # build the image
#   bash scripts/vivado-run.sh                # interactive shell
#   bash scripts/vivado-run.sh make synth     # one-shot
#   GUI=1 bash scripts/vivado-run.sh bash flows/embedded/gui.sh
#
# XILINX_ROOT    install prefix on the host (required; mounted read-only)
# LICENSE_FILE   AMD licence file (default ~/.Xilinx/Xilinx.lic, then
#                $XILINXD_LICENSE_FILE if that is a file)
# VIVADO_HOME    the container's $HOME, kept between runs
#                (default ${XDG_DATA_HOME:-~/.local/share}/zynq-rtl-flow/vivado-home)
# GUI=1          share the host's X socket (docs/adr/0002-...)
# HOST_NET       1/0 forces the host's network on/off; unset, it is on only for
#                a node-locked licence. Also needed to reach a board on a
#                private segment behind this host (docs/adr/0003-...)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="${IMAGE:-zynq-rtl-flow-vivado:latest}"
# The lab's /etc/bash.bashrc aliases docker to podman for anyone outside the
# docker group, but an alias does not reach a script: without this, such a user
# gets "permission denied" on the docker socket instead of their own podman.
if [[ -z "${DOCKER:-}" ]]; then
  if ! id -nG | grep -qw docker && command -v podman >/dev/null 2>&1; then
    DOCKER=podman
  else
    DOCKER=docker
  fi
fi

if [[ "${1:-}" == "build" ]]; then
  # Rootless podman needs neither a remapped dev user (--userns=keep-id below
  # runs the container as the caller) nor could it build one: the caller's UID
  # lies outside their own subordinate range. Its seccomp profile, from podman
  # 3.x, predates fchmodat2 and answers it with EPERM rather than ENOSYS, so
  # Ubuntu 24.04's glibc never falls back and every tar in the build fails
  # with "Cannot change mode".
  if [[ "$(basename "$DOCKER")" == podman ]]; then
    build_args=(--security-opt seccomp=unconfined)
  else
    build_args=(--build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)")
  fi
  exec "$DOCKER" build "${build_args[@]}" -f "$ROOT/docker/Dockerfile" \
       --target vivado -t "$IMAGE" "$ROOT"
fi

if [[ -z "${XILINX_ROOT:-}" || ! -d "$XILINX_ROOT" ]]; then
  echo "vivado-run: set XILINX_ROOT to the AMD toolchain's install prefix" >&2
  exit 2
fi

# The toolchain is mounted at the SAME absolute path it was installed to, not a
# tidier one: Vivado's settings64.sh sources its sub-scripts by absolute path,
# baked in at install time. Mount it anywhere else and sourcing fails with a
# "No such file or directory" naming a path that plainly exists on the host.
args=(--rm -v "$ROOT":/workspace -w /workspace
      -v "$XILINX_ROOT":"$XILINX_ROOT":ro
      -e "XILINX_ROOT=$XILINX_ROOT")

# Rootless podman maps the image's user onto a subordinate UID unless told to
# keep the caller's, and the bind-mounted workspace is then read-only to it.
# podman 3.x's keep-id still runs as the image's USER (dev, UID 1000), so the
# caller's UID is also passed explicitly.
if [[ "$(basename "$DOCKER")" == podman ]]; then
  args+=(--userns=keep-id --user "$(id -u):$(id -g)")
fi

# The X server runs with -nolisten tcp, so this is the unix socket and nothing
# else; xhost is what lets the container's user through (docs/adr/0002-...).
if [[ "${GUI:-0}" == 1 ]]; then
  if [[ -z "${DISPLAY:-}" || ! -d /tmp/.X11-unix ]]; then
    echo "vivado-run: GUI=1 but there is no X display to share" >&2
    exit 2
  fi
  args+=(-v /tmp/.X11-unix:/tmp/.X11-unix -e "DISPLAY=$DISPLAY")
  if command -v xhost >/dev/null 2>&1; then
    xhost +local: >/dev/null 2>&1 || \
      echo ">> warning: xhost failed; the GUI will not be able to open a window" >&2
  fi
fi

# Vivado writes preference and project state under $HOME; keep it on the host so
# it survives the container, outside the workspace so it never reaches git, and
# outside the toolchain, which is the user's and may be shared or read-only.
VIVADO_HOME="${VIVADO_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/zynq-rtl-flow/vivado-home}"
mkdir -p "$VIVADO_HOME"
args+=(-v "$VIVADO_HOME":/home/dev -e HOME=/home/dev)

# From 2026.1 Vivado refuses to launch without a licence, free tier included.
# Pointed at explicitly: a licence that is merely *not found* fails identically
# to one that does not cover the part, which is the harder question to debug.
# A host-wide XILINXD_LICENSE_FILE is the fallback, used only when it names a
# single file: a port@server or a list cannot be bind-mounted.
if [[ -z "${LICENSE_FILE:-}" ]]; then
  LICENSE_FILE="$HOME/.Xilinx/Xilinx.lic"
  if [[ ! -f "$LICENSE_FILE" && -f "${XILINXD_LICENSE_FILE:-}" ]]; then
    LICENSE_FILE="$XILINXD_LICENSE_FILE"
  fi
fi
node_locked=0
if [[ -f "$LICENSE_FILE" ]]; then
  args+=(-v "$LICENSE_FILE":/licence/Xilinx.lic:ro
         -e XILINXD_LICENSE_FILE=/licence/Xilinx.lic)
  if grep -oE 'HOSTID=[^[:space:];]+' "$LICENSE_FILE" | grep -qviE '=(ANY|DEMO)$'; then
    node_locked=1
  fi
else
  echo ">> warning: no licence at $LICENSE_FILE — Vivado will refuse to start" >&2
fi

# A node-locked licence names the host's NIC by its MAC. In a container with its
# own network namespace that NIC is not there, and FlexLM does not report a
# host mismatch: Vivado segfaults inside the licence checkout before printing
# anything about licensing.
if [[ "${HOST_NET:-$node_locked}" == 1 ]]; then
  args+=(--network host)
elif (( node_locked )); then
  echo ">> warning: HOST_NET=0 with a node-locked licence — Vivado will crash at licence checkout" >&2
fi

if [[ -t 0 ]]; then args+=(-it); fi

exec "$DOCKER" run "${args[@]}" "$IMAGE" "${@:-bash}"
