# The Vivado image is a stage of the dev image

The Vivado image used to come from its own `docker/vivado.Dockerfile`, on a bare
`ubuntu:24.04`. It is now the `vivado` stage of `docker/Dockerfile`, built
`FROM runtime` — the stage that is published to GHCR as the dev image. Both
were already on 24.04 with the same `dev` user and `/workspace`, so the split
bought nothing but a second container: simulating and synthesising the same
change meant switching between two images with different tools on `PATH`.

## Consequences

One container on the build host runs `make sim` and `make synth` alike. The
published dev image is unchanged: CI and the Dev Container still pull only the
`runtime` stage, so none of the X, GTK and OpenCL libraries or the system-wide
workarounds Vivado needs (`/bin/sh` as bash, the trimmed `/etc/os-release`)
reach them. The Vivado image grows by the size of the dev image, a few GB on
the build host's persistent disk, and its first build compiles Verilator.

Under rootful docker the `dev` user takes the caller's UID through a
`USER_UID`/`USER_GID` build argument that remaps the inherited UID 1000, so
workspace files stay owned by the caller. Rootless podman builds with the
defaults instead: `--userns=keep-id` already runs the container as the caller,
and the remap could not be built anyway, since a directory account's UID lies
outside its own subordinate range.

## Considered options

**Put the Vivado dependencies in the dev image itself.** Rejected: every CI run
would pull libraries only the build host uses, and the workarounds would apply
to simulation too.
