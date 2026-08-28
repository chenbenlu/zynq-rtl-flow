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

## Verification approach

[tb/sparse_mac_pe/tb_sparse_mac_pe.py](../tb/sparse_mac_pe/tb_sparse_mac_pe.py)
holds the cocotb coroutines. Each test generates operand streams with numpy
(controllable sparsity), drives one pair per cycle, and checks both `acc` and
`skip_count` against a numpy golden model. Cases: dense, high-sparsity, all-zero,
full-magnitude (no overflow within `ACC_W`), and mid-stream `clear_acc`.

[tb/sparse_mac_pe/test_sparse_mac_pe.py](../tb/sparse_mac_pe/test_sparse_mac_pe.py)
is the pytest entry point. It uses the cocotb 2.x Python test runner
(`cocotb_tools.runner.get_runner`) to build with Verilator and run the suite.

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
   FSM and weight/activation broadcast. Reuse `sparse_cnn_pkg` widths.
2. **Convolution layer controller** — loop nest / im2col sequencing, line
   buffers, output accumulation.
3. **AXI interfaces** — wrap the array in AXI-Stream (data) + AXI-Lite
   (control/status) to attach to the Zynq PS. Model these in cocotb with
   `cocotbext-axi` (add to `pyproject.toml`).
4. **Zynq PS co-simulation / synthesis** — Verilator simulates the PL only;
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
