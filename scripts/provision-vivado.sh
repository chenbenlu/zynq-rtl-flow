#!/usr/bin/env bash
# =============================================================================
# Install the AMD toolchain onto the build host's persistent disk.
#
# Runs on the BUILD HOST, not inside a container — this is the step the Vivado
# image deliberately does not perform (docs/adr/0001-...). Together with
# docker/vivado.Dockerfile and the install config it checks in, it is the
# complete, re-runnable description of the environment.
#
#   bash scripts/provision-vivado.sh --config-gen   # first time: make a config
#   bash scripts/provision-vivado.sh                # install
#
# The installer archive cannot be fetched automatically: AMD requires a signed-in
# account to download it. Place it yourself at $INSTALLER_DIR before running.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

XILINX_VERSION="${XILINX_VERSION:-2026.1}"
XILINX_PREFIX="${XILINX_PREFIX:-/home/ubuntu/disk/lab/xilinx}"
INSTALLER_DIR="${INSTALLER_DIR:-/home/ubuntu/disk/lab/vivado-installer}"
CONFIG="${CONFIG:-$ROOT/scripts/vivado-install-config.txt}"

# Installed size plus the installer's own working set. Checked up front because
# running out of disk mid-install leaves an unusable half-installation that has
# to be removed by hand.
REQUIRED_GB="${REQUIRED_GB:-250}"

usage() {
  cat <<'MSG'
provision-vivado.sh [--config-gen]

  (no args)      install the toolchain using scripts/vivado-install-config.txt
  --config-gen   run the installer's config generator and write a template to
                 scripts/vivado-install-config.txt for you to edit, then exit

Environment:
  XILINX_VERSION   toolchain version            (default 2026.1)
  XILINX_PREFIX    install destination          (default /home/ubuntu/disk/lab/xilinx)
  INSTALLER_DIR    where the downloaded archive is (default /home/ubuntu/disk/lab/vivado-installer)
MSG
}

find_xsetup() {
  local extracted
  extracted="$(find "$INSTALLER_DIR" -maxdepth 2 -name xsetup -type f 2>/dev/null | head -1)"
  if [[ -n "$extracted" ]]; then
    echo "$extracted"
    return 0
  fi

  local archive
  archive="$(find "$INSTALLER_DIR" -maxdepth 1 -name '*.tar.gz' -o -maxdepth 1 -name '*.tar' 2>/dev/null | head -1)"
  if [[ -z "$archive" ]]; then
    cat >&2 <<MSG
No installer found under $INSTALLER_DIR

AMD requires a signed-in account to download the Unified Installer, so this
script cannot fetch it. Download the ${XILINX_VERSION} "Unified Installer for
Linux" (a self-extracting archive, roughly 90 GB) and place it at:

    $INSTALLER_DIR/

then run this script again.
MSG
    return 2
  fi

  echo ">> extracting $(basename "$archive")" >&2
  tar -xf "$archive" -C "$INSTALLER_DIR"
  find "$INSTALLER_DIR" -maxdepth 2 -name xsetup -type f | head -1
}

check_space() {
  local target_fs avail_gb
  target_fs="$(dirname "$XILINX_PREFIX")"
  mkdir -p "$XILINX_PREFIX"
  avail_gb=$(( $(df --output=avail -k "$target_fs" | tail -1) / 1024 / 1024 ))
  echo ">> $target_fs has ${avail_gb} GB free (need ~${REQUIRED_GB} GB)"
  if (( avail_gb < REQUIRED_GB )); then
    echo "provision: not enough free space on $target_fs." >&2
    echo "           Installing anyway risks a half-finished install." >&2
    exit 1
  fi
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  local xsetup
  xsetup="$(find_xsetup)"
  [[ -n "$xsetup" ]] || { echo "provision: could not locate xsetup" >&2; exit 2; }
  echo ">> installer: $xsetup"

  if [[ "${1:-}" == "--config-gen" ]]; then
    local tmp
    tmp="$(mktemp -d)"
    "$xsetup" -b ConfigGen -c "$tmp/config.txt"
    cp "$tmp/config.txt" "$CONFIG"
    rm -rf "$tmp"
    cat <<MSG

Wrote $CONFIG

Edit it before installing:
  - Destination  -> $XILINX_PREFIX
  - Devices      -> keep Zynq UltraScale+ MPSoC, drop everything else. This is
                    what keeps the install near 60 GB rather than over 100 GB;
                    it covers both ZU5EV (KV260) and ZU7EV (ZCU104).
  - Products     -> Vivado and Vitis are both needed: this project runs the
                    embedded and acceleration flows side by side (see CONTEXT.md).

Then commit it — it is part of the environment's description, not a local
preference.
MSG
    exit 0
  fi

  if [[ ! -f "$CONFIG" ]]; then
    echo "provision: no install config at $CONFIG" >&2
    echo "           run: bash scripts/provision-vivado.sh --config-gen" >&2
    exit 2
  fi

  check_space

  echo ">> installing ${XILINX_VERSION} to $XILINX_PREFIX (this takes hours)"
  "$xsetup" --agree XilinxEULA,3rdPartyEULA \
            --batch Install \
            --config "$CONFIG"

  local settings="$XILINX_PREFIX/Vivado/$XILINX_VERSION/settings64.sh"
  if [[ ! -f "$settings" ]]; then
    echo "provision: install finished but $settings is missing —" >&2
    echo "           check the Destination in $CONFIG." >&2
    exit 1
  fi
  echo ">> installed. Vivado settings at $settings"
  echo ">> next: bash scripts/vivado-run.sh build && make synth"
}

main "$@"
