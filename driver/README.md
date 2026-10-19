# PS-side driver

Submits a tile to an accelerator and reports what came back — the software half
of [the accelerator contract](../docs/accelerator-contract.md) and one
accelerator's register map. The RTL and its cocotb testbenches are the other
half.

It is a kernel module because the board's kernel is built with
`CONFIG_STRICT_DEVMEM=y`: `/dev/mem` maps the accelerator's AXI4-Lite registers
(device memory) but not the system memory a DMA descriptor points at, so a
tile's operands cannot be handed to the DMA from userspace at all.
[ADR-0005](../docs/adr/0005-the-accelerators-driver-is-in-scope.md) has the
reasoning and the cost.

## Two layers, three modules

| Module | Knows | Changes when |
|--------|-------|--------------|
| `accel_transport.ko` | The contract: registers at resource 0, the ID at offset `0x00`, an AXI DMA on `s_axis`, the optional return path on `m_axis` | The contract changes |
| `sparse_cnn.ko` | [`docs/register-map-sparse-cnn.md`](../docs/register-map-sparse-cnn.md) and `xlnx,sparse-cnn-axi-1.0` | That accelerator changes |
| `relu.ko` | [`docs/register-map-relu.md`](../docs/register-map-relu.md) and `xlnx,relu-axi-1.0` | That accelerator changes |

Why two layers ([ADR-0006](../docs/adr/0006-the-deliverable-is-the-environment.md)):
the dmaengine client that moves a tile is the same for every conforming
accelerator; the registers it reads are not. A register layer owns the platform
driver and the `compatible` string, and answers four questions:

1. may a tile start?
2. what makes it start?
3. how to tell it finished?
4. what does `read()` give back?

[`accel_transport.h`](accel_transport.h) is the interface. A third conforming
accelerator needs a new register layer and nothing else.

## Interface

One character device per accelerator, named after its register layer.

| Call | Meaning |
|------|---------|
| `write()` | One tile, as stream beats (at most 4096). Runs it and returns when it has completed. |
| `read()` | The tile's results, in the shape that accelerator reports them. |

Neither uses the file offset: a tile is a transaction, not a position in a
stream. One tile at a time; concurrent writers are serialised.

**`/dev/sparse_cnn`** — a beat is a little-endian 16-bit operand pair: bits 15:8
the activation, 7:0 the weight. `read()` gives eight bytes for the last
completed tile: the accumulator as a signed 32-bit value, then the zero-skip
count.

**`/dev/relu`** — a beat is one signed 8-bit activation. `read()` gives the
transformed tile back off the DMA's return path, same length and order. The
negative slope belongs to the accelerator, not to a tile, so it is a sysfs
attribute:

```bash
echo 25 | sudo tee /sys/class/misc/relu/device/slope
```

Each driver refuses the device unless its ID register reads the value its
register map specifies, so a bitstream of another design fails to attach rather
than returning wrong numbers.

## Building and running it

Built on the board. Neither container can: the toolchain image carries no kernel
headers, and the Vivado image is x86 against an aarch64 target.

Load the [firmware overlay](../README.md#loading-it-on-the-zcu104) first: a
register layer binds to a device the overlay creates, and the transport's
`dma_request_chan()` needs the DMA the same overlay describes.

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

Load order matters: the register layers resolve symbols against the transport,
and `insmod` refuses a module whose symbols are missing. Unload in reverse —
`rmmod sparse_cnn`, then `rmmod accel_transport` — and before removing the
overlay.

`run-tile.py` runs five tiles through the accelerator named on its command line
(or the only one with a device node) and checks each against `tb/model/`. These
are the golden models the cocotb testbenches import, so a mismatch is hardware
disagreeing with simulation, not two ideas of what the accelerator computes. It
also reports how many interrupts the DMA took: tiles completing without the DMA
having moved would mean the result came from somewhere other than this driver's
path.

## What is not covered

`make regress` has no board, so nothing here runs in CI; the modules are
established only by running them. That is a real asymmetry with the RTL, where
a golden model and two simulated seams answer for correctness before anything is
synthesised. ADR-0005 states it rather than leaving it to be discovered.

Evidence so far — all three modules on the ZCU104, 2026-09-19,
5.15.0-1015-xilinx-zynqmp, recorded on issue #25:

- `sparse_cnn.ko` moved five tiles through the transport with the results the
  pre-split module gave.
- `relu.ko` bound to `xlnx,relu-axi-1.0` and returned five more on the DMA's
  S2MM channel, both interrupt lines moving.
- The generated tree spells the `compatible` string the way this driver
  derives it.

That is one accelerator's worth of evidence for the rule, not the rule. A new register
layer's `compatible` is still derived from its module name, not read off a tree.
If it does not bind, read the node's `compatible` in `/sys/firmware/devicetree`
and fix the match table — a one-line correction, not a design problem.
