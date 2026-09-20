# The example accelerators

Two accelerators occupy the environment today. They are examples, not the
deliverable ([ADR-0006](adr/0006-the-deliverable-is-the-environment.md)), and
everything in this file goes when they do. How the environment carries them is
[docs/environment.md](environment.md); what it requires of them is
[the accelerator contract](accelerator-contract.md).

They were chosen to be the opposite shapes, because one implementation cannot
distinguish a contract from a description of itself:

| | sparse CNN | Leaky ReLU |
|---|---|---|
| What a tile becomes | one accumulator | one output beat per input beat |
| Results leave over | AXI4-Lite | the stream master |
| A tile starts on | a register write | its first beat |
| AXI4-Lite holds | results | a writable parameter |
| DMA channels used | MM2S | MM2S and S2MM |

The second column is what falsifies the first. Where the environment turned out
to assume something only the sparse CNN does — the overlay generator's DMA
channels, the block design's interconnect width — the ReLU is what exposed it.

## The sparse CNN

### `sparse_mac_pe` — the processing element

A single multiply-accumulate element ([rtl/sparse_mac_pe.sv](../rtl/sparse_mac_pe.sv)).
It streams `(weight, activation)` pairs and accumulates their signed products.

| Port | Dir | Meaning |
|------|-----|---------|
| `clk`, `rst_n` | in | clock, synchronous active-low reset |
| `en` | in | global enable; low freezes all state |
| `clear_acc` | in | synchronous clear of `acc` + `skip_count` (new tile) |
| `valid_in` | in | the operand pair this cycle is valid |
| `weight`, `act` | in | signed `DATA_W` operands |
| `acc` | out | signed `ACC_W` accumulator |
| `valid_out` | out | high the cycle a valid pair was consumed |
| `skip_count` | out | running count of zero-skipped cycles |

The defining behaviour is **zero-skip**: when either operand is zero the
multiply-add is suppressed and `skip_count` advances instead. That models the
work a real sparse accelerator avoids, and it gives the testbench a direct
observable — a count that has to match exactly, rather than an accumulator that
would come out the same either way.

Widths live in [rtl/sparse_cnn_pkg.sv](../rtl/sparse_cnn_pkg.sv) so a future PE
array stays consistent with the single element.

Its seam drives the raw ports: operand streams generated with numpy at a
controlled sparsity, one pair per cycle, checking both `acc` and `skip_count`.
Five cases — dense, high-sparsity, all-zero, full-magnitude (no overflow within
`ACC_W`), and a mid-stream `clear_acc`.

### `sparse_cnn_axi` — the AXI wrapper

[rtl/sparse_cnn_axi.sv](../rtl/sparse_cnn_axi.sv) makes the PE addressable by
the PS. It instantiates `sparse_mac_pe` unmodified, adds no arithmetic of its
own, and presents two interfaces split by data rate: an AXI4-Stream slave
carrying one packed `(activation, weight)` pair per beat with `tlast` marking
the end of a tile, and an AXI4-Lite slave carrying control, status and results
at one transaction per tile.

Results come back over AXI4-Lite rather than a second stream because the PE
produces one accumulator per tile, not a value per beat. A result stream would
be idle almost all the time and would add an interface for the integrator to
wire up for no throughput gained.

[docs/register-map-sparse-cnn.md](register-map-sparse-cnn.md) is the
specification the tests hold the RTL to. In outline: an ID register readable
before anything is written, a control register whose single write starts a
tile, a status register to poll, and latched accumulator and skip-count
registers holding the last *completed* tile — so a poll loop that reads one
cycle early gets a defined value rather than a partial accumulation.

Its seam drives AXI ports only, fifteen cases: the PE's cases ported over,
plus backpressure from the source and from the wrapper, ready held low before
START, back-to-back tiles, a mid-tile result read, an explicit clear, register
accesses against the documented map, and a reset asserted mid-stream.

### The DSP question

The 8-bit multiply infers into LUTs, not a DSP block. That is measured, and
measured for the **bare PE**: 100 LUTs, 49 registers, 14 carry cells, no block
RAM, 310.7 MHz on KV260 and 395.1 MHz on ZCU104, from out-of-context synthesis
at a 3.0 ns constraint. The wrapper adds no arithmetic, so it should not
introduce a DSP either — but that is a prediction until `make synth
RTL_TOP=sparse_cnn_axi` runs on the build host and the number is recorded here.

It matters for the PE array that would follow. A LUT-bound design scales
differently from a DSP-bound one, and a zero-DSP result is the consequence of
an 8-bit operand width rather than an oversight to fix.

## The Leaky ReLU

### `relu_unit`

`y = x` for `x >= 0`, `y = x * slope` for `x < 0`
([rtl/relu_unit.sv](../rtl/relu_unit.sv)). The slope is unsigned Q0.8 — the
fraction `slope/256` — so the negative branch is a multiply and an arithmetic
shift, and the shift truncates towards minus infinity. That truncation is the
definition rather than an approximation of one: the golden model truncates the
same way and the two are compared exactly.

The unit is combinational. The pipeline register and the backpressure that goes
with it belong to the wrapper, which is the only part that knows when a beat
may be accepted.

Widths are in [rtl/relu_pkg.sv](../rtl/relu_pkg.sv), including the reset slope
— 25/256 ≈ 0.098, the usual leaky-ReLU coefficient rounded to the fraction this
width can hold.

### `relu_axi`

[rtl/relu_axi.sv](../rtl/relu_axi.sv) carries the contract's **optional
AXI4-Stream master**, so the block design gives it the DMA's S2MM channel as
well as MM2S. Its AXI4-Lite slave holds a writable parameter rather than only
results, which is the direction `sparse_cnn_axi` never exercises.
[docs/register-map-relu.md](register-map-relu.md) is its specification; only
offset `0x00` is shared with the other accelerator, and that is the point of
the ID register.

There is no START. A tile begins when its first beat arrives and ends on
`tlast`, and `COUNT` reports how many beats the last completed one held. That
counter is not decoration: a completed AXI DMA descriptor reports no residue,
so a receive transfer that ended early is indistinguishable from one that
filled the buffer, and `COUNT` is what the driver reads the result's length
from.

`SLOPE` is writable while a tile is in flight, and the accelerator applies the
write on the next beat it accepts rather than deferring it to the next tile.
The driver exposes it as a sysfs attribute held against the tile path for that
reason.

Eleven cases in its seam, covering the register map, the tile boundary,
back-to-back tiles, enable withdrawing `ready`, and backpressure preserving the
tile.

## Golden models

[tb/model/sparse_mac_model.py](../tb/model/sparse_mac_model.py) holds the
sparse MAC's reference and its sparsity-controlled operand generator;
[tb/model/relu_model.py](../tb/model/relu_model.py) holds the ReLU's. Each is
imported by every seam that needs it and copied into none, so there is one
definition per accelerator of what it computes.

## What is deliberately not here

Out of scope for the example, to be added when something actually needs it:

1. **A PE array** — a grid of `sparse_mac_pe` with a shared control FSM and
   weight/activation broadcast, reusing `sparse_cnn_pkg` widths. The AXI
   interface's measured cost per PE is the input to the question of whether the
   array shares one interface or replicates it.
2. **A convolution layer controller** — loop-nest / im2col sequencing, line
   buffers, output accumulation.
3. **PS co-simulation** — Verilator simulates the PL only. PS interaction is
   modelled in the testbench and executed on the board, not simulated in
   between.
