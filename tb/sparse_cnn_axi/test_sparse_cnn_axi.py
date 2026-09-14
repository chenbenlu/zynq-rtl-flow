"""pytest entry point for the sparse_cnn_axi cocotb suite.

Same shape as the sparse_mac_pe runner: build the wrapper with Verilator via
the cocotb 2.x Python runner, then run the coroutine tests in
``tb_sparse_cnn_axi``. Artifacts land under ``sim/sparse_cnn_axi``.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

THIS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = THIS_DIR.parents[1]
RTL_DIR = PROJECT_ROOT / "rtl"
MODEL_DIR = PROJECT_ROOT / "tb" / "model"
SIM_BUILD = PROJECT_ROOT / "sim" / "sparse_cnn_axi"

HDL_TOPLEVEL = "sparse_cnn_axi"
TEST_MODULE = "tb_sparse_cnn_axi"

SOURCES = [
    RTL_DIR / "sparse_cnn_pkg.sv",
    RTL_DIR / "sparse_mac_pe.sv",
    RTL_DIR / "sparse_cnn_axi.sv",
]


def test_sparse_cnn_axi() -> None:
    sim = os.getenv("SIM", "verilator")
    runner = get_runner(sim)

    runner.build(
        sources=SOURCES,
        hdl_toplevel=HDL_TOPLEVEL,
        build_dir=str(SIM_BUILD),
        build_args=["--timing", "--coverage", "-Wall"],
        waves=True,
        always=True,
    )

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
    test_sparse_cnn_axi()
    sys.exit(0)
