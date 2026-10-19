# zynq-rtl-flow — an accelerator environment for Zynq UltraScale+

An environment that carries a hand-written accelerator from SystemVerilog to a
running design on an AMD Zynq UltraScale+ board: simulation, lint, coverage,
sequential equivalence, out-of-context synthesis, a block design, place & route,
a bitstream, a firmware overlay and a PS-side driver.

- The simulation toolchain (Verilator, cocotb, Verible, GTKWave) is a Docker
  image, so local development, Dev Containers and CI run the *exact same*
  environment.
- The AMD toolchain runs in a second container, on one machine.

**The environment is the deliverable**
([ADR-0006](docs/adr/0006-the-deliverable-is-the-environment.md)). What a module
must present to be carried through it is
[docs/accelerator-contract.md](docs/accelerator-contract.md): a clock, an
AXI4-Lite slave with an ID register, an AXI4-Stream slave, and optionally a
stream master.

Two example accelerators, chosen to be opposite shapes, each with a numpy golden
model and a cocotb seam:

- a **sparse MAC** — reduces a tile to an accumulator and reports it in a register;
- a **Leaky ReLU** — transforms a tile beat by beat and streams it back out, with
  a writable slope.

Everything under `make regress` runs anywhere Docker does. Synthesis and
everything after it need the build host, its node-locked licence and, for the
last step, a board on a network segment CI cannot reach.

## Toolchain (pinned)

