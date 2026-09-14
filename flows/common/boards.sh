#!/usr/bin/env bash
# Board -> silicon mapping. The single place to edit when adding a board.
# Sourced by the flow scripts; board_select "$BOARD" sets BOARD_PART and
# BOARD_FILE (the latter may be empty when the design does not need board
# files, e.g. out-of-context synthesis).

board_select() {
  case "${1:-}" in
    kv260)
      BOARD_PART="xck26-sfvc784-2LV-c"
      BOARD_FILE="xilinx.com:kv260_som:part0:1.4"
      ;;
    zcu104)
      BOARD_PART="xczu7ev-ffvc1156-2-e"
      BOARD_FILE="xilinx.com:zcu104:part0:1.1"
      ;;
    *)
      echo "unknown BOARD '${1:-}' — known boards: kv260 zcu104" >&2
      echo "add it to flows/common/boards.sh" >&2
      return 2
      ;;
  esac
}
