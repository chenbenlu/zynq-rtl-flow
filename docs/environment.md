# How the environment works

The path a conforming accelerator takes from a SystemVerilog file to a design
running on the board, and what each stage hands to the next. What a module must
present to be carried along it is
[the accelerator contract](accelerator-contract.md); the vocabulary is
[CONTEXT.md](../CONTEXT.md). The accelerators that happen to occupy it today are
[docs/example-accelerators.md](example-accelerators.md) and are not the subject
of this file.

```
                    rtl/*.sv  ─────────────────────────────┐
                        │                                  │
  ┌─────────────────────┴─────────────────────┐            │
  │  runs anywhere Docker does                │            │
  │                                           │            │
  │  lint ──► sim (cocotb/Verilator) ──► VCD  │            │
  │            │                              │            │
  │            └─► golden model comparison    │            │
  │                                           │            │
  │  coverage        sec (two revisions)      │            │
  └───────────────────────────────────────────┘            │
                                                           │
  ┌────────────────────────────────────────────────────────┴──┐
  │  build host only — AMD toolchain, node-locked licence      │
  │                                                            │
  │  synth (one module, OOC) ──► resource + timing baseline     │
  │                                                            │
  │  impl (block design) ──► routed checkpoint ──► .bit         │
  │                            │                                │
  │                            └──► .xsa ──► boot ──► overlay   │
  └────────────────────────────────────────────────────────────┘
                                                           │
                      board: firmware overlay + three .ko ──┘
```

The line across the middle is the one that matters most when reading this
repository: everything above it is reproducible by anyone with Docker, and
everything below it needs the build host, its licence and — for the last step —
a board on a network segment CI cannot reach. `make regress` is exactly the
part above the line, which is why it is what CI runs.

## Simulation

`make sim` builds each seam with Verilator and runs its cocotb coroutines
through a pytest entry point. Three seams, 31 tests. Each `tb/<dut>/` holds a
pair: `tb_<dut>.py` has the coroutines, `test_<dut>.py` is the pytest entry
using the cocotb 2.x runner (`cocotb_tools.runner.get_runner`).

Two rules shape every seam.

**Tests sit at RTL module boundaries and drive only top-level ports.** A
wrapper's tests never reach inside to the module it wraps: the interface the
wrapper presents is the whole reason it exists, and a test that sampled
internal state would keep passing with that interface broken.

**The reference is a numpy golden model, one per accelerator, under
`tb/model/`.** Every seam that needs it imports the same one rather than
carrying a copy, so the module-level seam and the AXI-level seam cannot drift
into two different opinions of what the accelerator computes. If they ever
disagree, that is a finding, not a maintenance task.

The dump is VCD (`waves=True`), one per seam under `sim/<dut>/dump.vcd`.

## Coverage

`make coverage` writes lcov reports to `sim/coverage/`, plus HTML and an
annotated RTL listing under `rtl_annotated/`.

- **`rtl.info`** — Verilator `--coverage` through `verilator_coverage`. This is
  the hardware signal.
- **`python.info`** — pytest-cov. It measures the *runner*, not the coroutines,
  which execute inside cocotb's embedded interpreter rather than the pytest
  process. Treat it as a sanity check on the harness and nothing more.

The Dev Container ships Coverage Gutters preconfigured to read both files, so
`make coverage` then *"Coverage Gutters: Watch"* colours the RTL in the editor.

## Sequential equivalence

Simulation shows a design passes the tests someone thought to write. `make sec`
proves something stronger: that two revisions produce identical outputs for
*every* input sequence. It is the check a behaviour-preserving change has to
clear — retiming a pipeline, rewriting an operator, restructuring decode logic.

```bash
make sec GOLDEN=HEAD                    # working tree vs last commit
make sec GOLDEN=HEAD~3 REVISED=HEAD     # two commits
make sec GOLDEN=../golden_rtl           # against an out-of-tree checkout
```

`GOLDEN` is the reference, a git revision or a directory holding `rtl/`;
`REVISED` defaults to the working tree. Both sides are materialised under
`sim/sec/{gold,gate}/`, so the check never touches the checkout.

