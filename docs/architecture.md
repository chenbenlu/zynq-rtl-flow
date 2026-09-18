# Architecture & Extension Guide

## What this skeleton is

A minimal but *complete* simulation loop for a sparse CNN accelerator:

```
        rtl/*.sv  ──►  Verilator (compile)  ──►  cocotb test (drive + check)
           ▲                                          │
           │                                          ▼
       Verible lint                      numpy golden model + assertions
           │                                          │
           ▼                                          ▼
     CI (GitHub Actions) ◄──────────────  VCD waveform + coverage report
```

Everything runs inside one pinned Docker image, consumed identically by the Dev
Container and CI (via GHCR).

## The example DUT: `sparse_mac_pe`

A single multiply-accumulate processing element ([rtl/sparse_mac_pe.sv](../rtl/sparse_mac_pe.sv)).
It streams `(weight, activation)` pairs and accumulates their signed products.

The defining sparse-CNN behaviour is **zero-skip**: when either operand is zero,
the multiply-add is suppressed and a `skip_count` is advanced instead. This
models the work a real sparse accelerator avoids, and `skip_count` gives the
testbench a direct observable to confirm skipping is exact.

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

Widths live in [rtl/sparse_cnn_pkg.sv](../rtl/sparse_cnn_pkg.sv) so a future PE
array stays consistent.

## The AXI-wrapped top level: `sparse_cnn_axi`

[rtl/sparse_cnn_axi.sv](../rtl/sparse_cnn_axi.sv) makes the PE addressable by
the Zynq PS. It instantiates `sparse_mac_pe` unmodified and adds two interfaces,
split by data rate:

- **AXI4-Stream slave** — one packed `(activation, weight)` pair per beat,
  backpressured, `tlast` marking the end of a tile. High rate, DMA-fed.
- **AXI4-Lite slave** — control, status and results: one transaction per tile.

Results come back over AXI4-Lite rather than a second stream because the PE
produces one accumulator per tile, not a value per beat; a result stream would
be almost entirely idle and would add an interface for the integrator to wire
up for no throughput benefit.

The full offsets and semantics are in
[docs/register-map-sparse-cnn.md](register-map-sparse-cnn.md), which is the
specification the tests hold the RTL to. In outline: an ID register readable before anything is
written, a control register whose single write starts a tile, a status register
to poll, and latched accumulator and zero-skip registers holding the last
*completed* tile — so a poll loop that reads one cycle early gets a defined
value rather than a partial accumulation.

Everything runs on the PS-sourced AXI clock. There is no clock-domain crossing
in this design.

### The DSP question

The 8-bit multiply infers into LUTs, not a DSP block. That is measured — zero
DSPs on both targets — but measured for the **bare PE**: 100 LUTs, 49 registers,
14 carry cells, no block RAM, 310.7 MHz on KV260 and 395.1 MHz on ZCU104, from
out-of-context synthesis at a 3.0 ns constraint. The wrapper does not change the
arithmetic, so it should not introduce a DSP either, but that is a prediction
until `make synth` runs on the build host with `RTL_TOP=sparse_cnn_axi` and the
number is recorded here.

The choice matters for the PE array that follows: a LUT-bound design scales
differently from a DSP-bound one, and a zero-DSP result is the consequence of an
8-bit operand width rather than an oversight to fix.

## Verification approach

There are two test seams, both at RTL module boundaries, both driven the same
way. Each `tb/<dut>/test_<dut>.py` is a pytest entry point using the cocotb 2.x
Python runner (`cocotb_tools.runner.get_runner`) to build with Verilator and run
the coroutines in the matching `tb_<dut>.py`.

**`sparse_mac_pe`** — raw ports. Each test generates operand streams with numpy
(controllable sparsity), drives one pair per cycle, and checks both `acc` and
`skip_count`. Cases: dense, high-sparsity, all-zero, full-magnitude (no overflow
within `ACC_W`), and mid-stream `clear_acc`.

**`sparse_cnn_axi`** — AXI ports only. Operands go in over AXI4-Stream and
results come back over AXI4-Lite, driven with `cocotbext-axi`. Nothing reaches
inside to the PE: the contract the wrapper presents to the PS is the whole point
of the module, and a test that sampled internal state would pass even with that
contract broken. The PE's cases are ported over, and the seam adds its own:
backpressure from the source and from the wrapper, ready held low before START,
back-to-back tiles, a mid-tile result read, an explicit clear, register accesses
against the documented map, and a reset asserted mid-stream.

[tb/model/sparse_mac_model.py](../tb/model/sparse_mac_model.py) holds the golden
model and the sparsity-controlled operand generator. Both seams import it, so
there is one definition of what the accelerator computes; if the two seams ever
disagree, that is a finding rather than a maintenance task.

