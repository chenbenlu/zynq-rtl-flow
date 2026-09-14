"""cocotb tests for sparse_cnn_axi — the AXI-wrapped accelerator top level.

Everything here drives and observes the wrapper's own AXI ports: operand pairs
go in over AXI4-Stream, control and results go over AXI4-Lite. Nothing reaches
inside to the PE, because the contract the wrapper presents to the PS is the
whole point of the module.

The golden model and the sparsity-controlled operand generator are imported
from ``tb/model/sparse_mac_model.py``, the same ones the bare PE testbench uses.
"""

from __future__ import annotations

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotbext.axi import (
    AxiLiteBus,
    AxiLiteMaster,
    AxiStreamBus,
    AxiStreamFrame,
    AxiStreamSource,
)

from sparse_mac_model import ACC_W, DATA_MASK, DATA_W, gen_pairs, golden, to_signed

CLK_PERIOD_NS = 10

# The register map documented in docs/register-map.md. These constants are the
# specification the tests hold the RTL to, not a copy of it.
REG_ID = 0x00
REG_CTRL = 0x04
REG_STATUS = 0x08
REG_ACC = 0x0C
REG_SKIP = 0x10

CTRL_START = 1 << 0
CTRL_CLEAR = 1 << 1
CTRL_EN = 1 << 2

STATUS_BUSY = 1 << 0
STATUS_DONE = 1 << 1

ID_EXPECTED = 0x53500100

POLL_LIMIT = 10_000


def pack_pair(weight: int, act: int) -> int:
    """One stream beat: weight in the low operand lane, activation above it."""
    return ((int(act) & DATA_MASK) << DATA_W) | (int(weight) & DATA_MASK)


class _BeatCounter:
    """Counts the beats the wrapper accepts, by watching the handshake."""

    def __init__(self):
        self.total = 0

    async def run(self, dut) -> None:
        while True:
            await RisingEdge(dut.aclk)
            if dut.s_axis_tvalid.value == 1 and dut.s_axis_tready.value == 1:
                self.total += 1


class Accelerator:
    """Driver for the wrapper's two AXI interfaces."""

    def __init__(self, dut):
        self.dut = dut
        self.axil = AxiLiteMaster(
            AxiLiteBus.from_prefix(dut, "s_axi"),
            dut.aclk,
            dut.aresetn,
            reset_active_level=False,
        )
        # One operand pair per beat: the stream is 2*DATA_W wide and carries a
        # single "byte" of that width, so frames are lists of packed pairs.
        self.stream = AxiStreamSource(
            AxiStreamBus.from_prefix(dut, "s_axis"),
            dut.aclk,
            dut.aresetn,
            reset_active_level=False,
            byte_size=2 * DATA_W,
        )

    def count_beats(self):
        """Start counting accepted stream beats at the wrapper's own ports."""
        counter = _BeatCounter()
        cocotb.start_soon(counter.run(self.dut))
        return counter

    async def read(self, addr: int) -> int:
        return await self.axil.read_dword(addr)

    async def write(self, addr: int, value: int) -> None:
        await self.axil.write_dword(addr, value)

    async def read_acc(self) -> int:
        return to_signed(await self.read(REG_ACC), ACC_W)

    async def send(self, weights, acts) -> None:
        tile = AxiStreamFrame([pack_pair(w, a) for w, a in zip(weights, acts)])
        await self.stream.send(tile)

    async def start(self) -> None:
        await self.write(REG_CTRL, CTRL_EN | CTRL_START)

    async def await_done(self) -> None:
        for _ in range(POLL_LIMIT):
            status = await self.read(REG_STATUS)
            if status & STATUS_DONE:
                assert not status & STATUS_BUSY, "DONE raised while still BUSY"
                return
        raise AssertionError("tile never completed (STATUS.DONE stayed low)")

    async def run_tile(self, weights, acts) -> tuple[int, int]:
        """Submit one tile and return the (accumulator, skip count) read back."""
        await self.start()
        await self.send(weights, acts)
        await self.await_done()
        return await self.read_acc(), await self.read(REG_SKIP)


async def bring_up(dut) -> Accelerator:
    cocotb.start_soon(Clock(dut.aclk, CLK_PERIOD_NS, unit="ns").start())
    dut.aresetn.value = 0
    accel = Accelerator(dut)
    for _ in range(5):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)
    return accel


async def check_tile(accel, weights, acts, label: str) -> None:
    exp_acc, exp_skip = golden(weights, acts)
    got_acc, got_skip = await accel.run_tile(weights, acts)
    assert got_acc == exp_acc, f"[{label}] acc {got_acc} != golden {exp_acc}"
    assert got_skip == exp_skip, f"[{label}] skip {got_skip} != golden {exp_skip}"


