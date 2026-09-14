# zynq_cnn

A sparse convolutional neural-network accelerator for AMD Zynq UltraScale+ MPSoC.
This file is the project's glossary: it fixes the vocabulary the RTL, the
testbenches and the synthesis flows all speak. It holds no implementation
details — those live in the code, in `docs/adr/` and in the module READMEs.

## Language

### The design

**Processing Element (PE)**:
One multiply-accumulate unit that skips zero-valued operands. The smallest unit
of the accelerator that can be synthesised and verified on its own.
_Avoid_: MAC unit, core, cell

**Zero-skip**:
Suppressing a multiply-accumulate when an operand is zero. The property that
makes this accelerator *sparse* rather than a plain systolic array.
_Avoid_: sparsity handling, pruning, gating

**Golden model**:
The numpy reference implementation in `tb/<dut>/tb_<dut>.py` that a cocotb
testbench compares the DUT against.
_Avoid_: reference design, oracle, expected model

**Sequential equivalence (SEC)**:
A proof that two revisions of the RTL produce identical outputs for every input
sequence, not merely for the directed tests. The bar a behaviour-preserving RTL
change must clear.
_Avoid_: formal check, regression proof

### The flows

Two distinct paths take RTL to silicon. They differ in their tooling, their
artefacts and what counts as success, so they are never referred to
interchangeably.

**Embedded flow**:
Hand-written SystemVerilog synthesised by Vivado into a bitstream, driven from
the PS by an application that talks to it over AXI. Its artefact is a `.bit`
(or a firmware overlay carrying one). The flow the accelerator's own RTL takes.
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
runtime to bring the accelerator up, rather than configuring the PL at boot.
The mechanism that lets KV260 be programmed without JTAG.
_Avoid_: partial bitstream, DFX, app firmware

### The environment

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
