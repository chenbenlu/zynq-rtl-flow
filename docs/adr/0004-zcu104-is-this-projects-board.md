# The ZCU104 becomes this project's board

The ZCU104 in the lab was bought for a different project. `amr_simulate` evaluated
it as the deployment platform for a BEV policy, then withdrew the case on
2026-08-31 with the sentence "the board goes back on the shelf; no project
inherits it". This project inherits it anyway, and that reversal is worth
recording rather than leaving as an inconsistency between two repositories.

The AMR case collapsed because its motivation could not carry it: a board was
already in hand with an idle PL, and a second AGX Orin was expensive. The latency
argument that ADR was built on came afterwards, to give that impulse a shape. A
port justified by an idle board is a port looking for a reason.

This project's relationship to the board is the opposite one. `zynq_cnn` exists to
put a sparse CNN accelerator in programmable logic; the PL is the deliverable, not
a resource to find a use for. The same board that could not justify hosting
someone else's inference stack is the natural target for an accelerator that has
been synthesised, placed, routed and timed against `xczu7ev` from the start.

Nothing here reopens the AMR decision. That project's surviving work is direct CAN
drive from the Orin, with no ZCU104 anywhere in it.

## Consequences

The PS side is not ours to build. Ubuntu 22.04.1 with ROS 2 Humble was installed
on this board by the earlier project and is left as it stands, which removes the
entire boot-image path from this repository's scope: no BOOT.BIN, no FSBL on an SD
card, no ATF, no U-Boot, no root filesystem. `make xsa` and `make boot` remain,
because FSBL and the PMU firmware are still the artefacts the hardware handoff is
validated through, but nothing assembles them into a boot image.

The programmable logic is therefore loaded at runtime, into a Linux that is
already up, through the ZynqMP FPGA manager. That makes the deliverable a firmware
overlay — bitstream plus device-tree overlay — rather than a bitstream alone.

The board is on the lab network (`192.168.88.7`, `ssh zcu104`), not direct-attached
to the build host the way the KV260 is. `scripts/provision-board-net.sh` and
[ADR-0003](0003-kv260-direct-attached-to-build-host.md) describe the KV260's private
segment and have nothing to do with this board.

That does not mean it is easier to reach. **The build host cannot talk to the
ZCU104 at all** — it sits on the server VLAN and the board is on the workstation
one, which is the same default-deny rule ADR-0003 worked around by cabling the
KV260 directly. Neither ping nor TCP 22 gets through. So the two boards are
unreachable from the build host for opposite reasons, and the overlay is built on
the build host but has to travel through a workstation to reach the board. The
compensation is that the ZCU104 has a route to the internet, which the KV260 does
not.

Two things follow from inheriting a rootfs rather than building one. This project
does not control the kernel, so what the accelerator can be driven through is
whatever `5.15.0-1015-xilinx-zynqmp` already provides. And if that install is ever
reflashed, the board's software state is not reproducible from anything in this
repository — only the PL side is.

The KV260 stays in `flows/common/boards.sh` and remains the primary *synthesis*
target. It is the board this design was dimensioned for; the ZCU104 is where it
first runs, because that is the board with a booted PS.
