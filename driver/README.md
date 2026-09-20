# PS-side driver

Submits a tile to an accelerator and reports what came back. It is the software
half of what [the accelerator contract](../docs/accelerator-contract.md) and one
accelerator's register map specify; the RTL and its cocotb testbenches are the
other half.

It is a kernel module because the board's kernel is built with
`CONFIG_STRICT_DEVMEM=y`: `/dev/mem` maps the accelerator's AXI4-Lite registers,
which are device memory, but not the system memory a DMA descriptor points at. So
a tile's operands cannot be handed to the DMA from userspace at all.
[ADR-0005](../docs/adr/0005-the-accelerators-driver-is-in-scope.md) has the
reasoning and what it costs.

## Two layers, three modules

| Module | Knows | Changes when |
|--------|-------|--------------|
| `accel_transport.ko` | The contract: registers at resource 0, the ID at offset `0x00`, an AXI DMA on `s_axis`, the optional return path on `m_axis` | The contract changes |
| `sparse_cnn.ko` | [`docs/register-map-sparse-cnn.md`](../docs/register-map-sparse-cnn.md) and `xlnx,sparse-cnn-axi-1.0` | That accelerator changes |
| `relu.ko` | [`docs/register-map-relu.md`](../docs/register-map-relu.md) and `xlnx,relu-axi-1.0` | That accelerator changes |

The split is the one [ADR-0006](../docs/adr/0006-the-deliverable-is-the-environment.md)
made necessary: a dmaengine client that moves a tile is the same for every
conforming accelerator, and the registers it reads are not. A register layer owns
the platform driver and the `compatible` string, and answers four questions —
whether a tile may start, what makes it start, how to tell it finished, and what
`read()` gives back. [`accel_transport.h`](accel_transport.h) is the interface.

Adding a third accelerator is a new register layer and nothing else, as long as
it conforms.

## Interface

One character device per accelerator, named after its register layer.

| Call | Meaning |
|------|---------|
| `write()` | One tile, as stream beats. Runs it and returns when it has completed. At most 4096 beats. |
| `read()` | The tile's results, in the shape that accelerator reports them. |

Neither uses the file offset: a tile is a transaction, not a position in a
stream. One tile at a time; concurrent writers are serialised.

**`/dev/sparse_cnn`** — a beat is a little-endian 16-bit operand pair, bits 15:8
the activation and 7:0 the weight. `read()` gives eight bytes: the accumulator as
a signed 32-bit value, then the zero-skip count, both of the last completed tile.

**`/dev/relu`** — a beat is one signed 8-bit activation. `read()` gives the
transformed tile back, same length and same order, off the DMA's return path. The
negative slope is a property of the accelerator rather than of a tile, so it is a
sysfs attribute rather than part of the tile:

```bash
echo 25 | sudo tee /sys/class/misc/relu/device/slope
```

Each driver refuses the device unless its ID register reads the value its
register map specifies, so a bitstream that is not that design fails to attach
rather than returning wrong numbers.

## Building and running it

Built on the board. Neither container can: the toolchain image carries no kernel
headers, and the Vivado image is x86 against an aarch64 target.

The [firmware overlay](../README.md) has to be loaded first — a register layer
binds to a device the overlay creates, and the transport's `dma_request_chan()`
needs the DMA the same overlay describes.

```bash
# from a workstation that reaches the board
tar czf - driver tb/model |
  ssh zcu104 'rm -rf ~/zynq-rtl-flow && mkdir -p ~/zynq-rtl-flow && tar xzf - -C ~/zynq-rtl-flow'

ssh zcu104 '
  cd ~/zynq-rtl-flow/driver
  make
  sudo insmod accel_transport.ko
  sudo insmod sparse_cnn.ko          # or relu.ko, matching the loaded overlay
  sudo python3 run-tile.py'
```

The transport goes in first: the register layers resolve their symbols against
it, and `insmod` will not load a module whose symbols are missing. Unloading runs
the other way — `rmmod sparse_cnn` then `rmmod accel_transport` — and the modules
have to come out before the overlay does.

`run-tile.py` runs five tiles through the accelerator named on its command line
(or the only one with a device node) and checks each against `tb/model/` — the
same golden models the cocotb testbenches import, so a disagreement here is
hardware disagreeing with simulation rather than two ideas of what the
accelerator computes. It also reports how many interrupts the DMA took, because
tiles that complete without it having moved would mean the result came from
somewhere other than the path this driver claims to use.

## What is not covered

`make regress` has no board, so nothing here runs in CI. The module's behaviour
is established by running it, which is a real asymmetry with the RTL — there a
golden model and two simulated seams answer for correctness before anything is
synthesised. ADR-0005 states it rather than leaving it to be discovered.

Within that, all three modules have been run on the ZCU104 — 2026-09-19, on
5.15.0-1015-xilinx-zynqmp, recorded on issue #25. `sparse_cnn.ko` moved five
tiles through the transport with the results the pre-split module gave, and
`relu.ko` bound to `xlnx,relu-axi-1.0` and returned five more on the DMA's S2MM
channel, both interrupt lines moving. The generated tree does spell the
`compatible` string the way this driver derives it.

That is one accelerator's worth of evidence for the rule, not the rule. A third
register layer's `compatible` is still a name derived from its module rather
than one read off a tree: if it does not bind, read the node's `compatible` in
`/sys/firmware/devicetree` and fix the match table — a one-line correction, not
a design problem.
