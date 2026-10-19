# The example accelerators

Two accelerators occupy the environment today. They are examples, not the
deliverable ([ADR-0006](adr/0006-the-deliverable-is-the-environment.md)), and
this file goes when they do. How the environment carries them is
[environment.md](environment.md); what it requires of them is
[the accelerator contract](accelerator-contract.md).

They are opposite shapes on purpose: one implementation cannot distinguish a
contract from a description of itself.

| | sparse CNN | Leaky ReLU |
|---|---|---|
| What a tile becomes | one accumulator | one output beat per input beat |
| Results leave over | AXI4-Lite | the stream master |
| A tile starts on | a register write | its first beat |
| AXI4-Lite holds | results | a writable parameter |
| DMA channels used | MM2S | MM2S and S2MM |

The second column falsifies the first. Where the environment assumed something
only the sparse CNN does — the overlay generator's DMA channels, the block
design's interconnect width — the ReLU exposed it.

## The sparse CNN

### `sparse_mac_pe` — the processing element

A single multiply-accumulate element ([rtl/sparse_mac_pe.sv](../rtl/sparse_mac_pe.sv))
that streams `(weight, activation)` pairs and accumulates their signed products.

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
multiply-add is suppressed and `skip_count` advances instead. It models the
work a real sparse accelerator avoids, and gives the testbench a count that
must match exactly — an accumulator would come out the same either way.

Widths live in [rtl/sparse_cnn_pkg.sv](../rtl/sparse_cnn_pkg.sv) so a future PE
array stays consistent with the single element.

Its seam drives the raw ports with numpy operand streams at a controlled
sparsity, one pair per cycle, checking both `acc` and `skip_count`. Five cases:
dense, high-sparsity, all-zero, full-magnitude (no overflow within `ACC_W`),
and a mid-stream `clear_acc`.

### `sparse_cnn_axi` — the AXI wrapper

[rtl/sparse_cnn_axi.sv](../rtl/sparse_cnn_axi.sv) makes the PE addressable by
the PS. It instantiates `sparse_mac_pe` unmodified, adds no arithmetic, and
presents two interfaces split by data rate:

- an AXI4-Stream slave: one packed `(activation, weight)` pair per beat, `tlast`
  ending a tile;
- an AXI4-Lite slave: control, status and results, one transaction per tile.

Results return over AXI4-Lite rather than a second stream because the PE
produces one accumulator per tile, not a value per beat. A result stream would
sit idle almost all the time and add an interface to wire up for no throughput.

[register-map-sparse-cnn.md](register-map-sparse-cnn.md) is the specification.
In outline: an ID register, a control register whose single write starts a
tile, a status register to poll, and latched accumulator and skip-count
registers holding the last *completed* tile.

Its seam drives AXI ports only, fifteen cases: the PE's cases ported over, plus
backpressure from the source and from the wrapper, ready held low before START,
back-to-back tiles, a mid-tile result read, an explicit clear, register accesses
against the documented map, and a reset asserted mid-stream.

### The DSP question

The 8-bit multiply infers into LUTs, not a DSP block. Measured for the **bare
PE**, out-of-context at a 3.0 ns constraint:

| | LUTs | Registers | Carry cells | Block RAM | Fmax |
|---|---|---|---|---|---|
| KV260 | 100 | 49 | 14 | 0 | 310.7 MHz |
| ZCU104 | 100 | 49 | 14 | 0 | 395.1 MHz |

The wrapper adds no arithmetic, so it should not introduce a DSP either — but
that is a prediction until `make synth RTL_TOP=sparse_cnn_axi` runs on the
build host and the number is recorded here.

It matters for the PE array that would follow: a LUT-bound design scales
differently from a DSP-bound one. Zero DSPs is the consequence of an 8-bit
operand width, not an oversight to fix.

## The Leaky ReLU

### `relu_unit`

`y = x` for `x >= 0`, `y = x * slope` for `x < 0`
([rtl/relu_unit.sv](../rtl/relu_unit.sv)). The slope is unsigned Q0.8 — the
fraction `slope/256` — so the negative branch is a multiply and an arithmetic
shift, truncating towards minus infinity. That truncation is the definition,
not an approximation: the golden model truncates the same way and the two are
compared exactly.

The unit is combinational. The pipeline register and its backpressure belong to
the wrapper, the only part that knows when a beat may be accepted.

Widths are in [rtl/relu_pkg.sv](../rtl/relu_pkg.sv), including the reset slope
— 25/256 ≈ 0.098, the usual leaky-ReLU coefficient rounded to the fraction this
width can hold.

### `relu_axi`

[rtl/relu_axi.sv](../rtl/relu_axi.sv) carries the contract's **optional
AXI4-Stream master**, so the block design gives it the DMA's S2MM channel as
well as MM2S. Its AXI4-Lite slave holds a writable parameter, the direction
`sparse_cnn_axi` never exercises. [register-map-relu.md](register-map-relu.md)
is its specification; only offset `0x00` is shared with the other accelerator,
which is the point of the ID register.

There is no START: a tile begins when its first beat arrives and ends on
`tlast`. `COUNT` reports how many beats the last completed tile held, and the
driver reads the result's length from it — a completed AXI DMA descriptor
reports no residue, so a receive transfer that ended early is
indistinguishable from one that filled the buffer.

`SLOPE` is writable mid-tile and applies from the next beat accepted, not the
next tile. The driver therefore exposes it as a sysfs attribute held against
the tile path.

Its seam has eleven cases: the register map, the tile boundary, back-to-back
tiles, enable withdrawing `ready`, and backpressure preserving the tile.

## Golden models

[tb/model/sparse_mac_model.py](../tb/model/sparse_mac_model.py) holds the
sparse MAC's reference and its sparsity-controlled operand generator;
[tb/model/relu_model.py](../tb/model/relu_model.py) holds the ReLU's.

## Not here, deliberately

Added when something needs it:

1. **A PE array** — a grid of `sparse_mac_pe` with a shared control FSM and
   weight/activation broadcast, reusing `sparse_cnn_pkg` widths. The AXI
   interface's measured cost per PE decides whether the array shares one
   interface or replicates it.
2. **A convolution layer controller** — loop-nest / im2col sequencing, line
   buffers, output accumulation.
3. **PS co-simulation** — Verilator simulates the PL only. PS interaction is
   modelled in the testbench and executed on the board, not simulated in
   between.
