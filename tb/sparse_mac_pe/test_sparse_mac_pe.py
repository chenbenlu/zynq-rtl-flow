"""pytest entry point for the sparse_mac_pe cocotb suite.

Uses the cocotb 2.x Python test runner to build the DUT with Verilator and run
the coroutine tests in ``tb_sparse_mac_pe``. Run with::

    pytest tb/sparse_mac_pe/test_sparse_mac_pe.py
    SIM=verilator pytest tb            # explicit simulator

Build/run artifacts (and the waveform) land under ``sim/sparse_mac_pe``.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

THIS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = THIS_DIR.parents[1]
MODEL_DIR = PROJECT_ROOT / "tb" / "model"
SIM_BUILD = PROJECT_ROOT / "sim" / "sparse_mac_pe"

# Importable whether pytest loaded tb/conftest.py or this file was run directly.
sys.path.insert(0, str(PROJECT_ROOT / "tb"))

from rtl_sources import sources_for  # noqa: E402

HDL_TOPLEVEL = "sparse_mac_pe"
TEST_MODULE = "tb_sparse_mac_pe"

SOURCES = sources_for(HDL_TOPLEVEL)


def test_sparse_mac_pe() -> None:
    sim = os.getenv("SIM", "verilator")
    runner = get_runner(sim)

    # cocotb 2.x needs --timing for its scheduler; --coverage emits coverage.dat
    # at end of simulation; -Wall keeps the elaboration lint-clean.
    runner.build(
        sources=SOURCES,
        hdl_toplevel=HDL_TOPLEVEL,
        build_dir=str(SIM_BUILD),
        build_args=["--timing", "--coverage", "-Wall"],
        waves=True,
        always=True,
    )

    # Make the coroutine module importable by the cocotb-spawned simulator.
    os.environ["PYTHONPATH"] = os.pathsep.join(
        [str(THIS_DIR), str(MODEL_DIR), os.environ.get("PYTHONPATH", "")]
    ).rstrip(os.pathsep)

    runner.test(
        hdl_toplevel=HDL_TOPLEVEL,
        test_module=TEST_MODULE,
        build_dir=str(SIM_BUILD),
        waves=True,
    )


if __name__ == "__main__":
    # Allow running the flow directly without pytest.
    test_sparse_mac_pe()
    sys.exit(0)
