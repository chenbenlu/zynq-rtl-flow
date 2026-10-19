# The accelerator contract

What a module must present for this repository's flows to carry it from RTL to
a running accelerator on the board. A conforming module gets simulation, lint,
sequential equivalence, out-of-context synthesis, the block design,
implementation, the bitstream, the firmware overlay and the driver's transport
layer without writing any of them. A non-conforming module is still simulated
and linted; everything downstream of the block design is its own problem.

This document is the specification. The register maps
([sparse CNN](register-map-sparse-cnn.md), [ReLU](register-map-relu.md)) are
not — each is one conforming accelerator's own.

## Required

### Clock and reset

One clock domain, driven from the PS. Active-low synchronous reset.

```systemverilog
(* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
(* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis, ASSOCIATED_RESET aresetn" *)
input logic aclk,
(* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
(* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
input logic aresetn,
```

The attributes are required. IP Integrator infers bus interfaces from port
names alone and gets clock association wrong often enough that the block design
fails to validate; stating it is cheaper than diagnosing it. List every bus the
clock serves in `ASSOCIATED_BUSIF`, colon-separated — including `m_axis` when
the accelerator has one.

### AXI4-Lite slave — `s_axi`

32-bit data, byte-addressed, 8-bit address by default. Every access returns
`OKAY`; unmapped offsets read as zero and ignore writes. Answering `SLVERR` to
an unmapped read is within the AXI specification but outside this contract: the
driver probes before it knows what it is talking to.

**Offset `0x00` is an ID register: read-only, readable before anything has been
written.**

| Bits | Meaning |
|-------|---------|
| 31:16 | A tag identifying the design |
| 15:8 | Major version |
| 7:0 | Minor version |

Bump the major version when a change would break a driver written against the
accelerator's register map; bump the minor for additions that do not. The tag
belongs to the design, not to this contract — it is how a driver confirms which
accelerator is in the PL before touching a control bit. `0x5350` is
`sparse_cnn_axi`'s, not a required value.

Everything above `0x00` is the accelerator's to define, in its own register-map
document. The contract fixes the probe and nothing else.

### AXI4-Stream slave — `s_axis`

`s_axis_tdata`, `s_axis_tvalid`, `s_axis_tready`, `s_axis_tlast`.

`tlast` marks the final beat of a **tile** — one run of beats the accelerator
treats as a unit. The tile boundary travels with the data rather than in a
register write, so software never has to synchronise a control-path event
against a DMA it does not directly observe.

Assert `tready` only when the beat will actually be consumed; never drop an
accepted beat. An accelerator that raises `tready` while idle loses the first
beats of a tile to a DMA that started before it did.

`tdata` width is the accelerator's choice, but not free: the block design's DMA
must match it (`CONFIG.c_m_axis_mm2s_tdata_width` in
`flows/embedded/bd/system.tcl`), so a new width is a block-design parameter,
not only an RTL one.

## Optional

### AXI4-Stream master — `m_axis`

`m_axis_tdata`, `m_axis_tvalid`, `m_axis_tready`, `m_axis_tlast`, with `tlast`
on the final beat of the tile the results belong to.

An accelerator that reduces a tile to a value reports through registers and
needs no master; one that transforms a tile beat by beat has nowhere else to
put its output. The block design connects the DMA's S2MM channel for the second
kind and leaves it unconnected for the first.

### Interrupt

Not part of the contract. Both reference accelerators are polled, which is
enough to prove an interface; an interrupt is an addition a design makes for
its own reasons.

## Excluded

- **The accelerator never masters memory.** It has no AXI4 master to DDR; the
  block design's DMA masters memory and the accelerator sees only a stream.
  This keeps the transport layer generic — a design that fetched its own
  operands would need a driver that knew where they were.
- **No second clock domain.** A design that wants one crosses it internally and
  presents `aclk` at its boundary.
- **No package-typed parameters.** See below.

## The package rule

A SystemVerilog package cannot express this contract.

A module added to a block design is packaged first, and every parameter default
and port-width expression in its header is evaluated **with no visibility of any
package**. `parameter int unsigned DATA_W = accel_contract_pkg::DATA_W` fails at
`create_bd_cell` with `Undefined parameter "accel_contract_pkg"`, before
synthesis runs — while lint, cocotb, `make sec` and out-of-context synthesis all
resolve it correctly. Out-of-context synthesis succeeding says nothing about
whether a module can be instantiated in a block design; the two use different
front ends.

So:

- Anything in the module header is a **literal**.
- Anything internal may come from a package freely.
- Keep the literal honest with an elaboration check, as `sparse_cnn_axi` does:

  ```systemverilog
  if (DATA_W != sparse_cnn_pkg::DATA_W) begin : gen_data_w_check
    $error("DATA_W (%0d) does not match the package (%0d)", DATA_W, sparse_cnn_pkg::DATA_W);
  end
  ```

The contract is held by port names, widths, this document and lint — not by the
type system. Do not look for it expressed in RTL; it cannot be.

## What a conforming accelerator still supplies

The contract covers the hardware boundary. Five things are per-design by
nature: its register map, a golden model, a cocotb seam, an entry in
`scripts/rtl_sources.sh` and — if it is to be driven from Linux — a register
layer under `driver/`. [Adding an accelerator](environment.md#adding-an-accelerator)
lists each with what it must satisfy.

## Conforming accelerators

| Module | Shape | Stream master | Register map |
|--------|-------|---------------|--------------|
| `sparse_cnn_axi` | Reduces a tile to an accumulator and a skip count | no | [register-map-sparse-cnn.md](register-map-sparse-cnn.md) |
| `relu_axi` | Transforms a tile beat by beat | yes | [register-map-relu.md](register-map-relu.md) |

The two are deliberately opposite shapes: one reports through registers, the
other through a stream; one has only readable fields, the other a writable
parameter that reaches its data path; their control registers do not even agree
on which bit enables the design. Everything they share is in this document,
which is what makes it a contract rather than a description of whichever was
written first.
