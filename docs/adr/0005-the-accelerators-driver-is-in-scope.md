# The accelerator's driver is in scope

> **Status:** corrected in part by
> [ADR-0006](0006-the-deliverable-is-the-environment.md). The decision stands —
> the driver is in scope. The alternatives weighed below are incomplete: they
> miss the dmaengine clients that already exist, so the driver's transport layer
> is a candidate for adoption rather than something that has to be written here.

[ADR-0004](0004-zcu104-is-this-projects-board.md) removed the boot-image path from
this repository with the sentence "the PS side is not ours to build". Read
literally that also excludes the software that *operates* the accelerator, which
would leave the deliverable unusable by anything in this project. This decision
draws the line the earlier one did not need to.

The line is between software that brings the board up and software that works the
design. A boot image is a property of the board: it decides what operating system
runs, and the board already has one that someone else installed. A driver is a
property of the design: it exists because `sparse_cnn_axi` presents a particular
register map and a particular stream interface, and it changes when those change.
[docs/register-map-sparse-cnn.md](../register-map-sparse-cnn.md) has been written
as the specification a PS-side driver is held to since before there was a board
to run on, and the cocotb
testbenches check the RTL against it. A driver that answers to the same document
is the second half of a contract this repository already owns, not a new scope.

## What forced the question

Reading `ACC` and `SKIP` from userspace works — `/dev/mem` maps the accelerator's
AXI4-Lite registers, which are device memory. Submitting a tile does not. The
board's kernel is built with `CONFIG_STRICT_DEVMEM=y`, so `/dev/mem` will not map
system memory, and the source buffer a DMA descriptor points at lives there. There
is no userspace-only path to hand the DMA a tile's operands, so there is no
lighter option to prefer; driving a tile requires a kernel-side client of the
dmaengine channel or it does not happen.

ADR-0004 already described this shape — "this project does not control the kernel,
so what the accelerator can be driven through is whatever
`5.15.0-1015-xilinx-zynqmp` already provides" — but that was a caveat about
capability. This is the first time it has decided a piece of work.

Two alternatives were available and are worse. Reserving a memory window at boot
would let `/dev/mem` map it under the strict rule, but it changes how the board
boots, which is exactly what ADR-0004 removed from scope. Installing a third-party
contiguous-buffer module and poking the DMA's registers from userspace avoids
writing a driver, but it is still an out-of-tree module compiled on the board, so
it pays the same price for less; and it polls, which would leave the interrupt
this design now carries unexercised.

## Consequences

The driver is an out-of-tree kernel module compiled on the ZCU104 against
`/lib/modules/$(uname -r)/build`. Neither container can build it: the toolchain
image carries no kernel headers, and the Vivado image is x86 while the target is
aarch64. It is the first component of this repository that is built somewhere
other than a pinned image.

CI therefore cannot cover it. `make regress` has no board and will not grow one,
so the module's behaviour is established on the board and the repository's
automated checks stay what they are today. That is a real asymmetry with the RTL,
where a golden model and two simulated seams answer for correctness before
anything is synthesised.

ADR-0004's closing caveat now costs more. If the rootfs is ever reflashed, the
module has to be rebuilt against whatever kernel replaces
`5.15.0-1015-xilinx-zynqmp`, and nothing here reproduces that kernel or that
kernel's configuration — including the `CONFIG_STRICT_DEVMEM` setting this
decision turns on.

What stays out of scope is unchanged: no BOOT.BIN, no FSBL on an SD card, no ATF,
no U-Boot, no root filesystem, and no kernel. The driver is also not a ROS 2 node.
ROS 2 Humble is on the board and is where this work is eventually going, but a
node is a consumer of the driver and a separate decision from whether the driver
exists.
