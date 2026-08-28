# CLAUDE.md — zynq_cnn

Sparse CNN FPGA accelerator (Xilinx Zynq target). This repo is an **RTL
simulation skeleton**: SystemVerilog RTL verified with cocotb on Verilator,
all inside a pinned Docker toolchain image. See [README.md](README.md) and
[docs/architecture.md](docs/architecture.md).

## How to run things

All commands assume you are inside the toolchain image / Dev Container (tools on
PATH). From a host shell, prefix with the docker run wrapper from the README
(remember `--user "$(id -u):$(id -g)"` on Linux so `sim/` stays user-owned).

```bash
make lint          # Verilator --lint-only -Wall + verible-verilog-lint
make sim           # build + run cocotb suite via pytest (5 tests, must stay green)
make coverage      # Python (pytest-cov) + RTL (verilator_coverage) -> sim/coverage/
make sec GOLDEN=HEAD   # sequential equivalence check vs a reference revision
make format        # verible-verilog-format --inplace
make format-check  # CI-style: fail if unformatted
make wave          # GTKWave on latest sim/**/dump.vcd (X11) — prefer WaveTrace/TerosHDL in-editor
make regress       # lint -> sim -> coverage (matches CI)
make clean
```

## Layout

- `rtl/` — SystemVerilog. `sparse_cnn_pkg.sv` (widths) + `sparse_mac_pe.sv` (DUT).
- `tb/<dut>/tb_<dut>.py` — cocotb coroutines + numpy golden model.
- `tb/<dut>/test_<dut>.py` — pytest entry; cocotb 2.x `cocotb_tools.runner`.
- `tb/conftest.py` — adds each `tb/<dut>/` to `sys.path`.
- `scripts/` — lint / format / regress / wave / sec.
  `rtl_sources.sh` holds the RTL source list shared by lint and sec.
- `docker/Dockerfile` — multi-stage; Verilator built from source.
- `.github/workflows/` — `build-image.yml` (push to GHCR) + `ci.yml` (consume GHCR).

## Pinned tooling (keep in sync)

Verilator **v5.042** · cocotb **2.x** · Verible **v0.0-4063-gf831ec18** ·
oss-cad-suite **2026-08-01** (Yosys/eqy/sby, for `make sec`) ·
Python **3.12** · Ubuntu **24.04**. Versions live in
[docker/Dockerfile](docker/Dockerfile); Python deps mirror
[pyproject.toml](pyproject.toml) (single source of truth — update both).

## Conventions

- 2-space indent for SystemVerilog (see `.editorconfig`, `.verible.lint.rules`).
- New DUT: add RTL, copy a `tb/<dut>/` pair, add sources to
  `scripts/rtl_sources.sh` (single list, used by lint and sec), then
  `make regress`. RTL must be `-Wall` clean.
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
- oss-cad-suite is intentionally **off** `PATH` (`OSS_CAD_SUITE` env only): its
  `bin/` ships its own `verilator`/`cocotb-config` that would shadow the pinned
  Verilator v5.042. `scripts/sec.sh` puts it on `PATH` for itself.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `chenbenlu/zynq_cnn` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
