#!/usr/bin/env bash
# =============================================================================
# Install the AMD toolchain onto the build host's persistent disk.
#
# Runs on the BUILD HOST, not inside a container — this is the step the Vivado
# image deliberately does not perform (docs/adr/0001-...). Together with
# docker/vivado.Dockerfile and the install config it checks in, it is the
# complete, re-runnable description of the environment.
#
#   bash scripts/provision-vivado.sh --auth         # first time: store an AMD token
#   bash scripts/provision-vivado.sh --config-gen   # then: make a config
#   bash scripts/provision-vivado.sh                # then: install
#
# The installer itself cannot be fetched automatically: AMD requires a signed-in
# account to download it. Place it yourself at $INSTALLER_DIR before running.
#
# This is the web installer, so the install downloads its content as it goes —
# it pulls only the device families the config selects, rather than the ~90 GB
# the offline package would cost to obtain 60 GB of tools. That needs an AMD
# account at install time, which `--auth` handles: it stores a token under
# $HOME/.Xilinx so no credentials ever enter this repo, the image, or a log.
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
provision-vivado.sh [--auth | --config-gen]

  --auth         run the installer's AuthTokenGen: prompts for your AMD account
                 and stores a token under $HOME/.Xilinx. Needed once per machine
                 before a batch install can download anything.
  --config-gen   run the installer's config generator and write a template to
                 scripts/vivado-install-config.txt for you to edit, then exit
  (no args)      install the toolchain using scripts/vivado-install-config.txt

Environment:
  XILINX_VERSION   toolchain version            (default 2026.1)
  XILINX_PREFIX    install destination          (default /home/ubuntu/disk/lab/xilinx)
  INSTALLER_DIR    where the downloaded archive is (default /home/ubuntu/disk/lab/vivado-installer)
MSG
}

find_xsetup() {
  local extracted
  extracted="$(find "$INSTALLER_DIR" -maxdepth 3 -name xsetup -type f 2>/dev/null | head -1)"
  if [[ -n "$extracted" ]]; then
    echo "$extracted"
    return 0
  fi

  # The web installer ships as a Makeself self-extracting .bin; the offline
  # package as a tarball. Both unpack to a directory containing xsetup.
  local bin archive
  bin="$(find "$INSTALLER_DIR" -maxdepth 1 -name '*.bin' -type f 2>/dev/null | head -1)"
  archive="$(find "$INSTALLER_DIR" -maxdepth 1 \( -name '*.tar.gz' -o -name '*.tar' \) 2>/dev/null | head -1)"

  if [[ -n "$bin" ]]; then
    echo ">> extracting $(basename "$bin")" >&2
    chmod +x "$bin"
    # --noexec unpacks without launching the GUI installer, which would fail on
    # a headless host and is not what we want anyway.
    "$bin" --noexec --target "$INSTALLER_DIR/extracted" >/dev/null
  elif [[ -n "$archive" ]]; then
    echo ">> extracting $(basename "$archive")" >&2
    tar -xf "$archive" -C "$INSTALLER_DIR"
  else
    cat >&2 <<MSG
No installer found under $INSTALLER_DIR

AMD requires a signed-in account to download the installer, so this script
cannot fetch it. Download the ${XILINX_VERSION} installer for Linux — either the
web installer (a ~400 MB .bin) or the offline package (a ~90 GB tarball) — and
place it at:

    $INSTALLER_DIR/

then run this script again.
MSG
    return 2
  fi

  find "$INSTALLER_DIR" -maxdepth 3 -name xsetup -type f | head -1
}

# Where Vivado's settings64.sh lands. 2026.1 nests as <prefix>/<version>/<Tool>/;
# earlier releases used <prefix>/<Tool>/<version>/. Echoes the path, or nothing.
installed_settings() {
  local a="$XILINX_PREFIX/$XILINX_VERSION/Vivado/settings64.sh"
  local b="$XILINX_PREFIX/Vivado/$XILINX_VERSION/settings64.sh"
  if   [[ -f "$a" ]]; then echo "$a"
  elif [[ -f "$b" ]]; then echo "$b"
  fi
}

