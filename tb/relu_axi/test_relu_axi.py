"""pytest entry point for the relu_axi cocotb suite.

Same shape as the other seams: build the accelerator with Verilator via the
cocotb 2.x Python runner, then run the coroutine tests in ``tb_relu_axi``.
Artifacts land under ``sim/relu_axi``.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

THIS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = THIS_DIR.parents[1]
MODEL_DIR = PROJECT_ROOT / "tb" / "model"
SIM_BUILD = PROJECT_ROOT / "sim" / "relu_axi"

# Importable whether pytest loaded tb/conftest.py or this file was run directly.
sys.path.insert(0, str(PROJECT_ROOT / "tb"))

from rtl_sources import sources_for  # noqa: E402

HDL_TOPLEVEL = "relu_axi"
TEST_MODULE = "tb_relu_axi"

SOURCES = sources_for(HDL_TOPLEVEL)


def test_relu_axi() -> None:
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
    test_relu_axi()
    sys.exit(0)