Verilator, cocotb, Verible, Python and the base image are pinned in
[docker/Dockerfile](docker/Dockerfile); Python packages are mirrored in
[pyproject.toml](pyproject.toml). Vivado / Vitis **2026.1** runs on the build
host only. Versions and the reason for each:
[CLAUDE.md](CLAUDE.md#pinned-tooling-keep-in-sync).

## Prerequisites

- Docker **or** rootless Podman
- (Recommended) VS Code + the **Dev Containers** extension

## Quickstart — Dev Container (recommended)

1. Log in to GHCR once — the package is private:

   ```bash
   docker login ghcr.io -u <your-github-user>   # PAT with read:packages
   ```

2. Open this folder in VS Code.
3. Run **"Dev Containers: Reopen in Container"**. It pulls
   `ghcr.io/chenbenlu/zynq-rtl-flow-dev:latest` (first time only; no local
   compile). On Linux, VS Code remaps the container user to your host UID, so
   files stay yours.
4. In the integrated terminal:

   ```bash
   make lint      # Verilator strict lint + Verible
   make sim       # build + run the cocotb suite (31 tests, 3 seams)
   make coverage  # Python + RTL coverage -> sim/coverage/
   make wave      # open the latest waveform (needs X11, see below)
   make regress   # test-scripts -> lint -> sim -> coverage (what CI runs)
   ```

### Podman

The same config works unmodified. Set this in your VS Code **user** settings
(not the repo's — that would break Docker users):

```jsonc
"dev.containers.dockerPath": "podman"
```

Dev Containers then injects `--userns=keep-id --security-opt label=disable`
itself (keep-id because this config sets a non-root `remoteUser`), so
bind-mounted files stay yours. Nothing podman-specific belongs in
`devcontainer.json`.

## Quickstart — raw Docker / Podman (no VS Code)

```bash
docker build -f docker/Dockerfile -t zynq-rtl-flow-dev:latest .

# On Linux, --user keeps artifacts in the mounted workspace owned by you.
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

`make sim` writes `sim/<dut>/dump.vcd`. View it with:

- **WaveTrace** or **TerosHDL** (preinstalled in the Dev Container) — VCD/FST in
  the editor, no X11.
- **GTKWave** (`make wave`) — inside the container it needs X11 forwarding
  (uncomment `mounts`/`containerEnv` in `devcontainer.json`); or open the file
  with GTKWave on your host.

For FST, pass `--trace-fst` in the runner `build_args`
(see [tb/sparse_mac_pe/test_sparse_mac_pe.py](tb/sparse_mac_pe/test_sparse_mac_pe.py)).

## Synthesis and implementation (build host only)

The AMD toolchain lives on the **build host**, `RTXWS`, in a second container
that is separate from the simulation image and never published to a registry.

Two flows, not interchangeable:

| Flow | Path | Artefact |
|------|------|----------|
| **Embedded** | hand-written SystemVerilog → Vivado → PS app over AXI | `.bit` / firmware overlay |
| **Acceleration** | HLS C++ → `v++` → XRT on the board | `.xclbin` |

Vocabulary: [CONTEXT.md](CONTEXT.md). Decisions: [docs/adr/](docs/adr/).

### One-time setup on the build host

Run these **as `ubuntu`**: the persistent disk is owned by that account, and the
container's user is aligned to its UID.

```bash
# 1. Download the AMD installer yourself (it needs a signed-in account) into
#    /home/ubuntu/disk/lab/vivado-installer/. The ~400 MB web installer is the
#    expected one; it pulls only the device families you select.
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

The toolchain is installed on the host's persistent disk and mounted into the
container, not baked into the image —
[ADR-0001](docs/adr/0001-vivado-installed-on-persistent-disk.md) has why and
what it costs.

### Running a flow

```bash
make vivado-shell            # a shell inside the Vivado container
make synth                   # OOC baseline for sparse_cnn_axi on kv260
make synth RTL_TOP=sparse_mac_pe BOARD=zcu104 CLK_PERIOD=2.5
make impl BOARD=kv260        # place & route the system design
make bitstream BOARD=kv260   # .bit + .bin from the routed checkpoint
make xsa BOARD=zcu104        # hardware handoff for the PS-side boot flow
make overlay BOARD=zcu104    # bitstream + device tree, ready to load
make vivado-gui              # GUI on the build host's display
```

`make synth` measures one module in isolation; it is not a step towards a
bitstream. `make impl` builds the design that ends up on the board. What each
stage hands to the next: [docs/environment.md](docs/environment.md). Full target
list: [CLAUDE.md](CLAUDE.md).

`make hls` and `make xclbin` wait on work not yet done — an HLS kernel and a
platform — and each reports exactly what is missing.

### Loading it on the ZCU104

The build host cannot reach the board (server VLAN vs workstation VLAN), so the
overlay is built on the build host and copied through a machine that sees both.
Each overlay is named after the accelerator it was built from, so two
accelerators' overlays do not share a directory.

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
the first check that the design on the bus is the one that was built. To unload:
`sudo rmdir /sys/kernel/config/device-tree/overlays/full`. To submit tiles, see
[driver/README.md](driver/README.md).

### Target boards

| Board | Device | Programmed via |
|-------|--------|----------------|
| KV260 (primary) | ZU5EV | SD-card boot + firmware overlay from Linux |
| ZCU104 | ZU7EV | firmware overlay into a booted Ubuntu 22.04 |

- **ZCU104** is where the design runs today, because it has a booted PS —
  Ubuntu 22.04 with ROS 2 Humble, installed by an earlier project that has since
  released the board
  ([ADR-0004](docs/adr/0004-zcu104-is-this-projects-board.md)). Nothing here
  builds that image, and nothing needs to: the PL is loaded into the running
  system, not at boot.
- **KV260** is cabled directly to the build host's second NIC on a private
  segment ([ADR-0003](docs/adr/0003-kv260-direct-attached-to-build-host.md)).

Both devices are covered by the free tier, but from 2026.1 the free tier is a
licence, not the absence of one: Vivado refuses to launch without a licence
file, and the build host's is node-locked and expires. Measurement and failure
mode: [CLAUDE.md](CLAUDE.md#gotchas-learned-during-setup).

## Continuous Integration

- **build-image.yml** — builds the toolchain image and pushes it to **GHCR**
  (`ghcr.io/<owner>/zynq-rtl-flow-dev`). Runs only when `docker/**` or
  `pyproject.toml` change, or on manual dispatch.
- **ci.yml** — runs `test-scripts → lint → format-check → sim → coverage` inside
  that image on every push/PR; uploads waveforms + coverage as artifacts.

> **Bootstrap order:** run **build-image.yml** once — it must publish the image
> before **ci.yml** can pull it. For a private repo, grant the repo `read`
> access to the package.

## Project layout

```
rtl/        SystemVerilog — accel_contract_pkg (the environment's), then one
            group per example accelerator (sparse_cnn_*, relu_*)
tb/         cocotb testbenches + pytest runners, one directory per seam
flows/      synthesis flows — common/ (board map), embedded/, accel/
scripts/    lint / format / regress / wave / sec + Vivado provisioning helpers;
            rtl_sources.sh is the single source list every consumer reads
tests/      bash tests for scripts/ (make test-scripts)
driver/     PS-side driver: a transport layer shared by every conforming
            accelerator, and one register layer per accelerator
docker/     Dockerfile (simulation) + vivado.Dockerfile (synthesis)
sim/        simulation artifacts, waveforms, coverage (gitignored)
build/      synthesis + implementation artifacts (gitignored)
docs/       accelerator contract, environment, example accelerators, one
            register map per accelerator, ADRs
CONTEXT.md  glossary, in two halves: the environment and the example
```

Where to start:

1. [docs/accelerator-contract.md](docs/accelerator-contract.md) — what the flows
   are built around.
2. [docs/environment.md](docs/environment.md) — the path a conforming
   accelerator takes and what each stage hands to the next.
3. [docs/example-accelerators.md](docs/example-accelerators.md) — the two
   designs that take it today; goes when they do.
