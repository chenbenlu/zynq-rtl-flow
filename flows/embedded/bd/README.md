# Block design

[`system.tcl`](system.tcl) — the block design `make impl` builds. Written as a
Tcl script rather than a checked-in `.bd`, so the design is reviewable in a diff
and rebuildable from the repository.

```
PS DDR ──HP0──► AXI DMA (MM2S) ──AXI4-Stream──► sparse_cnn_axi
   ▲                  ▲                              ▲
   └──── HPM0 ────────┴──── AXI4-Lite interconnect ──┘

PS GIC ◄──pl_ps_irq0── AXI DMA (mm2s_introut)
```

One clock domain: the PS's PL clock 0, at the per-board frequency in
[`flows/common/boards.sh`](../../common/boards.sh). The accelerator is pulled in
as an RTL module reference (`create_bd_cell -type module`) rather than a
packaged IP, so the operand widths stay in `sparse_cnn_pkg` and nowhere else.

The DMA is MM2S only. The accelerator produces one accumulator per tile, read
back over AXI4-Lite, so there is nothing for an S2MM channel to carry.

The DMA's `mm2s_introut` goes to the PS's `pl_ps_irq0`. It is the only interrupt
in the design, and `pl_ps_irq0` sizes itself from what is connected to it, so it
takes the single source without an `xlconcat`. This connection is what puts an `interrupts` property on the dma node
of the generated device tree; without it `xilinx-vdma` fails to probe, which
reads as a driver or packaging fault rather than a hole in the block design.
