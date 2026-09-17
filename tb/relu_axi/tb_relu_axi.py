"""cocotb tests for relu_axi — the Leaky ReLU accelerator.

The second implementation of the accelerator contract, and the one that is not
shaped like the first: it transforms a tile beat by beat instead of reducing it,
so its results come back on an AXI4-Stream master rather than out of a register,
and its AXI4-Lite slave holds a parameter software writes rather than only
values it reads.

Everything here drives the top-level ports. The golden model is imported from
``tb/model/relu_model.py``.
"""

from __future__ import annotations

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge
from cocotbext.axi import (
    AxiLiteBus,
    AxiLiteMaster,
    AxiStreamBus,
    AxiStreamFrame,
    AxiStreamSink,
    AxiStreamSource,
)

from relu_model import (
    DATA_MASK,
    DATA_W,
    SLOPE_RESET,
    gen_activations,
    golden,
    to_signed,
)

CLK_PERIOD_NS = 10

# The register map documented in docs/register-map-relu.md. These constants are
# the specification the tests hold the RTL to, not a copy of it.
REG_ID = 0x00
REG_CTRL = 0x04
REG_STATUS = 0x08
REG_SLOPE = 0x0C
REG_COUNT = 0x10

CTRL_EN = 1 << 0

STATUS_BUSY = 1 << 0
STATUS_DONE = 1 << 1

ID_EXPECTED = 0x524C0100

POLL_LIMIT = 10_000


class Accelerator:
    """Driver for the accelerator's three interfaces."""

    def __init__(self, dut):
        self.dut = dut
        self.axil = AxiLiteMaster(
            AxiLiteBus.from_prefix(dut, "s_axi"),
            dut.aclk,
            dut.aresetn,
            reset_active_level=False,
        )
        self.source = AxiStreamSource(
            AxiStreamBus.from_prefix(dut, "s_axis"),
            dut.aclk,
            dut.aresetn,
            reset_active_level=False,
            byte_size=DATA_W,
        )
        self.sink = AxiStreamSink(
            AxiStreamBus.from_prefix(dut, "m_axis"),
            dut.aclk,
            dut.aresetn,
            reset_active_level=False,
            byte_size=DATA_W,
        )

    async def read(self, addr: int) -> int:
        return int.from_bytes(await self.axil.read(addr, 4), "little")

    async def write(self, addr: int, value: int) -> None:
        await self.axil.write(addr, int(value).to_bytes(4, "little"))

    async def send_tile(self, activations) -> None:
        """One frame is one tile: cocotbext asserts tlast on its final beat."""
        raw = [int(v) & DATA_MASK for v in activations]
        await self.source.send(AxiStreamFrame(raw))

    async def recv_tile(self) -> list[int]:
        frame = await self.sink.recv()
        return [to_signed(v) for v in frame.tdata]

    async def run_tile(self, activations) -> list[int]:
        await self.send_tile(activations)
        return await self.recv_tile()

    async def await_done(self) -> None:
        for _ in range(POLL_LIMIT):
            if await self.read(REG_STATUS) & STATUS_DONE:
                return
        raise AssertionError("DONE never rose")


class LastMonitor:
    """Records tlast on every beat the master hands over.

    A frame that arrives at all proves a tlast arrived somewhere; this is what
    proves it arrived on the *last* beat and on no other.
    """

    def __init__(self):
        self.flags: list[int] = []

    async def run(self, dut) -> None:
        while True:
            await RisingEdge(dut.aclk)
            await ReadOnly()
            if dut.m_axis_tvalid.value == 1 and dut.m_axis_tready.value == 1:
                self.flags.append(int(dut.m_axis_tlast.value))


async def reset(dut) -> Accelerator:
    cocotb.start_soon(Clock(dut.aclk, CLK_PERIOD_NS, unit="ns").start())
    dut.aresetn.value = 0
    dut.s_axis_tvalid.value = 0
    dut.m_axis_tready.value = 0
    for _ in range(5):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    await RisingEdge(dut.aclk)
    return Accelerator(dut)


@cocotb.test()
async def test_id_reads_before_any_write(dut):
    """The contract's probe: offset 0x00 identifies the design from reset."""
    accel = await reset(dut)
    assert await accel.read(REG_ID) == ID_EXPECTED


@cocotb.test()
async def test_reset_values(dut):
    """Enabled, with the documented default slope, before software touches it."""
    accel = await reset(dut)
    assert await accel.read(REG_CTRL) & CTRL_EN
    assert await accel.read(REG_SLOPE) == SLOPE_RESET
    assert await accel.read(REG_COUNT) == 0
    assert await accel.read(REG_STATUS) == 0