# --- the cases ported from the PE's seam -------------------------------------
@cocotb.test()
async def test_dense(dut):
    """No injected zeros: every pair MACs, skip count near zero."""
    accel = await bring_up(dut)
    w, a = gen_pairs(64, sparsity=0.0, seed=1)
    await check_tile(accel, w, a, "dense")


@cocotb.test()
async def test_sparse(dut):
    """High sparsity: most pairs are skipped."""
    accel = await bring_up(dut)
    w, a = gen_pairs(128, sparsity=0.7, seed=2)
    await check_tile(accel, w, a, "sparse")


@cocotb.test()
async def test_all_zero(dut):
    """Every pair has a zero operand: acc stays 0, skip == tile length."""
    accel = await bring_up(dut)
    n = 32
    await check_tile(accel, np.zeros(n, dtype=int), np.arange(1, n + 1), "all_zero")


@cocotb.test()
async def test_saturation_range(dut):
    """Full-magnitude operands accumulate exactly (no overflow within ACC_W)."""
    accel = await bring_up(dut)
    n = 100
    w, a = gen_pairs(n, sparsity=0.0, seed=3)
    w[:] = 127
    a[:] = -128
    await check_tile(accel, w, a, "saturation_range")


# --- cases the new seam adds -------------------------------------------------
@cocotb.test()
async def test_id_register(dut):
    """The identification register reads correctly before anything is written."""
    accel = await bring_up(dut)
    got = await accel.read(REG_ID)
    assert got == ID_EXPECTED, f"ID {got:#010x} != {ID_EXPECTED:#010x}"


@cocotb.test()
async def test_register_map(dut):
    """Reads and writes behave as the documented map says they do."""
    accel = await bring_up(dut)

    # EN comes up set so a single CTRL write can start a tile; START and CLEAR
    # are write-1-to-pulse and always read back low.
    assert await accel.read(REG_CTRL) == CTRL_EN
    assert await accel.read(REG_STATUS) == 0
    assert await accel.read(REG_ACC) == 0
    assert await accel.read(REG_SKIP) == 0

    await accel.write(REG_CTRL, 0)
    assert await accel.read(REG_CTRL) == 0, "EN did not clear"
    await accel.write(REG_CTRL, CTRL_EN | CTRL_START | CTRL_CLEAR)
    assert await accel.read(REG_CTRL) == CTRL_EN, "START/CLEAR did not self-clear"

    # Bits outside the documented three are reserved: they swallow writes and
    # read back zero, so the register exposes no state the map does not describe.
    await accel.write(REG_CTRL, 0xFFFFFFFF)
    assert await accel.read(REG_CTRL) == CTRL_EN, "reserved CTRL bits are writable"

    # An unmapped offset reads as zero rather than aliasing a real register.
    assert await accel.read(0x40) == 0


@cocotb.test()
async def test_backpressure_from_source(dut):
    """A stalling source loses nothing: the result matches the dense case."""
    accel = await bring_up(dut)
    accel.stream.set_pause_generator(iter(cycle_pauses()))
    w, a = gen_pairs(48, sparsity=0.3, seed=4)
    await check_tile(accel, w, a, "source_stall")


@cocotb.test()
async def test_backpressure_from_wrapper(dut):
    """Clearing EN mid-tile withdraws ready; no accepted beat is lost."""
    accel = await bring_up(dut)
    w, a = gen_pairs(64, sparsity=0.2, seed=5)

    await accel.start()
    await accel.send(w, a)

    # Stall long enough that the source has beats waiting, then resume.
    await RisingEdge(dut.aclk)
    await accel.write(REG_CTRL, 0)
    for _ in range(20):
        await RisingEdge(dut.aclk)
        assert dut.s_axis_tready.value == 0, "ready asserted while EN was low"
    await accel.write(REG_CTRL, CTRL_EN)

    await accel.await_done()
    exp_acc, exp_skip = golden(w, a)
    assert await accel.read_acc() == exp_acc
    assert await accel.read(REG_SKIP) == exp_skip


@cocotb.test()
async def test_no_beats_before_start(dut):
    """Ready stays low until a tile is started, so nothing is consumed early."""
    accel = await bring_up(dut)
    w, a = gen_pairs(16, sparsity=0.0, seed=6)
    await accel.send(w, a)

    for _ in range(20):
        await RisingEdge(dut.aclk)
        assert dut.s_axis_tready.value == 0, "ready asserted before START"

    await accel.start()
    await accel.await_done()
    exp_acc, exp_skip = golden(w, a)
    assert await accel.read_acc() == exp_acc
    assert await accel.read(REG_SKIP) == exp_skip


