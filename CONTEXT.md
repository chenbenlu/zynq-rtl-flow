# zynq_cnn

An environment that carries a hand-written accelerator from RTL to a running
design on an AMD Zynq UltraScale+ MPSoC, and one accelerator that goes through
it. This file is the project's glossary: it fixes the vocabulary the RTL, the
testbenches and the synthesis flows all speak. It holds no implementation
details — those live in the code, in `docs/adr/` and in the module READMEs.

The two halves below have different lifetimes. The environment's language is
permanent; the example design's language is replaced whenever the example is —
see [ADR-0006](docs/adr/0006-the-deliverable-is-the-environment.md).

## The environment

### The contract

**Accelerator contract**:
What a module must present at its boundary for this repository's flows to carry
it all the way to the board, specified in
[docs/accelerator-contract.md](docs/accelerator-contract.md). Held by port
names, widths and that document — never by the type system.
_Avoid_: interface spec, wrapper API, socket

**Conforming accelerator**:
A module that satisfies the contract, and therefore one this environment can
simulate, synthesise, implement, package and drive without being modified for
it.
_Avoid_: DUT, IP core, user design

**Tile**:
One run of stream beats that a conforming accelerator treats as a unit, from
its first beat to the beat carrying `tlast`. The unit a PS-side driver submits.
_Avoid_: batch, job, transfer, frame

**Register map**:
The AXI4-Lite offsets, fields and semantics of one conforming accelerator,
specified in a document under `docs/`. The document is the specification; that
accelerator's RTL and its testbench both answer to it.
_Avoid_: CSR layout, register file, control interface

**Golden model**:
The numpy reference implementation an accelerator's cocotb seams compare their
DUT against. One definition per accelerator, imported by each seam, never
copied into one.
_Avoid_: reference design, oracle, expected model

**Sequential equivalence (SEC)**:
A proof that two revisions of the RTL produce identical outputs for every input
sequence, not merely for the directed tests. The bar a behaviour-preserving RTL
change must clear.
_Avoid_: formal check, regression proof

### The PS side

**PS-side driver**:
The software on the board's processing system that operates an accelerator. In
scope for this repository; the boot image that brings the board up is not —
[ADR-0005](docs/adr/0005-the-accelerators-driver-is-in-scope.md).
_Avoid_: host driver, kernel driver, ROS node, application

**Transport layer**:
The half of the driver that moves a tile between memory and the accelerator's
stream. Generic across accelerators, and therefore a candidate for adoption
rather than authorship.
_Avoid_: DMA driver, data path

**Register layer**:
The half of the driver that reads and writes one accelerator's registers. Held
to that accelerator's register map, and replaced with it.
_Avoid_: control path, register interface

### The flows

Two distinct paths take RTL to silicon. They differ in their tooling, their
artefacts and what counts as success, so they are never referred to
interchangeably.

**Embedded flow**:
Hand-written SystemVerilog synthesised by Vivado into a bitstream, driven from
the PS by software that talks to it over AXI. Its artefact is a `.bit` (or a
firmware overlay carrying one). The flow a conforming accelerator takes.
_Avoid_: classic flow, traditional flow, Vivado flow

**Acceleration flow**:
A kernel compiled by Vitis HLS into a `.xo`, linked by `v++` against a platform
into a `.xclbin`, and loaded at runtime by XRT on the board. Its artefact is a
`.xclbin`. The flow used to obtain an HLS-derived comparison point.
_Avoid_: Vitis flow, XRT flow, OpenCL flow

**Out-of-context (OOC) synthesis**:
Synthesising one module with no surrounding design and no I/O buffers, to obtain
a resource and timing baseline for that module alone. Not a step towards a
bitstream — a measurement.
_Avoid_: standalone synth, module synth

**Platform**:
The packaged hardware/software base an acceleration-flow kernel is linked
against — PS configuration, clocks, memory interfaces and the runtime that
exposes them. Belongs to the acceleration flow only.
_Avoid_: shell, base design, BSP

**Firmware overlay**:
The bitstream plus device-tree fragment that Linux on the board loads at
runtime to bring an accelerator up, rather than configuring the PL at boot.
_Avoid_: partial bitstream, DFX, app firmware

### The machines

**Toolchain image**:
The pinned container holding the simulation tools (Verilator, cocotb, Verible).
Self-contained and published to GHCR.
_Avoid_: dev image, sim container

**Vivado image**:
The container holding the AMD toolchain's *runtime dependencies* only. The
toolchain itself is not inside it — see [ADR-0001](docs/adr/0001-vivado-installed-on-persistent-disk.md).
Never published to a registry.
_Avoid_: synthesis image, Xilinx image

**Build host**:
`RTXWS`, the x86 workstation the Vivado image runs on. The only machine where
synthesis, implementation and board programming happen.
_Avoid_: server, rtx, workstation

## The example design

The language of the accelerator that currently occupies the environment. These
terms go when it does; nothing in the environment depends on them.

**Processing Element (PE)**:
One multiply-accumulate unit that skips zero-valued operands. The smallest unit
of the accelerator that can be synthesised and verified on its own.
_Avoid_: MAC unit, core, cell

**Zero-skip**:
Suppressing a multiply-accumulate when an operand is zero. The property that
makes this accelerator *sparse* rather than a plain systolic array.
_Avoid_: sparsity handling, pruning, gating

**AXI wrapper**:
`sparse_cnn_axi`, the top level that makes the PE addressable by the PS. It
instantiates the PE unmodified and adds no arithmetic of its own. The
contract's first implementation.
_Avoid_: AXI shim, bus adapter, IP core
