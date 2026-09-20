# zynq-rtl-flow — an accelerator environment for Zynq UltraScale+

An environment that carries a hand-written accelerator from SystemVerilog to a
running design on an AMD Zynq UltraScale+ board: simulation, lint, coverage,
sequential equivalence, out-of-context synthesis, a block design, place & route,
a bitstream, a firmware overlay and a PS-side driver. The simulation toolchain
(Verilator, cocotb, Verible, GTKWave) lives inside a Docker image so local
development, Dev Containers and CI all run the *exact same* environment; the AMD
toolchain runs in a second container on one machine.

**The environment is the deliverable**
([ADR-0006](docs/adr/0006-the-deliverable-is-the-environment.md)). What a module
must present to be carried through it is
[docs/accelerator-contract.md](docs/accelerator-contract.md) — a clock, an
AXI4-Lite slave with an ID register, an AXI4-Stream slave, and optionally a
stream master.

Two accelerators go through it today, chosen to be the opposite shapes: a
**sparse MAC** that reduces a tile to an accumulator and reports it in a
register, and a **Leaky ReLU** that transforms a tile beat by beat and sends it
back out on a stream, with a writable slope. Each has a numpy golden model and a
cocotb seam; neither is the point of the repository.

Which parts travel: everything under `make regress` runs anywhere Docker does.
Synthesis and everything after it do not — they need the build host, its
node-locked licence and, for the last step, a board on a network segment CI
cannot reach.

## Toolchain (pinned)

| Tool | Version |
|------|---------|
| Verilator | 5.042 |
| cocotb | 2.x (2.0.1) |
| Verible | v0.0-4063-gf831ec18 |
| Python | 3.12 |
| Base image | Ubuntu 24.04 |
| Vivado / Vitis | 2026.1 (build host only) |

## Prerequisites

- Docker **or** rootless Podman
- (Recommended) VS Code + the **Dev Containers** extension

## Quickstart — Dev Container (recommended)

1. Log in to GHCR once -- the package is private:

   ```bash
   docker login ghcr.io -u <your-github-user>   # PAT with read:packages
   ```

2. Open this folder in VS Code.
3. Run **"Dev Containers: Reopen in Container"**. It pulls
   `ghcr.io/chenbenlu/zynq-rtl-flow-dev:latest` (first time only) -- no local
   compile. On Linux, VS Code auto-remaps the container user to your host UID,
   so files stay yours.
4. In the integrated terminal:

   ```bash
   make lint      # Verilator strict lint + Verible
   make sim       # build + run the cocotb suite (31 tests, 3 seams)
   make coverage  # Python + RTL coverage -> sim/coverage/
   make wave      # open the latest waveform (needs X11, see below)
   make regress   # lint -> sim -> coverage (what CI runs)
   ```

### Podman

The same config works unmodified. Point the extension at podman in your VS Code
**user** settings (not the repo -- that would break Docker users):

```jsonc
"dev.containers.dockerPath": "podman"
```

Dev Containers then detects the podman variant and injects
`--userns=keep-id --security-opt label=disable` itself (keep-id because this
config sets a non-root `remoteUser`), so bind-mounted files stay owned by you.
Nothing podman-specific belongs in `devcontainer.json`.

## Quickstart — raw Docker / Podman (no VS Code)

```bash
# Build the toolchain image
docker build -f docker/Dockerfile -t zynq-rtl-flow-dev:latest .

# Run a target. On Linux, pass --user so artifacts in the mounted workspace
# are owned by you rather than the container user.
docker run --rm -v "$PWD":/workspace -w /workspace \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  zynq-rtl-flow-dev:latest make sim
```

With rootless podman, drop `--user` and let `keep-id` do the mapping:

```bash
podman build -f docker/Dockerfile -t zynq-rtl-flow-dev:latest .
podman run --rm --userns=keep-id -v "$PWD":/workspace -w /workspace \
  -e HOME=/tmp zynq-rtl-flow-dev:latest make sim
```

## Waveforms

`make sim` writes a VCD dump under `sim/<dut>/dump.vcd`. View it with:

- **WaveTrace** or **TerosHDL** VS Code extensions — opens VCD/FST directly in
  the editor, no X11 needed (preinstalled in the Dev Container).