| `SEC_ENGINE` | Tool | Use when |
| --- | --- | --- |
| `eqy` (default) | Yosys `eqy` | The revision keeps the state encoding. Partitions both designs at matching register boundaries and discharges each to SAT — fast, and a failure names the partition that diverged. |
| `miter` | Yosys `miter` + `sby` k-induction | The state encoding changed: an added pipeline stage, a re-encoded FSM. Proves an unbounded sequential miter; a failure drops a counterexample VCD under `sim/sec/work/`. |

`SEC_DEPTH` (default 20) bounds the unrolling.

The `miter` engine zero-initialises every register on both sides. Both
revisions reset synchronously with no RTL init value, so an unconstrained miter
would start the two copies in different arbitrary states and fail at t=0 for
reasons that have nothing to do with equivalence. Zero-init pins them to a
common start, which is also how a Zynq FPGA brings registers up after
configuration.

`make sec` reads RTL, so it cannot see a change made in the block design. The
check for that one is the synthesis checksum — see the conventions in
[CLAUDE.md](../CLAUDE.md).

## Synthesis, implementation and the board

`make synth` synthesises **one module out of context** — no surrounding design,
no I/O buffers — and reports what that module costs and how fast it runs. It is
a measurement, not a step towards a bitstream, and the number it produces is
the input to design questions rather than a gate anything has to pass.

`make impl` builds the real thing. The block design in
[flows/embedded/bd/system.tcl](../flows/embedded/bd/system.tcl) — Zynq PS, AXI
interconnect, an AXI DMA feeding the accelerator's stream, the accelerator's
AXI4-Lite slave on the PS's master port — is placed and routed against the
per-board PL clock target in
[flows/common/boards.sh](../flows/common/boards.sh), with a summary in
`build/<board>/impl/impl_summary.txt`. The design is written as Tcl rather than
a checked-in `.bd` so it is reviewable in a diff and rebuildable from the
repository.

`make bitstream` writes the `.bit` from the routed checkpoint. `make xsa`
exports the hardware handoff — the PS configuration, the address map and the
block design's metadata — which is what FSBL, the PMU firmware and the device
tree are generated from. `make boot` generates those; `make overlay` packages
the bitstream and the generated PL device tree into a firmware overlay, the
thing a running Linux loads through the ZynqMP FPGA manager.

The device-tree nodes are not written by hand. They come from the same hardware
handoff as everything else, so the accelerator's address has one source rather
than a copy in a file someone has to remember to update.

## The PS side

The driver is in two layers, and the split is the contract's
([ADR-0005](adr/0005-the-accelerators-driver-is-in-scope.md),
[driver/README.md](../driver/README.md)):

- **`accel_transport.ko`** knows the contract and nothing above offset `0x00`.
  It moves a tile between memory and the accelerator's stream, which is the
  same job for every conforming accelerator, so it is written once.
- **one register layer per accelerator** owns the platform driver and answers
  what that accelerator's register map says: whether a tile may start, what
  starts it, how to tell it finished, and what a read gives back.

Both are built on the board rather than in a container — the toolchain image
carries no kernel headers and the Vivado image is x86.

## Adding an accelerator

The environment's claim is that a module satisfying the contract gets all of
the above without the environment being modified for it. Concretely:

1. Add `rtl/<module>.sv`, presenting what
   [the accelerator contract](accelerator-contract.md) requires.
2. Write its register map as `docs/register-map-<name>.md`. That document is
   the specification, not a description of what the RTL turned out to do.
3. Add a numpy golden model under `tb/model/`.
4. Add `tb/<module>/tb_<module>.py` and `tb/<module>/test_<module>.py`; copy an
   existing pair and swap `HDL_TOPLEVEL`, `TEST_MODULE` and `SOURCES`.
   `tb/conftest.py` puts each `tb/<module>/` on `sys.path`, so the test module
   resolves regardless of where pytest was invoked.
5. Add the sources to [scripts/rtl_sources.sh](../scripts/rtl_sources.sh) — the
   single list that lint, `make sec` and both synthesis flows all read.
6. Add a register layer under `driver/` against the map from step 2.
7. `make regress`.

Nothing in that list touches the transport layer, the block design or the
overlay generator. Where it turns out that something does, the contract was
incomplete and that is what needs fixing — not the accelerator.
