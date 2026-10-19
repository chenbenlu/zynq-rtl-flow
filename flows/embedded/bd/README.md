# Block design

[`system.tcl`](system.tcl) — the block design `make impl` builds. A Tcl script
rather than a checked-in `.bd`, so it is reviewable in a diff and rebuildable
from the repository.

```
PS DDR ──HP0──► AXI DMA (MM2S) ──AXI4-Stream──► accel
   ▲                  ▲                          ▲
   └──── HPM0 ────────┴──── AXI4-Lite ───────────┘

PS GIC ◄──pl_ps_irq0── AXI DMA (mm2s_introut)

                  … and when the accelerator has a stream master:

PS DDR ◄─HP0── AXI DMA (S2MM) ◄──AXI4-Stream── accel
```

- **One clock domain:** the PS's PL clock 0, at the per-board frequency in
  [`flows/common/boards.sh`](../../common/boards.sh).
- **RTL module reference, not packaged IP** (`create_bd_cell -type module`), so
  the accelerator's widths stay in the RTL and nowhere else.
- **No accelerator named here.** The cell instantiates `$::env(RTL_TOP)` —
  whatever [`scripts/rtl_sources.sh`](../../../scripts/rtl_sources.sh) names as
  the top — and every connection is exactly
  [the accelerator contract](../../../docs/accelerator-contract.md). Stream
  widths are read off the accelerator's own ports, so a second accelerator needs
  no edit to this file.

## S2MM follows the optional stream master

An accelerator that reduces a tile to a value reports it over AXI4-Lite and
needs no write channel: the DMA is built MM2S-only and the memory interconnect
has one slave port. `sparse_cnn_axi` is this kind. An accelerator with an
`m_axis` gets the S2MM channel, a second interconnect slave port, and a second
interrupt.

## Interrupts

The DMA's `mm2s_introut` drives the PS's `pl_ps_irq0`. That port's width is
read-only and follows what is connected to it, so:

- MM2S-only: one interrupt, connected directly.
- With S2MM: two, through an `xlconcat`.

This connection is what puts an `interrupts` property on the dma node of the
generated device tree. Without it `xilinx-vdma` fails to probe, which reads as a
driver or packaging fault rather than a hole in the block design.
