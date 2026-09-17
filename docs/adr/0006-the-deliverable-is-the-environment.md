# The deliverable is the environment, not the accelerator

[ADR-0004](0004-zcu104-is-this-projects-board.md) justified inheriting the
ZCU104 with the sentence "`zynq_cnn` exists to put a sparse CNN accelerator in
programmable logic; the PL is the deliverable, not a resource to find a use
for". That is no longer what this repository is for. The deliverable is the
environment that carries a hand-written accelerator from RTL to a running
design on the board; the sparse MAC accelerator is its first example, and
`relu_unit` will be its second.

## What forced the question

Not a change of taste — a division of labour that already exists.

[FINN](https://xilinx.github.io/finn/) is AMD Research's dataflow compiler for
quantized neural networks. Its input is a network trained in Brevitas and
exported through QONNX; it generates the accelerator, builds the bitstream and
ships worked examples for this class of board. It does **not** accept
hand-written SystemVerilog. Anything this repository produced as "another
sparse CNN accelerator" would be competing with a tool that does it end to end
and better.

What FINN does not do is serve RTL it did not generate. There is no equivalent
path that takes a module somebody wrote by hand and carries it through
simulation, lint, sequential equivalence, out-of-context synthesis, a block
design, implementation, a firmware overlay and a PS-side driver. That gap is
what this repository already fills, accidentally, as a by-product of getting
one accelerator onto a board. Naming it as the deliverable costs almost nothing
and changes what "done" means.

## What this supersedes

Only ADR-0004's account of the project's purpose. Its decision — that this
project inherits the ZCU104 and that the PS side is not ours to build — stands,
and so does its reasoning about the two boards, the network topology and the
inherited rootfs. ADR-0004 is marked `partially superseded` rather than
rewritten: its most valuable paragraph is the one recording that `amr_simulate`
went looking for a reason to use an idle board, and a repository that edits its
own reasoning out of the record cannot make that point.

## A correction to ADR-0005

[ADR-0005](0005-the-accelerators-driver-is-in-scope.md) decided to write the
accelerator's driver, and weighed two alternatives: reserving a memory window
at boot, and installing a third-party contiguous-buffer module to poke the DMA
from userspace. It did not weigh the closest prior art, which is neither of
those.

[Xilinx's dma-proxy](https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/1027702787/Linux+DMA+From+User+Space+2.0)
and [`bperez77/xilinx_axidma`](https://github.com/bperez77/xilinx_axidma) (MIT)
are dmaengine clients that allocate through CMA — the shape ADR-0005 chose to
write from scratch, already written. They avoid `/dev/mem` for the data path
entirely, which is exactly the constraint `CONFIG_STRICT_DEVMEM=y` imposes.
Neither touches an accelerator's own AXI4-Lite registers; that half stays ours
and is reachable from userspace, as ADR-0005 established.

So the driver splits along the same line the contract does. Its transport layer
is generic and should be adopted rather than written, subject to one
measurement: `xilinx_axidma` documents support for 4.x Xilinx kernels and this
board runs `5.15.0-1015-xilinx-zynqmp`. Its register layer is per-design and
stays here. ADR-0005's conclusion — that the driver is in scope — is unchanged;
its premise that all of it had to be written is not.

## Considered and rejected

**[ESP](https://www.esp.cs.columbia.edu/docs/)** (Columbia) is the mature
version of what the accelerator contract here describes: a documented
accelerator socket, generated wrappers, DMA and interrupt as platform services,
three design flows converging on one integration flow, silicon-validated. It
integrates an accelerator by generating an entire SoC — NoC and processor tiles
included. This board's PS is already running an operating system that ADR-0004
put out of scope. Adopting ESP would mean replacing it. Its accelerator
specification is worth reading when this contract grows; its integration flow
is not available to us.

**PYNQ** allocates physically contiguous buffers in kernel space — historically
`xlnk`, now XRT's `zocl` on ZynqMP — with the CMA limit fixed at kernel build
time. On an inherited kernel that is another out-of-tree module compiled on the
board, which is the price of the option this ADR already recommends, plus a
Python runtime and a rootfs this project cannot reflash. Rejected for cost
structure, not for quality.

## Consequences

The accelerator contract becomes a document
([docs/accelerator-contract.md](../accelerator-contract.md)) and
`docs/register-map.md` becomes one conforming accelerator's map rather than
*the* specification.

A second accelerator stops being optional. One implementation cannot
distinguish a contract from a description of itself, so the claim this ADR
makes is unfalsifiable until `relu_unit` — elementwise, stream-in/stream-out,
with a writable parameter — has been through the whole flow. That work is
larger than it sounds: it requires the block design's S2MM channel, a second
register map and a return path in the driver.

The repository keeps its name. `zynq_cnn`, the GHCR image and the Dev Container
reference each other and the rename buys nothing a paragraph cannot. What does
move is the vocabulary one layer down, so that a package named for the example
does not look like a prerequisite for using the environment.

The audience is now explicit: whoever in the lab picks this up next. That makes
the boundary between what is reproducible (the toolchain image, `make sim`,
`make lint`, `make sec`) and what is not (the build host, a node-locked
licence, two boards on unreachable network segments) something the
documentation has to state rather than imply.

## Limits of this decision

The prior-art survey behind it is partial. The simulation-harness layer —
FuseSoC/Edalize, SiliconCompiler, the various cocotb/Verilator templates — was
**not** surveyed, on the grounds that it is already built and working here and
the cost of the survey exceeds its expected value. If a future reader finds
that one of those would have subsumed `docker/`, `scripts/` and `tb/`, this ADR
did not consider it and was not entitled to.
