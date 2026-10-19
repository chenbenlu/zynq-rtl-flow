# How the environment works

The path a conforming accelerator takes from a SystemVerilog file to a design
running on the board, and what each stage hands to the next. What a module must
present is [the accelerator contract](accelerator-contract.md); the vocabulary
is [CONTEXT.md](../CONTEXT.md); the accelerators in it today are in
[example-accelerators.md](example-accelerators.md).

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

The line across the middle is the one that matters. Everything above it is
reproducible by anyone with Docker. Everything below needs the build host, its
licence and — for the last step — a board on a network segment CI cannot reach.
`make regress` is exactly the part above the line, which is why CI runs it.

## Simulation

`make sim` builds each seam with Verilator and runs its cocotb coroutines
through pytest: three seams, 31 tests. Each `tb/<dut>/` holds a pair —
`tb_<dut>.py` (coroutines) and `test_<dut>.py` (pytest entry, cocotb 2.x
runner `cocotb_tools.runner.get_runner`).

Two rules shape every seam:

- **Tests sit at RTL module boundaries and drive only top-level ports.** A
  wrapper's tests never reach inside the module it wraps: the wrapper's
  interface is why it exists, and a test that sampled internal state would keep
  passing with that interface broken.
- **The reference is a numpy golden model under `tb/model/`, one per
  accelerator.** Every seam imports the same one rather than a copy, so the
  module-level and AXI-level seams cannot drift into two opinions of what the
  accelerator computes. If they disagree, that is a finding, not a maintenance
  task.

The dump is VCD (`waves=True`), one per seam at `sim/<dut>/dump.vcd`.

## Coverage

`make coverage` writes lcov reports to `sim/coverage/`, plus HTML and an
annotated RTL listing under `rtl_annotated/`.

| File | Source | Meaning |
| --- | --- | --- |
| `rtl.info` | Verilator `--coverage` via `verilator_coverage` | The hardware signal. |
| `python.info` | pytest-cov | Measures the *runner* only — the coroutines run inside cocotb's embedded interpreter, not the pytest process. A sanity check on the harness, nothing more. |

The Dev Container ships Coverage Gutters configured for both files:
`make coverage`, then *"Coverage Gutters: Watch"* colours the RTL in the editor.

## Sequential equivalence

Simulation shows a design passes the tests someone wrote. `make sec` proves two
revisions produce identical outputs for *every* input sequence. It is the check
a behaviour-preserving change must clear — retiming a pipeline, rewriting an
operator, restructuring decode logic.

```bash
make sec GOLDEN=HEAD                    # working tree vs last commit
make sec GOLDEN=HEAD~3 REVISED=HEAD     # two commits
make sec GOLDEN=../golden_rtl           # against an out-of-tree checkout
```

`GOLDEN` is the reference: a git revision or a directory holding `rtl/`.
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
reasons unrelated to equivalence. Zero-init gives them a common start — also
how a Zynq FPGA brings registers up after configuration.

`make sec` reads RTL, so it cannot see a block-design change. That one is
checked by the synthesis checksum — see the conventions in
[CLAUDE.md](../CLAUDE.md).

## Synthesis, implementation and the board

| Target | Does | Produces |
| --- | --- | --- |
| `make synth` | Synthesises **one module out of context** — no surrounding design, no I/O buffers. | What the module costs and how fast it runs. A measurement feeding design questions, not a step towards a bitstream or a gate. |
| `make impl` | Places and routes the block design in [flows/embedded/bd/system.tcl](../flows/embedded/bd/system.tcl) — Zynq PS, AXI interconnect, an AXI DMA feeding the accelerator's stream, the accelerator's AXI4-Lite slave on the PS's master port — against the per-board PL clock target in [flows/common/boards.sh](../flows/common/boards.sh). | Routed checkpoint; summary in `build/<board>/impl/impl_summary.txt`. |
| `make bitstream` | Writes the bitstream from the routed checkpoint. | `.bit` |
| `make xsa` | Exports the hardware handoff: PS configuration, address map, block-design metadata. | `.xsa`, the source FSBL, PMU firmware and device tree are generated from. |
| `make boot` | Generates boot firmware from the handoff. | FSBL, PMU firmware, device tree. |
| `make overlay` | Packages the bitstream and generated PL device tree. | A firmware overlay, loaded by running Linux through the ZynqMP FPGA manager. |

The block design is Tcl rather than a checked-in `.bd` so it is reviewable in a
diff and rebuildable from the repository.

Device-tree nodes are generated from the same hardware handoff, not written by
hand, so the accelerator's address has one source rather than a copy someone
must remember to update.

## The PS side

The driver has two layers, split along the contract
([ADR-0005](adr/0005-the-accelerators-driver-is-in-scope.md),
[driver/README.md](../driver/README.md)):

- **`accel_transport.ko`** knows the contract and nothing above offset `0x00`.
  It moves a tile between memory and the accelerator's stream — the same job
  for every conforming accelerator, so it is written once.
- **One register layer per accelerator** owns the platform driver and
  implements that accelerator's register map: whether a tile may start, what
  starts it, how to tell it finished, what a read returns.

Both are built on the board, not in a container: the toolchain image has no
kernel headers and the Vivado image is x86.

## Adding an accelerator

The environment's claim: a module satisfying the contract gets all of the above
without the environment being modified for it. The contract covers the hardware
boundary; steps 2–6 are what every design supplies for itself.

1. Add `rtl/<module>.sv`, presenting what
   [the accelerator contract](accelerator-contract.md) requires.
2. Write its register map as `docs/register-map-<name>.md`, in the shape of
   [register-map-sparse-cnn.md](register-map-sparse-cnn.md). It is the
   specification, not a description of what the RTL turned out to do: the
   testbench checks the RTL against it, so where they disagree the RTL is wrong.
3. Add a numpy golden model under `tb/model/`, imported by every seam that
   verifies the design and never copied into one.
4. Add `tb/<module>/tb_<module>.py` and `tb/<module>/test_<module>.py`,
   driving only top-level ports. Copy an existing pair and swap `HDL_TOPLEVEL`,
   `TEST_MODULE` and `SOURCES`. `tb/conftest.py` puts each `tb/<module>/` on
   `sys.path`, so the test module resolves wherever pytest was invoked.
5. Add the sources to [scripts/rtl_sources.sh](../scripts/rtl_sources.sh) — the
   single list lint, `make sec` and both synthesis flows read.
6. If it is to be driven from Linux, add a register layer under `driver/`
   against the map from step 2. The transport that moves its tiles comes with
   the contract; what binds to its `compatible` string and reads its registers
   does not. See [driver/README.md](../driver/README.md).
7. `make regress`.

Nothing here touches the transport layer, the block design or the overlay
generator. If something turns out to, the contract was incomplete — fix the
contract, not the accelerator.
