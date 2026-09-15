#!/usr/bin/env bash
# Vivado GUI on the build host's display — block design and implementation reports.
#
#   make vivado-gui
#   make vivado-gui PRJ=build/zcu104/impl/prj/impl_prj.xpr
#   bash flows/embedded/gui.sh build/kv260/impl/prj/impl_prj.xpr   # inside the container

source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"
vivado_env Vivado

# The project arrives as an argument rather than in the environment. The
# Makefile's PRJ= is set on the host, and docker run forwards only the variables
# it was told to — so an env var would be silently dropped at the container
# boundary, leaving the GUI to open with no project and no complaint.
# A relative path resolves against the repo root: env.sh has already cd'd there.
exec vivado "$@"
