# CLAUDE.md — zynq_cnn

An **environment** that carries a hand-written accelerator from SystemVerilog to
a running design on a Xilinx Zynq UltraScale+ board — simulation (cocotb on
Verilator, in a pinned Docker toolchain image), lint, sequential equivalence,
synthesis, implementation, firmware overlay and a PS-side driver. A sparse CNN
accelerator is the example that goes through it, not the point of it
([ADR-0006](docs/adr/0006-the-deliverable-is-the-environment.md)). What a module
must present to be carried is
[docs/accelerator-contract.md](docs/accelerator-contract.md). See
[README.md](README.md) and [docs/architecture.md](docs/architecture.md).

## How to run things

All commands assume you are inside the toolchain image / Dev Container (tools on
PATH). From a host shell, prefix with the docker/podman run wrapper from the
README (`--user "$(id -u):$(id -g)"` on docker, `--userns=keep-id` on rootless
podman, so `sim/` stays user-owned).

Simulation targets run in the toolchain image. **Synthesis targets run in a
different container, on one machine only** — see "Two containers" below.

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

- **Toolchain image** (`docker/Dockerfile`) — Verilator/cocotb/Verible. Self-contained,
  published to GHCR, used by CI and the Dev Container. Everything under `make sim`.
- **Vivado image** (`docker/vivado.Dockerfile`) — AMD toolchain *runtime deps only*.
  The toolchain itself is bind-mounted from the build host's persistent disk, **not**
  in the image (ADR-0001: a 100 GB image would sit on a 258 GB partition shared with
  other people's services). Never pushed to a registry, never used by CI.

**Do not merge them.** Adding Vivado to the toolchain image would make every CI
lint/sim run pull tens of GB.

The Vivado image runs only on the **build host** (`RTXWS`). `make synth` on any other
machine fails with a message telling you so.

## Synthesis flows

Two flows run side by side and are deliberately kept apart — different tools,
different artefacts, different notions of success. `CONTEXT.md` defines both;
don't blur the terms.

- `flows/embedded/` — hand-written SystemVerilog → Vivado → `.bit`
- `flows/accel/` — HLS C++ → `v++` → `.xclbin`
- `flows/common/boards.sh` — the board→part map, the single place to add a board

`make synth` (out-of-context synthesis of one module) and `make impl` /
`make bitstream` (the full system design: Zynq PS + interconnect + DMA + the
AXI-wrapped accelerator) both run today. The acceleration-flow targets `hls` and
`xclbin` are real scripts whose prerequisites — an HLS kernel, a platform — do
not exist yet; each **reports exactly what is missing** rather than producing
something broken. If you are asked to "make xclbin work", the actual task is the
missing kernel, not the script.

## Layout

- `rtl/` — SystemVerilog. `accel_contract_pkg.sv` is the environment's; the rest
  belongs to one of the two example accelerators: `sparse_cnn_pkg` /
  `sparse_mac_pe` / `sparse_cnn_axi` (the default `RTL_TOP`) and `relu_pkg` /
  `relu_unit` / `relu_axi`.
- `tb/<dut>/tb_<dut>.py` — cocotb coroutines.
- `tb/<dut>/test_<dut>.py` — pytest entry; cocotb 2.x `cocotb_tools.runner`.
- `tb/model/` — the numpy golden models, one per accelerator, imported by its
  seams and never copied into one.
- `tb/conftest.py` — adds each `tb/<dut>/` to `sys.path`.
- `tests/` — `test-*.sh`, bash tests for the scripts that cannot be exercised
  for real (`provision-board-net.sh` reconfigures the build host's own NICs).
  They stub the command the script acts through and assert on what it tried to
  do; `make test-scripts` runs them anywhere bash does.
- `scripts/` — lint / format / regress / wave / sec.
  `rtl_sources.sh` holds the RTL source list shared by lint, sec and the synthesis flows.
- `flows/` — synthesis flows: `common/` (board map incl. per-board PL clock
  target, shared env), `embedded/` (`bd/system.tcl` block design, `impl.tcl`,
  `xdc/<board>/`), `accel/`.
- `docs/accelerator-contract.md` — what a module must present to get the flows.
  The environment's specification; every conforming accelerator answers to it.
- `docs/register-map.md`, `docs/register-map-relu.md` — one AXI4-Lite map per
  accelerator. Each is the specification for *that* accelerator, not a
  description: its tests check the RTL against it.
- `docker/Dockerfile` — multi-stage; Verilator built from source.
- `docker/vivado.Dockerfile` — AMD toolchain runtime deps (toolchain itself is mounted).
- `.devcontainer/devcontainer.json` — consumes the GHCR image (local `build`
  block is commented out; building it needs ~8 GB RAM). Engine-agnostic: Dev
  Containers adds `--userns=keep-id` itself when the engine is podman, so keep
  podman-specific flags out of it.
- `.github/workflows/` — `build-image.yml` (push to GHCR) + `ci.yml` (consume GHCR).

## Pinned tooling (keep in sync)

Vivado / Vitis **2026.1** (build host only). Chosen because `Xilinx/kria-vitis-platforms`
— the KV260 platform's upstream — tracks it on `main`; that repo stopped cutting release
branches after 2023.2, so any older tools version means pinning an arbitrary commit.
Boards: **KV260** (ZU5EV, primary) and **ZCU104** (ZU7EV) — both covered by the free
Vivado ML Standard Edition.

Verilator **v5.042** · cocotb **2.x** · cocotbext-axi **0.1.25+** · Verible **v0.0-4063-gf831ec18** ·
oss-cad-suite **2026-08-01** (Yosys/eqy/sby, for `make sec`) ·
Python **3.12** · Ubuntu **24.04**. Versions live in
[docker/Dockerfile](docker/Dockerfile); Python deps mirror
[pyproject.toml](pyproject.toml) (single source of truth — update both).

## Conventions

- 2-space indent for SystemVerilog (see `.editorconfig`, `.verible.lint.rules`).
- New DUT: add RTL, copy a `tb/<dut>/` pair, add sources to
  `scripts/rtl_sources.sh` (single list, used by lint, sec and both synthesis
  flows), then `make regress`. RTL must be `-Wall` clean.
- Verible's lint config wants **localparams in CamelCase** (`RegCtrl`), while
  module parameters stay ALL_CAPS (`DATA_W`). The two rules have different
  regexes; `make lint` is the arbiter.
- Tests live at RTL module boundaries and drive only top-level ports. The
  wrapper's tests never reach inside to the PE — the contract it presents to the
  PS is the point, and an internal probe would pass with that contract broken.
- Behaviour-preserving RTL change (retiming, operator rewrite): prove it with
  `make sec GOLDEN=HEAD` rather than trusting the directed tests.
  `SEC_ENGINE=miter` when the state encoding changed.
- Behaviour-preserving block-design change (a width or a cell reference derived
  from the environment rather than written into `bd/system.tcl`): `make sec`
  reads RTL and cannot see it. Compare `Synth Design complete | Checksum:` in
  `$OUT_DIR/vivado.log` — one line per run, the top-level design's — between two
  runs on the same part. Equal checksums mean the same netlist; equal utilisation
  and WNS only mean the two designs cost the same. Give the second run its own
  `OUT_DIR=` or it overwrites the log you are comparing against.
- cocotb 2.x API: `Clock(..., unit="ns")` (not `units`), runner imports from
  `cocotb_tools.runner`, `build(sources=[...])`. Read signed signals via the
  helpers in `tb_sparse_mac_pe.py` (cocotb value-accessor names vary).
- Waveform is **VCD** (cocotb `waves=True`); `wave.sh`/`.gitignore` also handle FST.

## Gotchas (learned during setup)

- Verilator build needs `libfl-dev`/`libfl2` (FlexLexer.h).
- Runtime needs `ccache` (Verilator bakes `ccache g++` into its makefiles) and
  `python3-dev` (cocotb embeds `libpython3.12.so`).
- Verible tarball extracts `bin/` as `700`; Dockerfile `chmod -R a+rX` fixes it.
- `ci.yml` requires the GHCR image to exist first — run `build-image.yml` once.
- **Adding a Python dependency makes CI red for one push.** `ci.yml` pulls
  `zynq_cnn-dev:latest` from GHCR; `build-image.yml` rebuilds it on the same
  push (`docker/**` + `pyproject.toml` are its triggers) but the two run
  concurrently, so the regression runs against the image *without* the new
  package. Let `build-image.yml` finish, then re-run `ci.yml`.
- **Vivado links against `libtinfo.so.5`**, which Ubuntu dropped after 20.04. The
  Vivado image symlinks it to `libtinfo.so.6`; without it the tools abort at startup
  with a shared-library error that looks nothing like a missing-package problem.
- **The build host runs Ubuntu 20.04, which Vivado 2026.1 does not support** (it wants
  22.04.x or 24.04.x). This is fine *only because* the tools run in a 24.04 container.
  Don't "simplify" by running Vivado on the host.
- **KV260's five DPU example overlays were deleted in the 2026.1 migration** of
  `kria-vitis-platforms` (smartcam, benchmark, aibox-reid, defect-detect,
  nlp-smartvision — PR #290): sources, Makefile targets and `OVERLAY_LIST` are all gone,
  and only the platform build remains. Tutorials written against 2025.1 and earlier will
  send you looking for directories that no longer exist — that is not a broken install.
  They are also the nearest worked example of packaging a bitstream as a firmware
  overlay, so when that step gets written, read them out of the git history before
  PR #290 rather than from a checkout.
- **bash cannot export an array.** `export RTL_SOURCES="${RTL_SOURCES[*]}"` on the
  array of the same name assigns to element 0 and exports nothing, so Vivado saw an
  unset variable. The flow scripts flatten into a differently-named scalar
  (`RTL_SOURCE_LIST`) of **absolute** paths — Vivado runs from the output directory,
  so relative paths resolve against the wrong place.
- **IP Integrator cannot evaluate a parameter default that references a package.**
  A module added to a block design is packaged first, and each parameter's default is
  evaluated with no visibility of the package, so `parameter int unsigned DATA_W =
  sparse_cnn_pkg::DATA_W` fails at `create_bd_cell` with `Undefined parameter
  "sparse_cnn_pkg"` — before synthesis runs. Widths that nothing overrides belong in a
  `localparam` sourced from the package; port widths may reference the package freely,
  because a width that does not depend on a user parameter is constant-folded. The
  corollary: **out-of-context synthesis succeeding tells you nothing about whether a
  module can be instantiated in a block design** — the two use different front ends,
  and lint, cocotb and `make sec` all resolve the package correctly too.
- **From 2026.1, Vivado will not launch without a license file — including the free
  tier.** The old "Vivado ML Standard is free and needs no license" rule ended with
  2025.x; 2026.1 uses tiers (Basic free w/ annual renewal, then Core/Pro/Enterprise/Gold)
  and checks for a license at startup. The symptom is `ERROR: Vivado Design Suite cannot
  be launched because a valid license was not found` **before any design is read**, so it
  looks nothing like a device-support problem and cannot be diagnosed from the part name.
  Which devices the free Basic tier covers is not the same list as 2025.x's Standard
  Edition — verify a part empirically rather than citing the old list. **Measured
  2026-09-14: the free Basic tier covers both `xck26` (KV260) and `xczu7ev` (ZCU104)**,
  synthesis, implementation and `write_bitstream`; the log grants licences per device, so
  `Got license for feature 'Vivado_Synthesis' and/or device '<part>'` is the line that
  settles it. The licence is node-locked to eth1's MAC and expires 2027-09-14.
- **Vivado's `settings64.sh` sources its sub-scripts by absolute path**, baked in at
  install time. The container therefore mounts the toolchain at *the same* absolute path
  it was installed to, not a tidy one like `/tools/Xilinx`. Mount it elsewhere and it
  fails with "No such file or directory" naming a path that plainly exists on the host.
- **2026.1 nests as `<prefix>/<version>/<Tool>/`**, where earlier releases used
  `<prefix>/<Tool>/<version>/`. Scripts that hardcode the old shape find nothing and
  report it as "the install went to the wrong place".
- **2026.1 has no `vitis_hls` binary.** HLS is a mode of `v++` (`v++ -c --mode hls`),
  driven by a config file, not the classic `open_project`/`csynth_design` Tcl. Tutorials
  and older repos will hand you Tcl that has nothing to run it.
- **`xsct` is disabled in Vitis 2026.1.** It still exists, still starts, and then prints
  `[ERROR] ********** XSCT is disabled in Vitis 2026.1 release **********`, pointing at
  the Vitis Python console (`vitis -s <script.py>`, UG1400) instead. Every FSBL and PMU
  firmware recipe you will find — `app create -template {Zynq MP FSBL}`, `hsi` commands,
  `setws`/`app build` — is XSCT Tcl with nothing left to run it, the same trap as the
  missing `vitis_hls`. Because the tool launches before refusing, the failure looks like a
  runtime problem rather than a removed feature.
- **The AMD tool launchers need `x11-utils` and `xvfb` even with no GUI.** They probe the
  display with `xlsclients` and, finding none, start their own `Xvfb`; a container missing
  either aborts with `ERROR: <tool> is not available on the system` before reading any
  input. Nothing in that message mentions X, so it reads like a broken install.
  `docker/vivado.Dockerfile` carries both for this reason alone — not for the GUI, which
  needs only the host's X socket (ADR-0002). A `dbus-launch is not available` line also
  appears; that one is a warning and the tools run without it.
- **A tool that starts `Xvfb` keeps `docker run` alive after its own command exits.** The
  child inherits the container's stdout, so the stream never closes and the docker client
  hangs long after the work is done — which looks exactly like the tool itself hanging.
  Redirect the tool's output to a file in the mounted workspace and read it from the host
  afterwards, rather than trying to diagnose a stall that is not one.
- **Vivado echoes a `-source`d script into its log as it reads it**, each line commented
  out, so waiting on that log for a marker matches the script's own text long before the
  run reaches it: `grep 'Reports in'` says `make impl` finished while it is still
  placing. Match the leading `>> ` that only the real `puts` carries. `Exiting Vivado` is
  no better a marker — the block design's out-of-context runs are separate Vivado
  processes whose logs land in the same file, so it appears three times per `make impl`.
- **`write_hw_platform -include_bit` takes the bitstream from the implementation run**,
  not from a file. This repo writes the bitstream from the routed checkpoint
  (`bitstream.tcl`), so the run holds none and the export aborts with `Unable to get BIT
  file from implementation run`. `make xsa` therefore exports without the bitstream; the
  `.bit` sits beside the `.xsa` and bootgen is handed both. Adding `-include_bit` means
  first making `impl` run all the way through bitstream generation, which is a different
  flow, not a missing switch.
- **An overlay that adds a bus node gets one device, and none for its children.**
  The generated `pl.dtsi` wraps everything in an `amba_pl` container with
  `compatible = "simple-bus"`. Applied as written, the kernel creates a platform
  device for `amba_pl` and stops: it creates a device per *added* node and does not
  recurse into a bus handed to it at runtime. The accelerator is then in
  `/sys/firmware/devicetree` and on no bus at all, which looks like a driver problem
  rather than a packaging one. `flows/embedded/overlay.py` therefore splices the
  container's children directly under `&amba`, dropping the container.
- **The FPGA manager does not take `write_bitstream -bin_file` output.** `make
  bitstream` writes `<board>.bin` alongside the `.bit`; the manager wants the file
  bootgen produces from a `[destination_device = pl]` BIF, which is the same size and
  a different format. `make overlay` runs bootgen for this reason. Handing over the
  wrong `.bin` fails at load, not at build.
- **The KV260 is not on the lab network.** It hangs off the build host's second NIC on
  a private segment (ADR-0003) — the router has no free port, and the workstation VLAN
  blocks the server→workstation direction this flow needs. `192.168.100.x` on `RTXWS`
  is that link, not a stray config.
- **`PSU__NUM_F2P0__INTR__INPUTS` is read-only.** IP Integrator derives `pl_ps_irq0`'s
  width from what is connected to the port, so setting it costs a `CRITICAL WARNING:
  [BD 41-737] ... It is read-only` — which also keeps the synthesis run out of the
  cache. Enable `PSU__USE__IRQ0`, connect the source, and let the width follow. One
  source connects directly; a second needs an `xlconcat`.
- **`pl.dtsi` parents its interrupts on `&imux`, which a booted kernel does not have.**
  `imux` is a proxy interrupt controller the *system* device tree defines so one tree
  can serve the A53, R5 and PMU domains, mapping every interrupt 1:1 onto that domain's
  GIC. The board's own tree exports `gic` and nothing else, so the reference resolves
  against nothing and the overlay is rejected at load — reported as the overlay failing
  to apply, naming no symbol. `flows/embedded/overlay.py` rewrites it and checks every
  remaining `&label` against what the board exports.
- **A DMA channel sub-node gets a different interrupt from the IP that owns it.** With
  only mm2s connected, the IP node carries the line the block design drives and the
  channel node gets the next number along, which nothing drives. The driver takes the
  channel's, so it probes and then waits forever: a completion timeout, not a probe
  failure, with nothing in it pointing at the device tree. `overlay.py` gives each
  channel the IP node's entry named for its direction — `interrupt-names` is what ties
  those numbers to the ports on the block design.
- **The generated tree describes no connection between two PL IPs.** Nothing in it says
  the DMA's stream feeds the accelerator, and without a `dmas` property on the client
  the kernel offers no way to ask for that channel. `overlay.py` adds it, derived from
  there being one AXI DMA and one accelerator rather than restated.
- **The board's kernel is built with `CONFIG_STRICT_DEVMEM=y`.** `/dev/mem` maps the
  accelerator's AXI4-Lite registers, which are device memory, but not the system memory
  a DMA descriptor points at — so reading `ACC`/`SKIP` from userspace works and
  submitting a tile cannot. That is why `driver/` exists (ADR-0005), and why it is built
  on the board: the toolchain image has no kernel headers and the Vivado image is x86.
- oss-cad-suite is intentionally **off** `PATH` (`OSS_CAD_SUITE` env only): its
  `bin/` ships its own `verilator`/`cocotb-config` that would shadow the pinned
  Verilator v5.042. `scripts/sec.sh` puts it on `PATH` for itself.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `chenbenlu/zynq_cnn` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: [`CONTEXT.md`](CONTEXT.md) + [`docs/adr/`](docs/adr/) at the repo root.
See `docs/agents/domain.md`. `CONTEXT.md` is in two halves — the environment's
vocabulary, which is permanent, and the example design's, which goes when the
example does.

Six ADRs so far. Three cover the synthesis environment: persistent-disk install
(0001), shared X socket (0002), direct-attached KV260 (0003). Two cover the
board the design runs on: the ZCU104 becoming this project's board (0004) and
the accelerator's driver being in scope while the boot image is not (0005). One
covers what this repository is for: the environment is the deliverable and the
accelerator is its first example (0006), which partially supersedes 0004 and
corrects 0005's alternatives.