@cocotb.test()
async def test_unmapped_offset_reads_zero(dut):
    """The contract: an unmapped offset reads zero and answers OKAY.

    A driver probes before it knows what it is talking to, so an error response
    here would be within AXI and outside the contract.
    """
    accel = await reset(dut)
    assert await accel.read(0x40) == 0


@cocotb.test()
async def test_default_slope_matches_the_model(dut):
    """A tile through the accelerator is the golden model's output, exactly."""
    accel = await reset(dut)
    tile = gen_activations(64, rng=np.random.default_rng(1))
    expected = golden(tile)

    got = await accel.run_tile(tile)

    assert got == list(expected), f"got {got[:8]}, expected {list(expected[:8])}"


@cocotb.test()
async def test_slope_is_writable(dut):
    """The register a driver writes changes the arithmetic.

    sparse_cnn_axi has no writable field that reaches its data path, so this is
    the direction of the AXI4-Lite interface the first accelerator never
    exercises.
    """
    accel = await reset(dut)
    tile = gen_activations(48, negative_ratio=0.9, rng=np.random.default_rng(2))

    for slope in (0, 1, 128, 255):
        await accel.write(REG_SLOPE, slope)
        assert await accel.read(REG_SLOPE) == slope

        got = await accel.run_tile(tile)
        assert got == list(golden(tile, slope)), f"slope {slope}"


@cocotb.test()
async def test_slope_is_eight_bits(dut):
    """Bits above the field are not storage: they read back as zero."""
    accel = await reset(dut)
    await accel.write(REG_SLOPE, 0xDEADBE07)
    assert await accel.read(REG_SLOPE) == 0x07


@cocotb.test()
async def test_tlast_marks_the_tile(dut):
    """The tile boundary travels with the data, and marks one beat only."""
    accel = await reset(dut)
    monitor = LastMonitor()
    cocotb.start_soon(monitor.run(dut))
    tile = gen_activations(16, rng=np.random.default_rng(3))

    values = await accel.run_tile(tile)

    assert len(values) == len(tile)
    assert monitor.flags == [0] * (len(tile) - 1) + [1], monitor.flags


@cocotb.test()
async def test_status_and_count_report_the_tile(dut):
    """BUSY spans the pipeline, DONE follows it, COUNT is the tile's length."""
    accel = await reset(dut)
    tile = gen_activations(32, rng=np.random.default_rng(4))

    await accel.send_tile(tile)
    await RisingEdge(dut.aclk)
    assert await accel.read(REG_STATUS) & STATUS_BUSY, "BUSY did not rise with the tile"

    values = await accel.recv_tile()
    await accel.await_done()

    status = await accel.read(REG_STATUS)
    assert not status & STATUS_BUSY
    assert status & STATUS_DONE
    assert await accel.read(REG_COUNT) == len(tile) == len(values)


@cocotb.test()
async def test_two_tiles_back_to_back(dut):
    """A second tile is accounted separately from the first."""
    accel = await reset(dut)
    rng = np.random.default_rng(5)

    for length in (8, 40):
        tile = gen_activations(length, rng=rng)
        got = await accel.run_tile(tile)
        await accel.await_done()

        assert got == list(golden(tile))
        assert await accel.read(REG_COUNT) == length


@cocotb.test()
async def test_enable_low_withdraws_ready(dut):
    """The contract: ready is asserted only when the beat will be consumed."""
    accel = await reset(dut)
    await accel.write(REG_CTRL, 0)

    dut.s_axis_tvalid.value = 1
    dut.s_axis_tdata.value = 0x7F
    for _ in range(8):
        await RisingEdge(dut.aclk)
        await ReadOnly()
        assert dut.s_axis_tready.value == 0, "ready rose while disabled"
    await RisingEdge(dut.aclk)
    dut.s_axis_tvalid.value = 0

    await accel.write(REG_CTRL, CTRL_EN)
    tile = gen_activations(12, rng=np.random.default_rng(6))
    assert await accel.run_tile(tile) == list(golden(tile))


@cocotb.test()
async def test_backpressure_preserves_the_tile(dut):
    """A stalled consumer delays the tile and changes nothing about it."""
    accel = await reset(dut)
    tile = gen_activations(64, rng=np.random.default_rng(7))

    accel.sink.pause = True
    await accel.send_tile(tile)
    for _ in range(50):
        await RisingEdge(dut.aclk)
    accel.sink.pause = False

    values = await accel.recv_tile()
    assert values == list(golden(tile))
