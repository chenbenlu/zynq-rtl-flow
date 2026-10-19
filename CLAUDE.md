# CLAUDE.md — zynq-rtl-flow

An **environment** that carries a hand-written accelerator from SystemVerilog to
a running design on a Xilinx Zynq UltraScale+ board: simulation (cocotb on
Verilator, in a pinned Docker toolchain image), lint, sequential equivalence,
synthesis, implementation, firmware overlay and a PS-side driver. The sparse CNN
accelerator is the example carried through it, not the point of it
([ADR-0006](docs/adr/0006-the-deliverable-is-the-environment.md)).

- What a module must present to be carried: [docs/accelerator-contract.md](docs/accelerator-contract.md)
- The path through the stages: [docs/environment.md](docs/environment.md), [README.md](README.md)

## How to run things

Commands assume the toolchain image / Dev Container (tools on PATH). From a host
shell, use the docker/podman run wrapper from the README: `--user "$(id -u):$(id -g)"`
on docker, `--userns=keep-id` on rootless podman, so `sim/` stays user-owned.

Simulation targets run in the toolchain image. **Synthesis targets run in a
different container, on one machine only** — see [Two containers](#two-containers-and-which-is-which).

```bash
make lint          # Verilator --lint-only -Wall + verible-verilog-lint
make sim           # build + run cocotb suite via pytest (3 seams, 31 tests, must stay green)
make test-scripts  # bash tests for scripts/ (no RTL toolchain, no root, no hardware)
make coverage      # Python (pytest-cov) + RTL (verilator_coverage) -> sim/coverage/
make sec GOLDEN=HEAD   # sequential equivalence check vs a reference revision
make format        # verible-verilog-format --inplace
make format-check  # CI-style: fail if unformatted
make wave          # GTKWave on latest sim/**/dump.vcd (X11) — prefer WaveTrace/TerosHDL in-editor
make regress       # test-scripts -> lint -> sim -> coverage (matches CI)
make clean

make synth         # OOC synthesis of one module -> build/<board>/ooc/ (BOARD=, CLK_PERIOD=)
make impl          # place & route the system design -> build/<board>/impl/
make bitstream     # .bit/.bin from the routed checkpoint
make xsa           # hardware handoff for the PS-side boot flow -> build/<board>/impl/<board>.xsa
make boot          # FSBL + PMU firmware + device tree from the handoff
make overlay       # bitstream + device tree overlay -> build/<board>/overlay/<app>/
make hls           # Vitis HLS kernel -> .xo  (KERNEL=)
make xclbin        # v++ link -> .xclbin
make vivado-image  # build the Vivado container (run on the build host)
make vivado-shell  # shell inside it
```

## Two containers, and which is which

| | Toolchain image | Vivado image |
|---|---|---|
| Dockerfile | `docker/Dockerfile` | `docker/vivado.Dockerfile` |
| Contains | Verilator/cocotb/Verible, self-contained | AMD toolchain *runtime deps only*; the toolchain is bind-mounted from the build host's persistent disk |
| Published | GHCR; used by CI and the Dev Container | never pushed, never used by CI |
| Runs | anywhere — everything under `make sim` | only on the **build host** (`RTXWS`) |

The toolchain is not in the Vivado image because a 100 GB image would sit on a
258 GB partition shared with other people's services (ADR-0001). `make synth` on
any other machine fails with a message saying so.

**Keep the two images separate.** Adding Vivado to the toolchain image would make
every CI lint/sim run pull tens of GB.

## Synthesis flows

Two flows, deliberately kept apart — different tools, different artefacts,
different notions of success. `CONTEXT.md` defines both; keep the terms distinct.

- `flows/embedded/` — hand-written SystemVerilog → Vivado → `.bit`
- `flows/accel/` — HLS C++ → `v++` → `.xclbin`
- `flows/common/boards.sh` — the board→part map, the single place to add a board

`make synth` (out-of-context synthesis of one module) and `make impl` /
`make bitstream` (the full system design: Zynq PS + interconnect + DMA + the
AXI-wrapped accelerator) run today. `hls` and `xclbin` are real scripts whose
prerequisites — an HLS kernel, a platform — do not exist yet; each **reports
exactly what is missing** instead of producing something broken. Asked to "make
xclbin work", the actual task is the missing kernel, not the script.

## Layout

- `rtl/` — SystemVerilog. `accel_contract_pkg.sv` is the environment's; the rest
  belongs to one of the two example accelerators: `sparse_cnn_pkg` /
  `sparse_mac_pe` / `sparse_cnn_axi` (the default `RTL_TOP`) and `relu_pkg` /
  `relu_unit` / `relu_axi`.
- `tb/<dut>/tb_<dut>.py` — cocotb coroutines. `tb/<dut>/test_<dut>.py` — pytest
  entry, cocotb 2.x `cocotb_tools.runner`.
- `tb/model/` — numpy golden models, one per accelerator, imported by its seams,
  never copied into one.
- `tb/conftest.py` — adds each `tb/<dut>/` to `sys.path`.
- `tests/test-*.sh` — bash tests for scripts that cannot be exercised for real
  (`provision-board-net.sh` reconfigures the build host's own NICs; `boot.sh` and
  `overlay.py` need the AMD toolchain and a routed design). They stub what the
  script acts through — a command, or the generated device tree — and assert on
  what it tried to do; `make test-scripts` runs them anywhere bash does.
- `scripts/` — lint / format / regress / wave / sec. `rtl_sources.sh` holds the
  RTL source list shared by lint, sec and the synthesis flows.
- `flows/` — `common/` (board map incl. per-board PL clock target, shared env),
  `embedded/` (`bd/system.tcl` block design, `impl.tcl`, `xdc/<board>/`), `accel/`.
- `docs/accelerator-contract.md` — the environment's specification; every
  conforming accelerator answers to it.
- `docs/environment.md` — the path a conforming accelerator takes and what each
  stage hands to the next.
- `docs/example-accelerators.md` — the two designs that take it today; it goes
  when they do, like `CONTEXT.md`'s second half.
- `docs/register-map-sparse-cnn.md`, `docs/register-map-relu.md` — one AXI4-Lite
  map per accelerator. Each is the *specification* for that accelerator, not a
  description: its tests check the RTL against it.
- `driver/` — PS-side driver in two layers: `accel_transport.{c,h}` is the
  contract's and moves tiles for any conforming accelerator; `sparse_cnn.c` and
  `relu.c` are one register map each. Three `.ko`s, built on the board.
  `run-tile.py` checks either one against `tb/model/`.
- `docker/Dockerfile` — multi-stage; Verilator built from source.
- `docker/vivado.Dockerfile` — AMD toolchain runtime deps (toolchain itself is mounted).
- `.devcontainer/devcontainer.json` — consumes the GHCR image (the local `build`
  block is commented out; building needs ~8 GB RAM). Engine-agnostic: Dev
  Containers adds `--userns=keep-id` itself under podman, so podman-specific
  flags stay out of it.
- `.github/workflows/` — `build-image.yml` (push to GHCR) + `ci.yml` (consume GHCR).

## Pinned tooling (keep in sync)

| Tool | Version |
|---|---|
| Vivado / Vitis | **2026.1** (build host only) |
| Verilator | **v5.042** |
| cocotb | **2.x** |
| cocotbext-axi | **0.1.25+** |
| Verible | **v0.0-4063-gf831ec18** |
| oss-cad-suite | **2026-08-01** (Yosys/eqy/sby, for `make sec`) |
| Python | **3.12** |
| Ubuntu | **24.04** |

- Versions live in [docker/Dockerfile](docker/Dockerfile); Python deps mirror
  [pyproject.toml](pyproject.toml), the single source of truth — update both.
- **Why 2026.1:** `Xilinx/kria-vitis-platforms`, the KV260 platform's upstream,
  tracks it on `main`. That repo stopped cutting release branches after 2023.2,
  so any older tools version means pinning an arbitrary commit.
- **Boards:** **KV260** (ZU5EV, primary) and **ZCU104** (ZU7EV), both covered by
  the free **Basic** tier, which from 2026.1 still requires a licence file — see
  [the licence gotcha](#the-amd-toolchain-and-what-20261-moved).

## Conventions

- 2-space indent for SystemVerilog (`.editorconfig`, `.verible.lint.rules`).
- **New DUT:** add RTL, copy a `tb/<dut>/` pair, add sources to
  `scripts/rtl_sources.sh` (the single list for lint, sec and both synthesis
  flows), then `make regress`. RTL must be `-Wall` clean.
- **Naming:** Verible wants **localparams in CamelCase** (`RegCtrl`) and module
  parameters in ALL_CAPS (`DATA_W`). The two rules have different regexes;
  `make lint` is the arbiter.
- **Tests drive only top-level ports** at RTL module boundaries. The wrapper's
  tests stay out of the PE: the contract it presents to the PS is the point, and
  an internal probe would pass with that contract broken.
- **Behaviour-preserving RTL change** (retiming, operator rewrite): prove it with
  `make sec GOLDEN=HEAD` rather than trusting the directed tests.
  `SEC_ENGINE=miter` when the state encoding changed.
- **Behaviour-preserving block-design change** (a width or cell reference derived
  from the environment rather than written into `bd/system.tcl`): `make sec`
  reads RTL and cannot see it. Compare `Synth Design complete | Checksum:` in
  `$OUT_DIR/vivado.log` — one line per run, the top-level design's — between two
  runs on the same part. Equal checksums mean the same netlist; equal utilisation
  and WNS only mean the two designs cost the same. Give the second run its own
  `OUT_DIR=` or it overwrites the log you are comparing against.
- **cocotb 2.x API:** `Clock(..., unit="ns")` (not `units`), runner imports from
  `cocotb_tools.runner`, `build(sources=[...])`. Read signed signals via the
  helpers in `tb_sparse_mac_pe.py` (cocotb value-accessor names vary).
- **Waveform** is **VCD** (cocotb `waves=True`); `wave.sh`/`.gitignore` also handle FST.

## Gotchas (learned during setup)

Each entry: **symptom** → cause → what the repo does about it.

### The toolchain image and CI

- **Verilator build** needs `libfl-dev`/`libfl2` (FlexLexer.h).
- **Runtime** needs `ccache` (Verilator bakes `ccache g++` into its makefiles) and
  `python3-dev` (cocotb embeds `libpython3.12.so`).
- **Verible tarball** extracts `bin/` as `700`; the Dockerfile's `chmod -R a+rX` fixes it.
- **`ci.yml` requires the GHCR image to exist first** — run `build-image.yml` once.
- **Adding a Python dependency makes CI red for one push.** `ci.yml` pulls
  `zynq-rtl-flow-dev:latest` from GHCR; `build-image.yml` rebuilds it on the same
  push (`docker/**` + `pyproject.toml` are its triggers), but the two run
  concurrently, so the regression runs against the image *without* the new
  package. Let `build-image.yml` finish, then re-run `ci.yml`.
- **oss-cad-suite is intentionally off `PATH`** (`OSS_CAD_SUITE` env only): its
  `bin/` ships its own `verilator`/`cocotb-config`, which would shadow the pinned
  Verilator v5.042. `scripts/sec.sh` puts it on `PATH` for itself.

### The AMD toolchain, and what 2026.1 moved

- **Shared-library error at startup** → Vivado links against `libtinfo.so.5`,
  which Ubuntu dropped after 20.04. The Vivado image symlinks it to
  `libtinfo.so.6`. The error looks nothing like a missing-package problem.
- **The build host runs Ubuntu 20.04, which Vivado 2026.1 does not support** (it
  wants 22.04.x or 24.04.x). This works *only because* the tools run in a 24.04
  container. Keep Vivado in the container; running it on the host breaks.
- **KV260 DPU example overlays are gone** → the 2026.1 migration of
  `kria-vitis-platforms` (PR #290) deleted smartcam, benchmark, aibox-reid,
  defect-detect and nlp-smartvision: sources, Makefile targets and `OVERLAY_LIST`.
  Only the platform build remains. Tutorials for 2025.1 and earlier point at
  directories that no longer exist — not a broken install. They are still the
  nearest worked example of packaging a bitstream as a firmware overlay: read
  them from git history before PR #290, not from a checkout.
- **`ERROR: Vivado Design Suite cannot be launched because a valid license was
  not found`**, printed **before any design is read** → from 2026.1 Vivado will
  not launch without a licence file, free tier included. The "ML Standard is free
  and needs no licence" rule ended with 2025.x; 2026.1 has tiers (Basic free with
  annual renewal, then Core/Pro/Enterprise/Gold) and checks at startup. The
  message looks nothing like a device-support problem and cannot be diagnosed
  from the part name.
  - Basic's device list is not 2025.x Standard Edition's — verify a part
    empirically. The settling log line is `Got license for feature
    'Vivado_Synthesis' and/or device '<part>'` (granted per device).
  - **Measured 2026-09-14:** Basic covers `xck26` (KV260) and `xczu7ev` (ZCU104)
    for synthesis, implementation and `write_bitstream`.
  - The licence is node-locked to eth1's MAC and expires 2027-09-14.
- **"No such file or directory" naming a path that plainly exists on the host** →
  `settings64.sh` sources its sub-scripts by the absolute path baked in at
  install time. The container mounts the toolchain at *the same* absolute path
  it was installed to, not a tidy one like `/tools/Xilinx`.
- **"The install went to the wrong place"** → 2026.1 nests as
  `<prefix>/<version>/<Tool>/`; earlier releases used `<prefix>/<Tool>/<version>/`.
  Scripts hardcoding the old shape find nothing.
- **No `vitis_hls` binary in 2026.1.** HLS is a mode of `v++`
  (`v++ -c --mode hls`), driven by a config file, not the classic
  `open_project`/`csynth_design` Tcl. Tutorials and older repos hand you Tcl with
  nothing to run it.
- **`[ERROR] ********** XSCT is disabled in Vitis 2026.1 release **********`** →
  `xsct` still exists and starts, then refuses, pointing at the Vitis Python
  console (`vitis -s <script.py>`, UG1400). Every FSBL and PMU firmware recipe you
  will find — `app create -template {Zynq MP FSBL}`, `hsi` commands,
  `setws`/`app build` — is XSCT Tcl with nothing left to run it. Because the tool
  launches before refusing, it looks like a runtime problem, not a removed feature.
- **`ERROR: <tool> is not available on the system`**, before any input is read →
  the AMD launchers probe the display with `xlsclients` and, finding none, start
  their own `Xvfb`, so they need `x11-utils` and `xvfb` even with no GUI. Nothing
  in the message mentions X, so it reads like a broken install.
  `docker/vivado.Dockerfile` carries both for this reason alone — the GUI needs
  only the host's X socket (ADR-0002). `dbus-launch is not available` also
  appears; it is a warning and the tools run without it.
- **`docker run` hangs after the tool's command exits** → a tool that starts
  `Xvfb` leaves a child holding the container's stdout, so the stream never
  closes. It looks exactly like the tool hanging. Redirect the tool's output to
  a file in the mounted workspace and read it from the host afterwards.
- **Waiting on Vivado's log matches a marker too early** → Vivado echoes a
  `-source`d script into its log as it reads it, each line commented out, so
  `grep 'Reports in'` says `make impl` finished while it is still placing. Match
  the leading `>> ` that only the real `puts` carries. `Exiting Vivado` is no
  better: the block design's out-of-context runs are separate Vivado processes
  logging to the same file, so it appears three times per `make impl`.

### The flows: block design, constraints, handoff

- **Vivado sees an unset `RTL_SOURCES`** → bash cannot export an array.
  `export RTL_SOURCES="${RTL_SOURCES[*]}"` on the array of the same name assigns
  to element 0 and exports nothing. The flow scripts flatten into a
  differently-named scalar (`RTL_SOURCE_LIST`) of **absolute** paths — Vivado runs
  from the output directory, so relative paths resolve against the wrong place.
- **`Undefined parameter "sparse_cnn_pkg"` at `create_bd_cell`**, before
  synthesis → IP Integrator packages a module first and evaluates each parameter
  default with no visibility of the package, so `parameter int unsigned DATA_W =
  sparse_cnn_pkg::DATA_W` fails. Widths nothing overrides belong in a
  `localparam` sourced from the package; port widths may reference the package
  freely, because a width independent of any user parameter is constant-folded.
  Corollary: **out-of-context synthesis succeeding says nothing about whether a
  module can be instantiated in a block design** — different front ends — and
  lint, cocotb and `make sec` all resolve the package correctly too.
- **WNS better than the constraints claim** → an XDC is read in a restricted Tcl
  mode with no `if`; a constraint guarded by one is skipped with the guard:
  `CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in the
  xdc constraint file`. Nothing downstream fails — that is how both boards'
  0.100 ns of clock uncertainty went unapplied for every run before issue #22.
  The guard an XDC can carry is `-quiet` on the `get_*`: an empty object list is
  only `CRITICAL WARNING: [Vivado 12-4739] No valid object(s) found` and the run
  continues. A constraint that genuinely needs a condition belongs in `impl.tcl`,
  which is ordinary Tcl.
- **`Unable to get BIT file from implementation run`** → `write_hw_platform
  -include_bit` takes the bitstream from the implementation run, not a file. This
  repo writes the bitstream from the routed checkpoint (`bitstream.tcl`), so the
  run holds none. `make xsa` exports without the bitstream; the `.bit` sits beside
  the `.xsa` and bootgen is handed both. Adding `-include_bit` means making `impl`
  run all the way through bitstream generation — a different flow, not a missing
  switch.
- **`CRITICAL WARNING: [BD 41-737] ... It is read-only`** →
  `PSU__NUM_F2P0__INTR__INPUTS` is derived by IP Integrator from what is
  connected to `pl_ps_irq0`. Setting it also keeps the synthesis run out of the
  cache. Enable `PSU__USE__IRQ0`, connect the source, and let the width follow.
  One source connects directly; a second needs an `xlconcat`.

### The device tree, the overlay and the board

- **Accelerator is in `/sys/firmware/devicetree` but on no bus** → the generated
  `pl.dtsi` wraps everything in an `amba_pl` container with
  `compatible = "simple-bus"`. The kernel creates a platform device per *added*
  node and does not recurse into a bus handed to it at runtime, so `amba_pl`
  gets one device and its children none. Looks like a driver problem, is a
  packaging one. `flows/embedded/overlay.py` splices the container's children
  directly under `&amba`, dropping the container.
- **Bitstream fails at load, not at build** → the FPGA manager does not take
  `write_bitstream -bin_file` output (`<board>.bin` from `make bitstream`). It
  wants the file bootgen produces from a `[destination_device = pl]` BIF — same
  size, different format. `make overlay` runs bootgen for this reason.
- **The KV260 is not on the lab network.** It hangs off the build host's second
  NIC on a private segment (ADR-0003): the router has no free port, and the
  workstation VLAN blocks the server→workstation direction this flow needs.
  `192.168.100.x` on `RTXWS` is that link, not a stray config.
- **Overlay rejected at load, naming no symbol** → `pl.dtsi` parents its
  interrupts on `&imux`, a proxy interrupt controller the *system* device tree
  defines so one tree can serve the A53, R5 and PMU domains (mapping every
  interrupt 1:1 onto that domain's GIC). The board's own tree exports `gic` and
  nothing else, so the reference resolves against nothing. `overlay.py` rewrites
  it and checks every remaining `&label` against what the board exports.
- **Driver probes, then a completion timeout** → a DMA channel sub-node gets a
  different interrupt from the IP that owns it. With only mm2s connected, the IP
  node carries the line the block design drives and the channel node gets the
  next number along, which nothing drives; the driver takes the channel's.
  Nothing in the timeout points at the device tree. `overlay.py` gives each
  channel the IP node's entry named for its direction — `interrupt-names` ties
  those numbers to the ports on the block design.
- **Second DMA channel reported as having no interrupt** → a node's `interrupts`
  is one `<...>` group however many it holds: the generator writes a
  two-interrupt DMA as `interrupts = < 0 89 4 0 90 4 >`, not two bracketed
  specifiers, so splitting on brackets finds one. Specifier width belongs to the
  interrupt parent and is not in `pl.dtsi`; `overlay.py` derives it from there
  being exactly one specifier per `interrupt-names` entry. A synthetic tree that
  brackets them separately passes either way — that is how this survived
  `tests/test-overlay.sh` until the first two-channel design was built.
- **The kernel offers no way to request the DMA channel** → the generated tree
  describes no connection between two PL IPs; nothing says the DMA's stream feeds
  the accelerator, and the client has no `dmas` property. `overlay.py` adds it,
  derived from there being one AXI DMA and one accelerator rather than restated,
  with one entry per channel sub-node the DMA actually carries: an accelerator
  with an `m_axis` gets `"tx", "rx"`, one without gets `"tx"` alone.
- **A short receive tile looks complete** → a finished AXI DMA descriptor reports
  no residue: `dmaengine_tx_status()` on a completed cookie returns through
  `dma_cookie_status()`, which zeroes residue before the AXI DMA driver's own
  calculation is reached. A transfer ended early by an unexpected `tlast` is
  indistinguishable from one that filled the buffer. What catches it is the
  accelerator's own beat count (`relu_axi`'s `COUNT`), which is why the
  contract's optional stream master is paired with one.
- **A tile cannot be submitted from userspace** → the board's kernel is built with
  `CONFIG_STRICT_DEVMEM=y`, so `driver/` is a kernel module
  ([driver/README.md](driver/README.md) has the full account, ADR-0005 the decision).

## Agent skills

### Issue tracker

GitHub Issues on `chenbenlu/zynq-rtl-flow`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: [`CONTEXT.md`](CONTEXT.md) + [`docs/adr/`](docs/adr/) at the repo
root. See `docs/agents/domain.md`. `CONTEXT.md` has two halves: the environment's
vocabulary (permanent) and the example design's (goes when the example does).

| ADR | Area | Decision |
|---|---|---|
| 0001 | synthesis environment | Vivado installed on the persistent disk |
| 0002 | synthesis environment | Vivado container shares the host X socket |
| 0003 | synthesis environment | KV260 direct-attached to the build host |
| 0004 | the board | ZCU104 becomes this project's board |
| 0005 | the board | the accelerator's driver is in scope; the boot image is not |
| 0006 | what the repo is for | the environment is the deliverable, the accelerator its first example — partially supersedes 0004, corrects 0005's alternatives |
| 0007 | what the repo is for | rename to zynq-rtl-flow — supersedes 0006's decision to keep the old name |
