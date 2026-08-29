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
   make sim       # build + run the cocotb suite (5 tests)
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
rtl/        SystemVerilog sources (sparse_cnn_pkg, sparse_mac_pe)
tb/         cocotb testbenches + pytest runners
scripts/    lint / format / regress / wave helpers
docker/     toolchain Dockerfile
sim/        build + run artifacts, waveforms, coverage (gitignored)
docs/       architecture notes & extension guide
```

See [docs/architecture.md](docs/architecture.md) for the data flow and how to
extend the single PE into a PE array with AXI interfaces.
