# CLAUDE.md — zynq_cnn

Sparse CNN FPGA accelerator (Xilinx Zynq target). This repo is an **RTL
simulation skeleton**: SystemVerilog RTL verified with cocotb on Verilator,
all inside a pinned Docker toolchain image. See [README.md](README.md) and
[docs/architecture.md](docs/architecture.md).

## How to run things

All commands assume you are inside the toolchain image / Dev Container (tools on
PATH). From a host shell, prefix with the docker/podman run wrapper from the
README (`--user "$(id -u):$(id -g)"` on docker, `--userns=keep-id` on rootless
podman, so `sim/` stays user-owned).

Simulation targets run in the toolchain image. **Synthesis targets run in a
different container, on one machine only** — see "Two containers" below.

```bash
make lint          # Verilator --lint-only -Wall + verible-verilog-lint
make sim           # build + run cocotb suite via pytest (2 seams, 18 tests, must stay green)
make coverage      # Python (pytest-cov) + RTL (verilator_coverage) -> sim/coverage/
make sec GOLDEN=HEAD   # sequential equivalence check vs a reference revision
make format        # verible-verilog-format --inplace
make format-check  # CI-style: fail if unformatted
make wave          # GTKWave on latest sim/**/dump.vcd (X11) — prefer WaveTrace/TerosHDL in-editor
make regress       # lint -> sim -> coverage (matches CI)
make clean

make synth         # OOC synthesis of one module -> build/<board>/ooc/ (BOARD=, CLK_PERIOD=)
make impl          # place & route the system design -> build/<board>/impl/
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

- `rtl/` — SystemVerilog. `sparse_cnn_pkg.sv` (widths), `sparse_mac_pe.sv` (the
  PE) and `sparse_cnn_axi.sv` (the AXI-wrapped top level, and the default
  `RTL_TOP`).
- `tb/<dut>/tb_<dut>.py` — cocotb coroutines.
- `tb/<dut>/test_<dut>.py` — pytest entry; cocotb 2.x `cocotb_tools.runner`.
- `tb/model/sparse_mac_model.py` — the numpy golden model and operand generator,
  shared by both seams. One definition of correct behaviour, imported, never copied.
- `tb/conftest.py` — adds each `tb/<dut>/` to `sys.path`.
- `scripts/` — lint / format / regress / wave / sec.
  `rtl_sources.sh` holds the RTL source list shared by lint, sec and the synthesis flows.
- `flows/` — synthesis flows: `common/` (board map incl. per-board PL clock
  target, shared env), `embedded/` (`bd/system.tcl` block design, `impl.tcl`,
  `xdc/<board>/`), `accel/`.
- `docs/register-map.md` — the AXI4-Lite map. It is the specification, not a
  description: the wrapper's tests check the RTL against it.
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
- **From 2026.1, Vivado will not launch without a license file — including the free
  tier.** The old "Vivado ML Standard is free and needs no license" rule ended with
  2025.x; 2026.1 uses tiers (Basic free w/ annual renewal, then Core/Pro/Enterprise/Gold)
  and checks for a license at startup. The symptom is `ERROR: Vivado Design Suite cannot
  be launched because a valid license was not found` **before any design is read**, so it
  looks nothing like a device-support problem and cannot be diagnosed from the part name.
  Which devices the free Basic tier covers is not the same list as 2025.x's Standard
  Edition — verify a part empirically rather than citing the old list. **Measured
  2026-09-14: the free Basic tier covers both `xck26` (KV260) and `xczu7ev` (ZCU104)**,
  synthesis and implementation; the log grants licences per device, so
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
- **The KV260 is not on the lab network.** It hangs off the build host's second NIC on
  a private segment (ADR-0003) — the router has no free port, and the workstation VLAN
  blocks the server→workstation direction this flow needs. `192.168.100.x` on `RTXWS`
  is that link, not a stray config.
- oss-cad-suite is intentionally **off** `PATH` (`OSS_CAD_SUITE` env only): its
  `bin/` ships its own `verilator`/`cocotb-config` that would shadow the pinned
  Verilator v5.042. `scripts/sec.sh` puts it on `PATH` for itself.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `chenbenlu/zynq_cnn` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: [`CONTEXT.md`](CONTEXT.md) + [`docs/adr/`](docs/adr/) at the repo root.
See `docs/agents/domain.md`. Three ADRs so far, all about the synthesis environment:
persistent-disk install (0001), shared X socket (0002), direct-attached KV260 (0003).