- **GTKWave** (`make wave`) — a GUI; inside the container it needs X11
  forwarding (uncomment the `mounts`/`containerEnv` in `devcontainer.json`), or
  just open the file with GTKWave on your host.

To switch the dump to FST, pass `--trace-fst` in the runner `build_args`
(see [tb/sparse_mac_pe/test_sparse_mac_pe.py](tb/sparse_mac_pe/test_sparse_mac_pe.py)).

## Synthesis and implementation (build host only)

Simulation runs anywhere; synthesis does not. The AMD toolchain lives on one
machine — the **build host**, `RTXWS` — inside a second container that is
separate from the simulation image and never published to a registry.

Two flows run side by side, and they are not interchangeable:

| Flow | Path | Artefact |
|------|------|----------|
| **Embedded** | hand-written SystemVerilog → Vivado → PS app over AXI | `.bit` / firmware overlay |
| **Acceleration** | HLS C++ → `v++` → XRT on the board | `.xclbin` |

See [CONTEXT.md](CONTEXT.md) for the vocabulary and
[docs/adr/](docs/adr/) for the decisions behind the setup.

### One-time setup on the build host

Run these **as `ubuntu`** on the build host — the persistent disk is owned by
that account, and its UID is what the container's user is aligned to.

```bash
# 1. Download the AMD installer yourself (it needs a signed-in account) and drop
#    it in /home/ubuntu/disk/lab/vivado-installer/ — the ~400 MB web installer
#    is the expected one; it pulls only the device families you select.
bash scripts/provision-vivado.sh --auth         # store an AMD token, once
bash scripts/provision-vivado.sh --config-gen   # generate + edit the config
bash scripts/provision-vivado.sh                # install (hours)

# 2. Build the container that runs it
make vivado-image

# 3. When the KV260 is cabled in. There is no default NIC — name the interface
#    it is cabled to ('ip -4 -br addr' lists them). Teardown (--down) needs no
#    NIC=: it finds the link by the address on it, and touches nothing else.
sudo NIC=<nic> bash scripts/provision-board-net.sh
```

The toolchain is installed to the host's persistent disk and mounted into the
container rather than baked into the image — the reasoning, and what that costs,
is in [ADR-0001](docs/adr/0001-vivado-installed-on-persistent-disk.md).

### Running a flow

```bash
make vivado-shell            # a shell inside the Vivado container
make synth                   # OOC baseline for sparse_cnn_axi on kv260
make synth RTL_TOP=sparse_mac_pe   # ... or for the bare PE
make synth BOARD=zcu104 CLK_PERIOD=2.5
make impl BOARD=kv260        # place & route the system design
make bitstream BOARD=kv260   # .bit + .bin from the routed checkpoint
make xsa BOARD=zcu104        # hardware handoff for the PS-side boot flow
make hls KERNEL=sparse_conv
make vivado-gui              # GUI on the build host's display
```

`make synth` synthesises one module out-of-context — no surrounding design, no
I/O buffers — and reports what that module costs and how fast it runs. It is a
measurement, not a step towards a bitstream.

`make impl` builds the real thing: the block design in
[flows/embedded/bd/system.tcl](flows/embedded/bd/system.tcl) — Zynq PS, AXI
interconnect, a DMA feeding the accelerator's stream — placed and routed against
the per-board PL clock target in [flows/common/boards.sh](flows/common/boards.sh),
with a summary in `build/<board>/impl/impl_summary.txt`. `make bitstream` writes
the `.bit` from the routed checkpoint.

`make xsa` exports the hardware handoff — the `.xsa` carrying the PS
configuration, the address map and the block design's metadata. It is what FSBL,
the PMU firmware and the device tree are generated from, so it is the first
artefact the PS-side boot flow needs; the bitstream is a separate file beside it
rather than packaged inside (see the gotcha in CLAUDE.md).

`make overlay` packages the bitstream and the generated PL device tree into a
firmware overlay — what a running Linux loads through the ZynqMP FPGA manager.
The device-tree nodes are not written by hand; they come from the same hardware
handoff as everything else, so the accelerator's address has one source.

The acceleration-flow targets (`make hls`, `make xclbin`) still depend on work
that has not been done yet — an HLS kernel and a platform — and each says
exactly what it is waiting for.

### Loading it on the ZCU104