### A note on coverage

- **RTL coverage** (Verilator `--coverage` → `verilator_coverage`) is the
  meaningful hardware signal. Report lands in `sim/coverage/`.
- **Python coverage** (pytest-cov) measures the *runner/harness*, not the
  coroutine logic — the coroutines execute inside cocotb's embedded interpreter,
  not the pytest process. Treat it as a sanity check on the harness only.

`make coverage` writes lcov reports to `sim/coverage/` — `rtl.info`
(verilator_coverage) and `python.info` (pytest-cov) — plus HTML and an annotated
RTL listing (`rtl_annotated/`). To see coverage **in the editor gutter**, the
Dev Container ships the **Coverage Gutters** extension
(`ryanluker.vscode-coverage-gutters`): run `make coverage`, then the
*"Coverage Gutters: Watch"* command, and open `rtl/sparse_mac_pe.sv` — covered
lines turn green, uncovered red. It is preconfigured to read both `.info` files
(see `coverage-gutters.*` settings in `.devcontainer/devcontainer.json`).

## Sequential equivalence checking (`make sec`)

Simulation shows that a design passes the tests you thought to write. **SEC**
proves something stronger: that two revisions of the RTL produce identical
outputs for *every* input sequence. That is the check you want when a change is
meant to be behaviour-preserving — retiming a pipeline, rewriting an operator,
restructuring decode logic, or hand-optimising for the ZCU104's DSP48 slices.

```bash
make sec GOLDEN=HEAD                    # working tree vs last commit
make sec GOLDEN=HEAD~3 REVISED=HEAD     # two commits
make sec GOLDEN=../golden_rtl           # against an out-of-tree checkout
```

`GOLDEN` is the reference — a git revision or a directory containing `rtl/`.
`REVISED` defaults to the working tree. Both sides are materialised under
`sim/sec/{gold,gate}/` so the check never mutates your checkout.

### Engines

| `SEC_ENGINE` | Tool | Use when |
| --- | --- | --- |
| `eqy` (default) | Yosys `eqy` | The revision keeps the state encoding. Partitions both designs at matching register boundaries and discharges each to SAT — fast, and a failure names the exact partition that diverged. |
| `miter` | Yosys `miter` + `sby` k-induction | The state encoding changed (added pipeline stage, re-encoded FSM). Proves an unbounded sequential miter; a failure drops a counterexample VCD in `sim/sec/work/engine_0/`. |

`SEC_DEPTH` (default 20) bounds the SAT/BMC unrolling.

The `miter` engine zero-initialises every register on both sides. Both DUT
revisions reset synchronously with no RTL init value, so an unconstrained miter
would start the two copies in *different* arbitrary states and fail at t=0 for
reasons unrelated to equivalence. Zero-init pins them to a common start state,
which is also how a Zynq FPGA brings registers up after configuration.

### Why oss-cad-suite is not on `PATH`

Its `bin/` ships its own `verilator` and `cocotb-config`, which would shadow the
pinned Verilator v5.042 and silently change what `make sim` runs. The image sets
`OSS_CAD_SUITE=/opt/oss-cad-suite` instead, and
[scripts/sec.sh](../scripts/sec.sh) prepends it to `PATH` for its own process
only.

## Extending the skeleton

Deliberately **out of scope** for the foundation (add when actually needed):

1. **PE array** — instantiate a grid of `sparse_mac_pe` with a shared control
   FSM and weight/activation broadcast. Reuse `sparse_cnn_pkg` widths. The AXI
   interface's measured cost per PE is the input to the question of whether the
   array shares one interface or replicates it.
2. **Convolution layer controller** — loop nest / im2col sequencing, line
   buffers, output accumulation.
3. **Zynq PS co-simulation / synthesis** — Verilator simulates the PL only;
   PS interaction is modelled, not executed. Synthesis (Vivado) is a separate
   flow outside this RTL-sim skeleton.

### Adding a new DUT + testbench

1. Add `rtl/<module>.sv` (and any package additions).
2. Add `tb/<module>/tb_<module>.py` (coroutines) and
   `tb/<module>/test_<module>.py` (runner — copy the existing one, swap
   `HDL_TOPLEVEL`, `TEST_MODULE`, and `SOURCES`).
3. Add the new sources to [scripts/rtl_sources.sh](../scripts/rtl_sources.sh)
   — the single list shared by `make lint` and `make sec`.
4. `make regress`.

`tb/conftest.py` auto-adds each `tb/<module>/` directory to `sys.path`, so
cocotb resolves the test module regardless of invocation directory.
