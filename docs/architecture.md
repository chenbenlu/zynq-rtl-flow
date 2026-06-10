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
3. Add the new sources to [scripts/lint.sh](../scripts/lint.sh).
4. `make regress`.

`tb/conftest.py` auto-adds each `tb/<module>/` directory to `sys.path`, so
cocotb resolves the test module regardless of invocation directory.
