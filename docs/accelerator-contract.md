# The accelerator contract

What a module has to present for this repository's flows to carry it from RTL
to a running accelerator on the board. A module that conforms gets simulation,
lint, sequential equivalence, out-of-context synthesis, the block design,
implementation, the bitstream, the firmware overlay and the PS-side driver's
transport layer without writing any of them; a module that does not conform is
still simulated and linted, but everything downstream of the block design is
its own problem.

This document is the specification. `docs/register-map.md` is not — it is one
conforming accelerator's register map, the first implementation of what is
written here.

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

The attributes are not decoration. IP Integrator infers a bus interface from
port names alone and gets clock association wrong often enough that the block
design fails to validate; stating it is cheaper than diagnosing it. List every
bus the clock serves in `ASSOCIATED_BUSIF`, separated by colons — including
`m_axis` when the accelerator has one.

### AXI4-Lite slave — `s_axi`

32-bit data, byte-addressed, 8-bit address by default. Every access returns
`OKAY`; unmapped offsets read as zero and ignore writes. An accelerator that
answers `SLVERR` to an unmapped read would be within the AXI specification and
outside this contract: the driver probes before it knows what it is talking to.

**Offset `0x00` is an ID register, read-only, readable before anything has been
written.**

| Bits | Meaning |
|-------|---------|
| 31:16 | A tag identifying the design |
| 15:8 | Major version |
| 7:0 | Minor version |

Bump the major version when a change would break a driver written against the
accelerator's register map; bump the minor for additions that do not. The tag
is the accelerator's own — it is how a driver confirms which accelerator is in
the PL before it touches a control bit, so it belongs to the design and not to
this contract. `0x5350` is `sparse_cnn_axi`'s, not a required value.

Everything above `0x00` is the accelerator's to define, and it defines it in
its own register-map document. The contract fixes the probe and nothing else.

### AXI4-Stream slave — `s_axis`

`s_axis_tdata`, `s_axis_tvalid`, `s_axis_tready`, `s_axis_tlast`.

`tlast` marks the final beat of a **tile** — one run of beats that the
accelerator treats as a unit. The tile boundary travels with the data rather
than in a register write, so software never has to synchronise a control-path
event against a DMA it does not directly observe.

`tready` must be asserted only when the beat will actually be consumed, and a
beat that has been accepted is never dropped. An accelerator that raises
`tready` while idle will lose the first beats of a tile to a DMA that started
before it did.

`tdata` width is the accelerator's business, but it is not free: the block
design's DMA has to be configured to match it
(`CONFIG.c_m_axis_mm2s_tdata_width` in `flows/embedded/bd/system.tcl`), so a
new width is a block-design parameter, not only an RTL one.

## Optional

### AXI4-Stream master — `m_axis`

`m_axis_tdata`, `m_axis_tvalid`, `m_axis_tready`, `m_axis_tlast`, with `tlast`
on the final beat of the tile the results belong to.

An accelerator that reduces a tile to a value reports through registers and
needs no master; one that transforms a tile beat by beat has nowhere else to
put its output. The block design carries the DMA's S2MM channel for the second
kind, and leaves it unconnected for the first.

### Interrupt

Not part of the contract. Both reference accelerators are polled, which is
enough to prove an interface, and an interrupt is an addition a design makes
for its own reasons.

## What the contract deliberately excludes

**The accelerator never masters memory.** It has no AXI4 master to DDR; the DMA
in the block design does the mastering and the accelerator sees only a stream.
This is what keeps the driver's transport layer generic — a design that fetched
its own operands would need a driver that knew where they were.

**No second clock domain.** A design that wants one crosses it internally and
presents `aclk` at its boundary.

**No package-typed parameters.** See below.

## The package rule

A SystemVerilog package cannot express this contract, and trying is a trap this
repository has already fallen into.

A module added to a block design is packaged first, and every parameter default
and port-width expression in its header is evaluated **with no visibility of any
package**. `parameter int unsigned DATA_W = accel_contract_pkg::DATA_W` fails at
`create_bd_cell` with `Undefined parameter "accel_contract_pkg"`, before
synthesis runs — while lint, cocotb, `make sec` and out-of-context synthesis all
resolve it correctly. Out-of-context synthesis succeeding tells you nothing
about whether a module can be instantiated in a block design; the two use
different front ends.

So:

- Anything that appears in the module header is a **literal**.
- Anything internal may come from a package freely.
- Keep the literal honest with an elaboration check, the way `sparse_cnn_axi`
  does:

  ```systemverilog
  if (DATA_W != sparse_cnn_pkg::DATA_W) begin : gen_data_w_check
    $error("DATA_W (%0d) does not match the package (%0d)", DATA_W, sparse_cnn_pkg::DATA_W);
  end
  ```

The contract is therefore held by port names, widths, this document and lint —
not by the type system. A reader who expects to find it expressed in RTL will
look for something that cannot exist.

## What a conforming accelerator still has to supply

The contract covers the hardware boundary. Four things sit outside it and are
per-design by nature:

1. **Its register map**, as a document under `docs/`, in the shape of
   `docs/register-map.md`. The testbench checks the RTL against it, so where the
   two disagree the RTL is wrong.
2. **A golden model** under `tb/model/`, imported by every seam that verifies
   the design and never copied into one.
3. **A cocotb seam** at `tb/<dut>/`, driving only top-level ports.
4. **An entry in `scripts/rtl_sources.sh`**, which is what lint, `make sec` and
   both synthesis flows read.

## Conforming accelerators

| Module | Shape | Stream master | Register map |
|--------|-------|---------------|--------------|
| `sparse_cnn_axi` | Reduces a tile to an accumulator and a skip count | no | [register-map.md](register-map.md) |
| `relu_axi` | Transforms a tile beat by beat | yes | [register-map-relu.md](register-map-relu.md) |

The two are deliberately the opposite shapes. One reports through registers and
the other through a stream; one has only readable fields and the other a
writable parameter that reaches its data path; their control registers do not
even agree on which bit enables the design. Everything they have in common is in
this document, which is what makes it a contract rather than a description of
whichever was written first.
