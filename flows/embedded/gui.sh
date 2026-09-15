#!/usr/bin/env bash
# Vivado GUI on the build host's display — block design and implementation reports.
#
#   make vivado-gui
#   make vivado-gui PRJ=build/zcu104/impl/prj/impl_prj.xpr

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"
vivado_env Vivado

# Relative to the repo root: env.sh has already cd'd there.
exec vivado ${PRJ:+"$PRJ"}