@cocotb.test()
async def test_back_to_back_tiles(dut):
    """Several tiles in a row: state clears between them without a reset."""
    accel = await bring_up(dut)
    for i in range(4):
        w, a = gen_pairs(24 + 8 * i, sparsity=0.1 * i, seed=10 + i)
        await check_tile(accel, w, a, f"tile{i}")


@cocotb.test()
async def test_result_read_before_completion(dut):
    """A read issued mid-tile returns the last completed tile, not a partial."""
    accel = await bring_up(dut)

    first_w, first_a = gen_pairs(32, sparsity=0.0, seed=20)
    await check_tile(accel, first_w, first_a, "first")
    first_acc, first_skip = golden(first_w, first_a)

    second_w, second_a = gen_pairs(256, sparsity=0.5, seed=21)
    accel.stream.set_pause_generator(iter(cycle_pauses()))
    await accel.start()
    await accel.send(second_w, second_a)

    saw_busy = False
    for _ in range(POLL_LIMIT):
        status = await accel.read(REG_STATUS)
        if status & STATUS_DONE:
            break
        saw_busy = True
        assert await accel.read_acc() == first_acc, "partial accumulator leaked"
        assert await accel.read(REG_SKIP) == first_skip, "partial skip count leaked"
    assert saw_busy, "tile completed before a mid-tile read could be issued"

    exp_acc, exp_skip = golden(second_w, second_a)
    assert await accel.read_acc() == exp_acc
    assert await accel.read(REG_SKIP) == exp_skip


@cocotb.test()
async def test_explicit_clear(dut):
    """CTRL.CLEAR wipes the readable tile state without resetting the block."""
    accel = await bring_up(dut)
    w, a = gen_pairs(32, sparsity=0.4, seed=30)
    await check_tile(accel, w, a, "before_clear")

    await accel.write(REG_CTRL, CTRL_EN | CTRL_CLEAR)
    await Timer(CLK_PERIOD_NS * 2, unit="ns")
    assert await accel.read_acc() == 0, "accumulator survived an explicit clear"
    assert await accel.read(REG_SKIP) == 0, "skip count survived an explicit clear"

    # And the block is still usable afterwards.
    w, a = gen_pairs(32, sparsity=0.4, seed=31)
    await check_tile(accel, w, a, "after_clear")


@cocotb.test()
async def test_clear_mid_tile(dut):
    """The PE's mid-stream clear, ported: CLEAR discards what a tile has
    accumulated so far and the rest of the same tile accumulates from zero."""
    accel = await bring_up(dut)
    w, a = gen_pairs(96, sparsity=0.3, seed=50)

    consumed = accel.count_beats()
    await accel.start()
    await accel.send(w, a)

    # Stall first, so the clear cannot race a beat, and so the split point is
    # known exactly rather than inferred from when the AXI write landed.
    while consumed.total < 24:
        await RisingEdge(dut.aclk)
    await accel.write(REG_CTRL, 0)
    await RisingEdge(dut.aclk)
    split = consumed.total

    await accel.write(REG_CTRL, CTRL_CLEAR)
    await RisingEdge(dut.aclk)
    assert await accel.read(REG_ACC) == 0, "accumulator survived a mid-tile clear"
    assert await accel.read(REG_SKIP) == 0, "skip count survived a mid-tile clear"
    assert consumed.total == split, "a beat was consumed while EN was low"

    await accel.write(REG_CTRL, CTRL_EN)
    await accel.await_done()

    exp_acc, exp_skip = golden(w[split:], a[split:])
    assert await accel.read_acc() == exp_acc
    assert await accel.read(REG_SKIP) == exp_skip


@cocotb.test()
async def test_reset_mid_stream(dut):
    """Reset during a tile returns the wrapper to its defined idle state."""
    accel = await bring_up(dut)
    w, a = gen_pairs(512, sparsity=0.0, seed=40)

    await accel.start()
    await accel.send(w, a)
    for _ in range(16):
        await RisingEdge(dut.aclk)

    dut.aresetn.value = 0
    for _ in range(5):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)
    accel.stream.clear()
    await RisingEdge(dut.aclk)

    assert await accel.read(REG_STATUS) == 0, "status not idle after reset"
    assert await accel.read(REG_CTRL) == CTRL_EN, "control register not reset"
    assert await accel.read(REG_ACC) == 0, "accumulator not cleared by reset"
    assert await accel.read(REG_SKIP) == 0, "skip count not cleared by reset"

    # A fresh tile still works.
    w, a = gen_pairs(32, sparsity=0.2, seed=41)
    await check_tile(accel, w, a, "after_reset")


def cycle_pauses():
    """A deterministic stall pattern for the stream source."""
    while True:
        yield from [0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 1, 0]
