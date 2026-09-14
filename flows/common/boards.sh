#!/usr/bin/env bash
# Board -> silicon mapping. The single place to edit when adding a board.
# Sourced by the flow scripts; board_select "$BOARD" sets BOARD_PART,
# BOARD_FILE (the latter may be empty when the design does not need board
# files, e.g. out-of-context synthesis) and BOARD_PL_CLK_MHZ.
#
# BOARD_PL_CLK_MHZ is the PL clock the Zynq PS is asked to produce, and the
# frequency the implementation result is judged against. Each is a round
# frequency comfortably below that board's measured out-of-context ceiling for
# the bare PE — 310.7 MHz on KV260, 395.1 MHz on ZCU104 — leaving margin for the
# AXI interface, the interconnect and routing in a real system. The two boards
# do not share a target because KV260's -2LV low-voltage grade is materially
# slower than ZCU104's -2, so one number would either waste the faster part or
# fail on the slower.
#
# These are provisional: the wrapped top level's own ceiling has not been
# measured yet. Re-derive them from `make synth RTL_TOP=sparse_cnn_axi` once
# that has run on the build host.

board_select() {
  case "${1:-}" in
    kv260)
      BOARD_PART="xck26-sfvc784-2LV-c"
      BOARD_FILE="xilinx.com:kv260_som:part0:1.4"
      BOARD_PL_CLK_MHZ="200"
      ;;
    zcu104)
      BOARD_PART="xczu7ev-ffvc1156-2-e"
      BOARD_FILE="xilinx.com:zcu104:part0:1.1"
      BOARD_PL_CLK_MHZ="250"
      ;;
    *)
      echo "unknown BOARD '${1:-}' — known boards: kv260 zcu104" >&2
      echo "add it to flows/common/boards.sh" >&2
      return 2
      ;;
  esac
}
