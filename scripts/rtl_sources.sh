#!/usr/bin/env bash
# Shared RTL source list — the single place to edit when adding a DUT.
# Order matters: packages must precede the modules that import them.
# Sourced by lint.sh, sec.sh and the synthesis flows; paths are relative to the
# repo root.

RTL_TOP="${RTL_TOP:-sparse_cnn_axi}"
RTL_SOURCES=(rtl/sparse_cnn_pkg.sv rtl/sparse_mac_pe.sv rtl/sparse_cnn_axi.sv)

# Out-of-context synthesis constrains the clock by port name, which differs
# between the bare PE and the AXI-wrapped top level.
rtl_clk_port() {
  case "${1:-}" in
    sparse_mac_pe) echo clk ;;
    *) echo aclk ;;
  esac
}
