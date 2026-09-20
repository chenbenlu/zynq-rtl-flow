# The repository is renamed to zynq-rtl-flow

> **Status:** supersedes the "The repository keeps its name" paragraph in
> [ADR-0006](0006-the-deliverable-is-the-environment.md)'s Consequences. The
> rest of ADR-0006 stands, and this decision is an argument from it rather than
> against it.

[ADR-0006](0006-the-deliverable-is-the-environment.md) decided the deliverable is
the environment and the accelerator is its example, and then declined to act on
it in the one place the old framing is hardest to miss: "`zynq_cnn`, the GHCR
image and the Dev Container reference each other and the rename buys nothing a
paragraph cannot." The repository is renamed to `zynq-rtl-flow`. The name states
the activity — an RTL flow, from a simulated module to a design running on the
board — and names no application domain, so the accelerator that currently
occupies the environment can be replaced without the name becoming false a
second time.

## What forced the question

ADR-0006's reasoning had two halves. The second one is what failed.

A paragraph does not constrain what gets written next; a name does, because
every document that introduces the project repeats it. Three days after ADR-0006
merged, `.devcontainer/devcontainer.json` still called the container
`zynq_cnn sparse-CNN sim`, and `docs/architecture.md` still opened with "What
this skeleton is", introduced `sparse_mac_pe` as "The example DUT", counted two
test seams where there are three, and placed synthesis "outside this RTL-sim
skeleton" — while `make impl`, `make bitstream`, `make xsa` and `make overlay`
sit in the same repository. That file was touched the day after the ADR merged,
to follow a file rename, and the framing was not noticed even then. Two
documents drifting the same way is not an accident when the name at the top of
both says the project is a CNN.

The first half — that the rename is expensive because the identifiers reference
each other — was not wrong, only unmeasured. Measured: 25 strings across 10
files, one GHCR image to republish under a bootstrap ordering CLAUDE.md already
records for any image change, one Vivado image tag that never leaves the build
host, and a GitHub rename that leaves redirects behind it.

## Considered and rejected

**Keep `zynq_cnn` and fix the documents instead.** This is the option ADR-0006
chose, and it has now been tried: ADR-0006 *is* the paragraph it said the rename
buys nothing over, and the documents drifted back anyway. The evidence against
it is the repository's own state three days later.

**A name with no platform in it** — `rtl-to-board`, `fpga-dev-env`. Rejected
because the portability it promises does not exist. ADR-0001, ADR-0002,
ADR-0003 and ADR-0004 are all decisions about one vendor's toolchain and two
Zynq UltraScale+ boards; nothing here would survive being pointed at a different
vendor's silicon. A name should not offer what the environment cannot do.

**A name covering only simulation** — `verilog-sim-flow`, or similar. Rejected
for exactly the reason `zynq_cnn` is: it names one segment of the path and
promotes it to the whole. Everything from `make synth` onwards — place & route,
the bitstream, the hardware handoff, the firmware overlay, the PS-side driver —
would fall outside a name that says the repository simulates.

## Consequences

The GHCR image becomes `ghcr.io/<owner>/zynq-rtl-flow-dev`. `ci.yml` cannot pull
it until `build-image.yml` has published it, so CI is red for one run after this
merges; the old package is orphaned by the rename rather than moved, and is
deleted by hand.

The GitHub rename leaves a redirect, so existing clones and the `origin` remote
keep working. The `rtxws` remote does not: it is a filesystem path on the build
host, not a URL, and it is repointed by hand along with the worktree it names.

`docs/adr/0004-zcu104-is-this-projects-board.md` and ADR-0006's quotation of it
keep the old name. They record what was decided when it was decided; rewriting
the string would leave ADR-0006 quoting a sentence ADR-0004 never contained.

The name now makes a claim the repository has to keep: that nothing in it is
specific to a sparse CNN. Today that holds — `rtl/sparse_*`,
`docs/register-map-sparse-cnn.md` and `tb/model/sparse_mac_model.py` carry the
example's name because they are the example's, which is the shape ADR-0006 asked
for. A future file that puts an accelerator's name on something the environment
owns is now a visible contradiction rather than a matter of taste.
