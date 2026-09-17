# Block design

[`system.tcl`](system.tcl) — the block design `make impl` builds. Written as a
Tcl script rather than a checked-in `.bd`, so the design is reviewable in a diff
and rebuildable from the repository.

```
PS DDR ──HP0──► AXI DMA (MM2S) ──AXI4-Stream──► accel
   ▲                  ▲                          ▲
   └──── HPM0 ────────┴──── AXI4-Lite ───────────┘

PS GIC ◄──pl_ps_irq0── AXI DMA (mm2s_introut)

                  … and when the accelerator has a stream master:

PS DDR ◄─HP0── AXI DMA (S2MM) ◄──AXI4-Stream── accel
```

One clock domain: the PS's PL clock 0, at the per-board frequency in
[`flows/common/boards.sh`](../../common/boards.sh). The accelerator is pulled in
as an RTL module reference (`create_bd_cell -type module`) rather than a
packaged IP, so its widths stay in the RTL and nowhere else.

Nothing here names an accelerator. The cell instantiates `$::env(RTL_TOP)` —
whatever [`scripts/rtl_sources.sh`](../../../scripts/rtl_sources.sh) names as the
top — and every connection below is exactly
[the accelerator contract](../../../docs/accelerator-contract.md). The stream
widths are read off the accelerator's own ports rather than restated here, so a
second accelerator needs no edit to this file.

**S2MM follows the contract's optional stream master.** An accelerator that
reduces a tile to a value reports it over AXI4-Lite and needs no write channel,
so the DMA is built MM2S-only and the memory interconnect has one slave port. An
accelerator with an `m_axis` gets the S2MM channel, a second slave port on the
interconnect, and a second interrupt. `sparse_cnn_axi` is the first kind.

The DMA's `mm2s_introut` goes to the PS's `pl_ps_irq0`. With an MM2S-only DMA it
is the only interrupt in the design, and `pl_ps_irq0` sizes itself from what is
connected to it, so it takes the single source directly; with S2MM there are two
and the port is driven from an `xlconcat` instead, because that parameter is
read-only and the width has to follow the connections. Either way this
connection is what puts an `interrupts` property on the dma node of the
generated device tree; without it `xilinx-vdma` fails to probe, which reads as a
driver or packaging fault rather than a hole in the block design.