# The web installer downloads content during the install, which needs a token
# from an AMD account. Absent it, the install fails well into the run rather
# than at the start.
auth_token_present() {
  local home_dir="${HOME:?}"
  compgen -G "$home_dir/.Xilinx/wi_authentication_key" >/dev/null 2>&1 || \
  compgen -G "$home_dir/.Xilinx/*auth*" >/dev/null 2>&1
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

  if [[ "${1:-}" == "--auth" ]]; then
    if [[ ! -t 0 ]]; then
      echo "provision: --auth prompts for your AMD account; run it on a terminal." >&2
      exit 2
    fi
    "$xsetup" -b AuthTokenGen
    if auth_token_present; then
      echo ">> token stored under $HOME/.Xilinx — it is not in this repo and must not be."
    else
      echo "provision: AuthTokenGen finished but no token is visible under $HOME/.Xilinx" >&2
      exit 1
    fi
    exit 0
  fi

  if [[ "${1:-}" == "--config-gen" ]]; then
    # ConfigGen prompts for a product and always writes to a fixed path; -c is
    # for *reading* a config, not for choosing where to write one. Product 1 is
    # Vitis, which bundles Vivado — both flows need it (see CONTEXT.md).
    local generated="$HOME/.Xilinx/install_config.txt"
    rm -f "$generated"
    echo "${PRODUCT_CHOICE:-1}" | "$xsetup" -b ConfigGen >/dev/null 2>&1 || true

    if [[ ! -s "$generated" ]]; then
      echo "provision: ConfigGen did not produce $generated" >&2
      echo "           run '$xsetup -b ConfigGen' by hand to see what it asked." >&2
      exit 1
    fi
    cp "$generated" "$CONFIG"
    cat <<MSG

Wrote $CONFIG  (product: $(grep -m1 '^Edition=' "$CONFIG" || echo 'see file'))

Edit it before installing:
  - Destination  -> $XILINX_PREFIX
  - Devices      -> keep Zynq UltraScale+ MPSoC, drop everything else. With the
                    web installer this governs the download as well as the
                    install, so it is the difference between pulling ~60 GB and
                    pulling everything. It covers both ZU5EV (KV260) and
                    ZU7EV (ZCU104).
  - Products     -> Vivado and Vitis are both needed: this project runs the
                    embedded and acceleration flows side by side (see CONTEXT.md).

Then commit it — it is part of the environment's description, not a local
preference.
MSG
    exit 0
  fi

  # Re-running provisioning is how you check the environment, so it must not
  # try to reinstall over a good install — xsetup refuses that with an error
  # that reads like a failure.
  local existing
  existing="$(installed_settings)"
  if [[ -n "$existing" && "${FORCE_REINSTALL:-0}" != "1" ]]; then
    echo ">> ${XILINX_VERSION} is already installed: $existing"
    echo ">> nothing to do. To add device families, use: \$xsetup -b Add"
    echo ">> to install a second copy elsewhere, set XILINX_PREFIX."
    exit 0
  fi

  if [[ ! -f "$CONFIG" ]]; then
    echo "provision: no install config at $CONFIG" >&2
    echo "           run: bash scripts/provision-vivado.sh --config-gen" >&2
    exit 2
  fi

  if ! auth_token_present; then
    cat >&2 <<MSG
provision: no AMD authentication token under $HOME/.Xilinx

The web installer downloads its content during the install and needs one. Run:

    bash scripts/provision-vivado.sh --auth

It prompts for your AMD account and stores a token; nothing is written to this
repo. Without it the install fails partway through, not at the start.
MSG
    exit 2
  fi

  check_space

  echo ">> installing ${XILINX_VERSION} to $XILINX_PREFIX (downloads as it goes; hours)"
  "$xsetup" --agree XilinxEULA,3rdPartyEULA \
            --batch Install \
            --config "$CONFIG"

  local settings
  settings="$(installed_settings)"
  if [[ -z "$settings" ]]; then
    echo "provision: install finished but no Vivado settings64.sh appeared under" >&2
    echo "           $XILINX_PREFIX — check the Destination in $CONFIG." >&2
    exit 1
  fi
  echo ">> installed. Vivado settings at $settings"
  echo ">> next: bash scripts/vivado-run.sh build && make synth"
}

main "$@"
