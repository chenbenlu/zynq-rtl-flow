# The AMD toolchain is the user's install, not the repository's

> **Status:** supersedes the Consequences and "The installer" sections of
> [ADR-0001](0001-vivado-installed-on-persistent-disk.md). Its decision — the
> toolchain is mounted into the Vivado image, not baked into it — stands.

The flows need Vivado / Vitis 2026.1 on `PATH` and a licence. That is all they
need. Until now the repository also carried how one machine got there:
`scripts/provision-vivado.sh` and its install config, which installed the
toolchain to `/home/ubuntu/disk/lab/xilinx` on the maintainer's build host, and
that path was the default in `flows/common/env.sh` and `scripts/vivado-run.sh`.

Under [ADR-0006](0006-the-deliverable-is-the-environment.md) the environment is
the deliverable. Someone who already has Vivado installed — in `/tools/Xilinx`,
by their own IT, on a shared server — met a flow that ignored the toolchain
their shell had already sourced, looked in a directory that only exists on one
machine, and told them to run an installer they did not need. Installing the
AMD toolchain is AMD's installer's job and the user's decision; the repository
has nothing to add to it that is not specific to one host.

## Decision

- A flow uses the toolchain the caller's shell has already set up
  (`XILINX_VIVADO` / `XILINX_VITIS`, exported by `settings64.sh`). Otherwise
  `XILINX_ROOT` names the install prefix. There is no default path.
- `scripts/provision-vivado.sh` and `scripts/vivado-install-config.txt` are
  removed.
- The Vivado image (the `vivado` stage, ADR-0008) is optional: a way to run
  the toolchain on a host whose OS AMD does not support. Its run wrapper mounts nothing it was not asked to:
  the X socket (`GUI=1`) is opt-in; host networking (`HOST_NET`) is on only
  when the licence is node-locked, because FlexLM must see the host's NIC; and the
  container's `$HOME` lives under the user's XDG data directory rather than
  inside the toolchain prefix, which may be shared or read-only.

## Consequences

The maintainer's build host is one configuration of this environment, not its
definition. ADRs 0001–0003 remain the record of why that host is set up the way
it is; nothing in the flows depends on it. Reinstalling the toolchain on that
host is now done with AMD's installer directly, as on any other machine.
