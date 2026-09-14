# Register map — `sparse_cnn_axi`

The AXI4-Lite slave of the AXI-wrapped accelerator
([rtl/sparse_cnn_axi.sv](../rtl/sparse_cnn_axi.sv)). This file is the
specification a PS-side driver is written against: the testbench in
[tb/sparse_cnn_axi/](../tb/sparse_cnn_axi/) checks the RTL against what is
written here, so where the two disagree the RTL is wrong.

All registers are 32 bits and aligned to 4 bytes. Offsets are from the base
address the block design assigns to the accelerator (recorded in
`build/<board>/impl/address_map.txt` when `make impl` runs). Unmapped offsets
read as zero and ignore writes; every access returns `OKAY`.

| Offset | Name | Access | Meaning |
|--------|--------|--------|---------|
| `0x00` | ID | RO | Identification and version |
| `0x04` | CTRL | RW | Start, clear, enable |
| `0x08` | STATUS | RO | Busy, done |
| `0x0C` | ACC | RO | Accumulator of the last completed tile |
| `0x10` | SKIP | RO | Zero-skip count of the last completed tile |

## `0x00` ID — identification

Reads `0x53500100` and is readable before anything has been written, so
software can confirm what it is talking to before it touches a control bit.

| Bits | Value | Meaning |
|------|-------|---------|
| 31:16 | `0x5350` | `"SP"` — sparse CNN accelerator |
| 15:8 | `0x01` | Major version |
| 7:0 | `0x00` | Minor version |

Bump the major version when a change would break a driver written against this
map; bump the minor version for additions that do not.

## `0x04` CTRL — control

| Bit | Name | Access | Reset | Meaning |
|-----|-------|--------|-------|---------|
| 0 | START | W1P | 0 | Begin a tile: clear the accumulator, then accept stream beats |
| 1 | CLEAR | W1P | 0 | Discard whatever has accumulated: zero the accumulator and skip count immediately |
| 2 | EN | RW | 1 | Enable. While low the accelerator withdraws stream ready and holds its state |
| 31:3 | — | RO | 0 | Reserved: reads 0, writes ignored |

`W1P` — write 1 to pulse. START and CLEAR act for one cycle and always read
back as 0, so CTRL can be read-modify-written without re-triggering them.

**Starting a tile is one write:** `CTRL = EN | START` (`0x5`). EN is a level,
not a pulse, so a write that leaves its bit clear disables the accelerator —
write `0x5` rather than `0x1`.

START is ignored while STATUS.BUSY is set.

CLEAR takes effect immediately whether or not a tile is in flight. It does not
end the tile: a tile that is running keeps running to its `tlast` beat and
accumulates the beats after the clear from zero. There is no way to abandon a
tile that never receives its `tlast`; reset the block instead.

## `0x08` STATUS — status

| Bit | Name | Meaning |
|-----|-------|---------|
| 0 | BUSY | A tile is in flight: START has been written and the `tlast` beat has not yet been absorbed |
| 1 | DONE | The last started tile completed. Cleared by the next START |
| 31:2 | — | Reads 0 |

BUSY falls and DONE rises in the same cycle, so a poll loop can wait on DONE
alone.

## `0x0C` ACC — accumulator

The signed accumulator of the **last completed tile**, sign-extended to 32 bits.
It is latched when the tile's `tlast` beat is absorbed and holds until the next
tile completes, so a read issued one cycle too early returns the previous
tile's result rather than a partial accumulation. Reset and CTRL.CLEAR both zero it,
and CTRL.CLEAR does so whether or not a tile is in flight.

## `0x10` SKIP — zero-skip count

The number of operand pairs in the last completed tile that had a zero operand
and were therefore skipped. Latched, held, and cleared on the same terms as
ACC. Counts up to `SKIP_W` bits (16 by default) and is zero-extended to 32.

This is what makes the sparse behaviour observable from software rather than
only from a waveform: for a tile of *n* pairs, *n* − SKIP multiply-accumulates
actually happened.

## The stream

Operand pairs arrive on the AXI4-Stream slave, one pair per beat, `2*DATA_W`
(16) bits wide:

| Bits | Field |
|------|-------|
| 15:8 | Activation, signed 8-bit |
| 7:0 | Weight, signed 8-bit |

`tlast` marks the final beat of a tile. The tile boundary travels with the data
rather than being signalled by a register write, so software never has to
synchronise a control-path event against a DMA it does not directly observe.

`tready` is asserted only when the beat will actually be consumed — never
during idle, never while EN is low, never during the cycle a CLEAR is applied —
and a beat that has been accepted is never dropped.

## Driving a tile

```c
while (readl(base + STATUS) & STATUS_BUSY)
    ;
writel(CTRL_EN | CTRL_START, base + CTRL);   /* one write starts the tile */
dma_send(operand_pairs, n);                  /* last beat carries tlast   */
while (!(readl(base + STATUS) & STATUS_DONE))
    ;
int32_t  acc  = (int32_t) readl(base + ACC);
uint32_t skip =           readl(base + SKIP);
```

The first version is polled deliberately. An interrupt line is a reasonable
later addition and is not needed to prove the interface.
