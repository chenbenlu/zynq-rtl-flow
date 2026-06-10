"""Shared pytest configuration for the testbench suite.

Keeps project-relative paths in one place and makes per-DUT testbench modules
importable so cocotb's runner (and pytest collection) resolve them regardless
of the working directory the suite is invoked from.
"""

from __future__ import annotations

import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RTL_DIR = PROJECT_ROOT / "rtl"
TB_DIR = PROJECT_ROOT / "tb"
SIM_DIR = PROJECT_ROOT / "sim"

# Ensure every testbench package directory is importable as a top-level module
# (cocotb's TEST_MODULE lookup relies on this).
for tb_pkg in TB_DIR.iterdir():
    if tb_pkg.is_dir() and not tb_pkg.name.startswith((".", "__")):
        sys.path.insert(0, str(tb_pkg))
