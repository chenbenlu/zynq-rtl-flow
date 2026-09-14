# Block design

[`system.tcl`](system.tcl) — the block design `make impl` builds. Written as a
Tcl script rather than a checked-in `.bd`, so the design is reviewable in a diff
and rebuildable from the repository.

```
PS DDR ──HP0──► AXI DMA (MM2S) ──AXI4-Stream──► sparse_cnn_axi
   ▲                  ▲                              ▲
   └──── HPM0 ────────┴──── AXI4-Lite interconnect ──┘
```

One clock domain: the PS's PL clock 0, at the per-board frequency in
[`flows/common/boards.sh`](../../common/boards.sh). The accelerator is pulled in
as an RTL module reference (`create_bd_cell -type module`) rather than a
packaged IP, so the operand widths stay in `sparse_cnn_pkg` and nowhere else.

The DMA is MM2S only. The accelerator produces one accumulator per tile, read
back over AXI4-Lite, so there is nothing for an S2MM channel to carry.
