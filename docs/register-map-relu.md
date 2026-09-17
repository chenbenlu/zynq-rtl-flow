# Register map — `relu_axi`

The AXI4-Lite slave of the Leaky ReLU accelerator
([rtl/relu_axi.sv](../rtl/relu_axi.sv)), the second implementation of
[the accelerator contract](accelerator-contract.md).

Only offset `0x00` is the contract's. **The rest is not `sparse_cnn_axi`'s map
with different names** — it is a different map, because this is a different
kind of accelerator. There is no START, because a tile begins when its first
beat arrives; there is no result register, because the results leave on the
stream master. Software that assumes one accelerator's layout from another's is
what the ID register exists to stop.

Within that scope this file is the specification a PS-side driver is written
against: the testbench in [tb/relu_axi/](../tb/relu_axi/) checks the RTL against
what is written here, so where the two disagree the RTL is wrong.

All registers are 32 bits and aligned to 4 bytes. Offsets are from the base
address the block design assigns to the accelerator. Unmapped offsets read as
zero and ignore writes; every access returns `OKAY`.

| Offset | Name | Access | Meaning |
|--------|--------|--------|---------|
| `0x00` | ID | RO | Identification and version |
| `0x04` | CTRL | RW | Enable |
| `0x08` | STATUS | RO | Busy, done |
| `0x0C` | SLOPE | RW | Negative slope, unsigned Q0.8 |
| `0x10` | COUNT | RO | Beats in the last completed tile |

## `0x00` ID — identification

Reads `0x524C0100`.

| Bits | Value | Meaning |
|------|-------|---------|
| 31:16 | `0x524C` | `"RL"` — this design's tag |
| 15:8 | `0x01` | Major version |
| 7:0 | `0x00` | Minor version |

## `0x04` CTRL — control

| Bit | Name | Access | Reset | Meaning |
|-----|-------|--------|-------|---------|
| 0 | EN | RW | 1 | Enable. While low the accelerator withdraws stream ready and holds its state |
| 31:1 | — | RO | 0 | Reserved: reads 0, writes ignored |

EN is a level and the only bit in the register. Note that it is **bit 0 here and
bit 2 in `sparse_cnn_axi`**: the contract fixes the probe, not the control
layout, and a driver that assumed otherwise would disable an accelerator it
meant to start.

## `0x08` STATUS — status

| Bit | Name | Meaning |
|-----|-------|---------|
| 0 | BUSY | A tile is in flight: a beat has been accepted and the beat carrying `tlast` has not yet left on the master |
| 1 | DONE | The last tile completed. Cleared when the next tile's first beat is accepted |
| 31:2 | — | Reads 0 |

BUSY spans the pipeline rather than only the input side. It falls when the final
beat *leaves*, not when it is accepted, so COUNT is never read a beat early.

## `0x0C` SLOPE — negative slope

The factor applied to negative activations, as an unsigned Q0.8 fraction: the
output is `x * SLOPE / 256`, truncated towards minus infinity. `0x19` (25, about
0.098) at reset, the usual leaky-ReLU coefficient at this width. `0x00` makes it
a plain ReLU; `0xFF` is very nearly the identity.

Bits above 7 are not storage and read back as zero.

Written between tiles. A write that lands mid-tile takes effect on the next beat
accepted — the accelerator does not defer it, because an accelerator that
silently ignored a write would be harder to explain than one that applies it.

## `0x10` COUNT — beats in the last completed tile

Latched when the tile's final beat leaves, and held until the next tile
completes. Counts up to 16 bits and is zero-extended to 32.

It is the observable that makes the tile boundary checkable from software: a
driver that submitted *n* activations and reads anything but *n* has lost beats
somewhere between the DMA and the stream.

## The streams

Both are `DATA_W` (8) bits wide, one signed activation per beat, in the same
order. `tlast` marks the final beat of a tile on the way in, and the accelerator
reproduces it on the corresponding beat on the way out.

`tready` is asserted only when the beat will actually be consumed — never while
EN is low, never while the output register is occupied and the consumer is not
taking it — and a beat that has been accepted is never dropped.

## Driving a tile

```c
writel(slope, base + SLOPE);                 /* before the tile */
dma_send(activations, n);                    /* last beat carries tlast */
dma_recv(results, n);                        /* S2MM, same order */
while (!(readl(base + STATUS) & STATUS_DONE))
    ;
uint32_t beats = readl(base + COUNT);        /* must equal n */
```

Polled, like the first accelerator. The DMA raises an interrupt per direction
and the S2MM one is what a driver would wait on instead; that is an addition,
not a prerequisite.