The build host cannot reach the board: it is on the server VLAN and the board is
on the workstation one. The overlay is therefore built on the build host and
copied through a machine that can see both.

The overlay is named after the accelerator that was built, so two accelerators'
overlays do not land on the same directory.

```bash
# from a workstation that reaches both
A=zcu104-sparse-cnn     # or zcu104-relu
ssh rtxws "cd zynq-rtl-flow/build/zcu104/overlay && tar czf - $A" |
  ssh zcu104 'cat > /tmp/overlay.tgz'

ssh zcu104 "
  sudo tar xzf /tmp/overlay.tgz -C /lib/firmware/xilinx
  D=/lib/firmware/xilinx/$A
  sudo fpgautil -b \$D/$A.bit.bin -o \$D/$A.dtbo"
```

The accelerator then appears as a platform device and answers on the bus:

```
$ ls /sys/bus/platform/devices/ | grep a0
a0000000.sparse_cnn_axi
a0010000.dma

$ sudo python3 -c 'import mmap,os,struct
fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC)
m=mmap.mmap(fd,0x1000,mmap.MAP_SHARED,mmap.PROT_READ,offset=0xA0000000)
print(hex(struct.unpack("<I",m[0:4])[0]))'
0x53500100
```

`0x53500100` is the ID register
[docs/register-map-sparse-cnn.md](docs/register-map-sparse-cnn.md) specifies —
the first check that the thing on the bus is the design that was
built. To unload, `sudo rmdir /sys/kernel/config/device-tree/overlays/full`.

### Target boards

| Board | Device | Programmed via |
|-------|--------|----------------|
| KV260 (primary) | ZU5EV | SD-card boot + firmware overlay from Linux |
| ZCU104 | ZU7EV | firmware overlay into a booted Ubuntu 22.04 |

The ZCU104 is the board the design runs on today, because it is the one with a
booted PS — Ubuntu 22.04 with ROS 2 Humble, installed by an earlier project that
has since released the board ([ADR-0004](docs/adr/0004-zcu104-is-this-projects-board.md)).
Nothing in this repository builds that image, and nothing needs to: the
programmable logic is loaded into the running system rather than at boot.

Both devices are covered by the free Vivado ML Standard Edition; no licence
purchase is needed. The KV260 is cabled directly to the build host's second NIC
on a private segment — [ADR-0003](docs/adr/0003-kv260-direct-attached-to-build-host.md).

## Continuous Integration

Two GitHub Actions workflows:

- **build-image.yml** — builds the toolchain image and pushes it to **GHCR**
  (`ghcr.io/<owner>/zynq-rtl-flow-dev`). Runs only when `docker/**` or
  `pyproject.toml` change, plus manual dispatch.
- **ci.yml** — runs `lint → format-check → sim → coverage` inside that GHCR
  image on every push/PR and uploads waveforms + coverage as artifacts.

> **Bootstrap order:** run **build-image.yml** once (it must publish the image
> before **ci.yml** can pull it). For a private repo, ensure the package grants
> the repo `read` access.

## Project layout

```
rtl/        SystemVerilog sources — accel_contract_pkg (the environment's),
            then one group per example accelerator (sparse_cnn_*, relu_*)
tb/         cocotb testbenches + pytest runners, one directory per seam
flows/      synthesis flows — common/ (board map), embedded/, accel/
scripts/    lint / format / regress / wave / sec + Vivado provisioning helpers
            rtl_sources.sh is the single source list every consumer reads
driver/     the PS-side driver: a transport layer every conforming accelerator
            shares, and one register layer per accelerator
docker/     Dockerfile (simulation) + vivado.Dockerfile (synthesis)
sim/        simulation artifacts, waveforms, coverage (gitignored)
build/      synthesis + implementation artifacts (gitignored)
docs/       the accelerator contract, architecture notes, a register map per
            accelerator, ADRs
CONTEXT.md  project glossary, in two halves: the environment and the example
```

Start with [docs/accelerator-contract.md](docs/accelerator-contract.md) — it is
what the flows are built around.
[docs/architecture.md](docs/architecture.md) has the data flow and how to extend
the single PE into a PE array;
[docs/register-map-sparse-cnn.md](docs/register-map-sparse-cnn.md) is the
example accelerator's own interface, the one its PS-side driver is written
against.
