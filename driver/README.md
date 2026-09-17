# PS-side driver

`sparse_cnn.ko` submits a tile to the accelerator and reports what came back. It
is the software half of the contract [docs/register-map.md](../docs/register-map.md)
specifies; the RTL and its cocotb testbenches are the other half.

It is a kernel module because the board's kernel is built with
`CONFIG_STRICT_DEVMEM=y`: `/dev/mem` maps the accelerator's AXI4-Lite registers,
which are device memory, but not the system memory a DMA descriptor points at. So
a tile's operands cannot be handed to the DMA from userspace at all.
[ADR-0005](../docs/adr/0005-the-accelerators-driver-is-in-scope.md) has the
reasoning and what it costs.

## Interface

One character device, `/dev/sparse_cnn`:

| Call | Meaning |
|------|---------|
| `write()` | The tile's operand pairs, one little-endian 16-bit beat each: bits 15:8 the activation, 7:0 the weight. Runs the tile and returns when it has completed. At most 4096 beats. |
| `read()` | Eight bytes — the accumulator as a signed 32-bit value, then the zero-skip count. The last completed tile's, as the register map defines them. |

Neither uses the file offset: a tile is a transaction, not a position in a
stream. One tile at a time; concurrent writers are serialised.

The driver binds to `xlnx,sparse-cnn-axi-1.0` and refuses the device if its ID
register does not read `0x53500100`, so a bitstream that is not this design fails
to attach rather than returning wrong numbers.

## Building and running it

Built on the board. Neither container can: the toolchain image carries no kernel
headers, and the Vivado image is x86 against an aarch64 target.

The [firmware overlay](../README.md) has to be loaded first — the driver binds to
a device the overlay creates, and `dma_request_chan()` needs the DMA the same
overlay describes.

```bash
# from a workstation that reaches the board
tar czf - driver tb/model/sparse_mac_model.py |
  ssh zcu104 'rm -rf ~/sparse_cnn && mkdir -p ~/sparse_cnn && tar xzf - -C ~/sparse_cnn'

ssh zcu104 '
  cd ~/sparse_cnn/driver
  make
  sudo insmod sparse_cnn.ko
  sudo python3 run-tile.py'
```

`run-tile.py` runs five tiles of different lengths and sparsities and checks each
against `tb/model/sparse_mac_model.py` — the same golden model the cocotb
testbenches import, so a disagreement here is hardware disagreeing with
simulation rather than two ideas of what the accelerator computes. It also
reports how many interrupts the DMA took, because tiles that complete without it
having moved would mean the result came from somewhere other than the path this
driver claims to use.

`sudo rmmod sparse_cnn` to unload. The module has to come out before the overlay
does.

## What is not covered

`make regress` has no board, so nothing here runs in CI. The module's behaviour
is established by running it, which is a real asymmetry with the RTL — there a
golden model and two simulated seams answer for correctness before anything is
synthesised. ADR-0005 states it rather than leaving it to be discovered.
