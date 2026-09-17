#!/usr/bin/env bash
# Shared RTL source list — the single place to edit when adding a DUT.
# Order matters: packages must precede the modules that import them.
# Sourced by lint.sh, sec.sh, the synthesis flows and (through tb/rtl_sources.py)
# the cocotb seams; paths are relative to the repo root.

RTL_TOP="${RTL_TOP:-sparse_cnn_axi}"

RTL_PACKAGES=(rtl/accel_contract_pkg.sv rtl/sparse_cnn_pkg.sv)
RTL_MODULES=(rtl/sparse_mac_pe.sv rtl/sparse_cnn_axi.sv)
RTL_SOURCES=("${RTL_PACKAGES[@]}" "${RTL_MODULES[@]}")

# The sources one top needs, newline-separated — exactly those, including
# packages. Handing a seam more than it elaborates costs twice: the extra
# modules' unexercised lines land in that seam's coverage report, and a package
# whose parameters go unread fails the -Wall build with UNUSEDPARAM.
rtl_sources_for() {
  case "${1:-}" in
    sparse_mac_pe) printf '%s\n' rtl/sparse_cnn_pkg.sv rtl/sparse_mac_pe.sv ;;
    *) printf '%s\n' "${RTL_SOURCES[@]}" ;;
  esac
}

# Out-of-context synthesis constrains the clock by port name, which differs
# between the bare PE and the AXI-wrapped top level.
rtl_clk_port() {
  case "${1:-}" in
    sparse_mac_pe) echo clk ;;
    *) echo aclk ;;
  esac
}
