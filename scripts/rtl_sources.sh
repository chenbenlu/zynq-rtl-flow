#!/usr/bin/env bash
# Shared RTL source list — the single place to edit when adding a DUT.
# Order matters: packages must precede the modules that import them.
# Sourced by lint.sh and sec.sh; paths are relative to the repo root.

RTL_TOP="${RTL_TOP:-sparse_mac_pe}"
RTL_SOURCES=(rtl/sparse_cnn_pkg.sv rtl/sparse_mac_pe.sv)
