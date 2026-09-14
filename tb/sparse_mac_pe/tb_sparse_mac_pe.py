"""cocotb tests for sparse_mac_pe.

Drives streams of (weight, activation) pairs with controllable sparsity and
checks the DUT's accumulator and zero-skip counter against the shared numpy
golden model in ``tb/model/sparse_mac_model.py``. Written against the cocotb 2.x
API; value access goes through small helpers so we don't depend on one exact
accessor name.
"""

from __future__ import annotations

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from sparse_mac_model import (
    ACC_W,
    DATA_MASK,
    DATA_MAX,
    DATA_MIN,
    gen_pairs,
    golden,
    to_signed,
)

CLK_PERIOD_NS = 10


# --- value helpers -----------------------------------------------------------
def _read_raw(signal) -> int:
    """Return the unsigned integer value of a signal across cocotb versions."""
    value = signal.value
    for attr in ("to_unsigned", "integer"):
        member = getattr(value, attr, None)
        if member is not None:
            return member() if callable(member) else int(member)
    return int(value)


def read_acc(dut) -> int:
    return to_signed(_read_raw(dut.acc), ACC_W)


def read_skip(dut) -> int:
    return _read_raw(dut.skip_count)


# --- DUT driving -------------------------------------------------------------
async def reset_dut(dut) -> None:
    dut.rst_n.value = 0
    dut.en.value = 1
    dut.clear_acc.value = 0
    dut.valid_in.value = 0
    dut.weight.value = 0
    dut.act.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_stream(dut, weights, acts):
    """Feed one pair per cycle; return the golden (acc, skip) for the stream."""
    for w, a in zip(weights, acts):
        dut.valid_in.value = 1
        dut.weight.value = int(w) & DATA_MASK
        dut.act.value = int(a) & DATA_MASK
        await RisingEdge(dut.clk)
    dut.valid_in.value = 0
    # One more edge + settle so the final NBA update is committed before read.
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    return golden(weights, acts)


async def _check_stream(dut, weights, acts, label):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    exp_acc, exp_skip = await run_stream(dut, weights, acts)

    got_acc = read_acc(dut)
    got_skip = read_skip(dut)
    assert got_acc == exp_acc, f"[{label}] acc {got_acc} != golden {exp_acc}"
    assert got_skip == exp_skip, f"[{label}] skip {got_skip} != golden {exp_skip}"


# --- tests -------------------------------------------------------------------
@cocotb.test()
async def test_dense(dut):
    """No injected zeros: every pair MACs, skip_count near zero."""
    w, a = gen_pairs(64, sparsity=0.0, seed=1)
    await _check_stream(dut, w, a, "dense")


@cocotb.test()
async def test_sparse(dut):
    """High sparsity: most pairs are skipped."""
    w, a = gen_pairs(128, sparsity=0.7, seed=2)
    await _check_stream(dut, w, a, "sparse")


@cocotb.test()
async def test_all_zero(dut):
    """Every pair has a zero operand: acc stays 0, skip == length."""
    n = 32
    w = np.zeros(n, dtype=int)
    a = np.arange(1, n + 1)
    await _check_stream(dut, w, a, "all_zero")


@cocotb.test()
async def test_saturation_range(dut):
    """Full-magnitude operands accumulate exactly (no overflow within ACC_W)."""
    n = 100
    w = np.full(n, DATA_MAX, dtype=int)
    a = np.full(n, DATA_MIN, dtype=int)
    await _check_stream(dut, w, a, "saturation_range")


@cocotb.test()
async def test_clear_acc(dut):
    """clear_acc resets acc + skip mid-stream."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    # Accumulate a few non-zero pairs.
    await run_stream(dut, [3, 4, 5], [2, 2, 2])  # acc = 6 + 8 + 10 = 24
    assert read_acc(dut) == 24, f"pre-clear acc {read_acc(dut)} != 24"

    # Pulse clear_acc for one cycle.
    dut.valid_in.value = 0
    dut.clear_acc.value = 1
    await RisingEdge(dut.clk)
    dut.clear_acc.value = 0
    await Timer(1, unit="ns")
    assert read_acc(dut) == 0, f"post-clear acc {read_acc(dut)} != 0"
    assert read_skip(dut) == 0, f"post-clear skip {read_skip(dut)} != 0"
