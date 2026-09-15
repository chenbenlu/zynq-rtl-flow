# zynq_cnn — Sparse CNN Accelerator Simulation Skeleton

A reproducible, automated RTL simulation environment for a sparse convolutional
neural-network accelerator targeting a Xilinx **Zynq** SoC. The whole toolchain
(Verilator, cocotb, Verible, GTKWave) lives inside a Docker image so local
development, Dev Containers, and CI all run the *exact same* environment.

The skeleton ships with one working, verified example — a **sparse MAC
processing element** with zero-skip — plus a cocotb testbench, lint, coverage,
waveform, and GitHub Actions regression. It is a foundation to grow a full
accelerator on, not a finished design.

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
   `ghcr.io/chenbenlu/zynq_cnn-dev:latest` (first time only) -- no local
   compile. On Linux, VS Code auto-remaps the container user to your host UID,
   so files stay yours.
4. In the integrated terminal:

   ```bash
   make lint      # Verilator strict lint + Verible
   make sim       # build + run the cocotb suite (18 tests, 2 seams)
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
docker build -f docker/Dockerfile -t zynq_cnn-dev:latest .

# Run a target. On Linux, pass --user so artifacts in the mounted workspace
# are owned by you rather than the container user.
docker run --rm -v "$PWD":/workspace -w /workspace \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  zynq_cnn-dev:latest make sim
```

With rootless podman, drop `--user` and let `keep-id` do the mapping:

```bash
podman build -f docker/Dockerfile -t zynq_cnn-dev:latest .
podman run --rm --userns=keep-id -v "$PWD":/workspace -w /workspace \
  -e HOME=/tmp zynq_cnn-dev:latest make sim
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

The acceleration-flow targets (`make hls`, `make xclbin`) still depend on work
that has not been done yet — an HLS kernel and a platform — and each says
exactly what it is waiting for.

### Target boards

| Board | Device | Programmed via |
|-------|--------|----------------|
| KV260 (primary) | ZU5EV | SD-card boot + firmware overlay from Linux |
| ZCU104 | ZU7EV | traditional PetaLinux flow |

Both devices are covered by the free Vivado ML Standard Edition; no licence
purchase is needed. The KV260 is cabled directly to the build host's second NIC
on a private segment — [ADR-0003](docs/adr/0003-kv260-direct-attached-to-build-host.md).

## Continuous Integration

Two GitHub Actions workflows:

- **build-image.yml** — builds the toolchain image and pushes it to **GHCR**
  (`ghcr.io/<owner>/zynq_cnn-dev`). Runs only when `docker/**` or
  `pyproject.toml` change, plus manual dispatch.
- **ci.yml** — runs `lint → format-check → sim → coverage` inside that GHCR
  image on every push/PR and uploads waveforms + coverage as artifacts.

> **Bootstrap order:** run **build-image.yml** once (it must publish the image
> before **ci.yml** can pull it). For a private repo, ensure the package grants
> the repo `read` access.

## Project layout

```
rtl/        SystemVerilog sources (sparse_cnn_pkg, sparse_mac_pe, sparse_cnn_axi)
tb/         cocotb testbenches + pytest runners
flows/      synthesis flows — common/ (board map), embedded/, accel/
scripts/    lint / format / regress / wave + Vivado provisioning helpers
docker/     Dockerfile (simulation) + vivado.Dockerfile (synthesis)
sim/        simulation artifacts, waveforms, coverage (gitignored)
build/      synthesis + implementation artifacts (gitignored)
docs/       architecture notes, register map, extension guide, ADRs
CONTEXT.md  project glossary
```

See [docs/architecture.md](docs/architecture.md) for the data flow and how to
extend the single PE into a PE array, and
[docs/register-map.md](docs/register-map.md) for the interface a PS-side driver
is written against.
