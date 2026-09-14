# Vivado is installed on the build host's persistent disk, not baked into the image

Every other tool in this repo lives inside its container image, so a reader will
reasonably expect the Vivado image to be self-contained too. It is not: the
image carries only Vivado's runtime dependencies, and the toolchain itself is
installed to `/home/ubuntu/disk/lab/xilinx` on the build host and bind-mounted
in. The reason is disk. A Vivado + Vitis install needs roughly 250 GB while it
runs and lands at 60–100 GB; the build host's `/var/lib/docker` has 258 GB free
and is shared with Harbor and a Forgejo runner that other people depend on,
whereas `/home/ubuntu/disk` has 686 GB and is ours. Baking the toolchain in
would put a 100 GB image — and a 250 GB install that might not fit at all — on
the partition whose exhaustion takes down someone else's service.

## Consequences

The install step is no longer described by the Dockerfile, so it is described by
`scripts/provision-vivado.sh` and the install config it generates instead;
both are version-controlled, and together with the Dockerfile they remain a
complete, re-runnable description of the environment. Reproducing it on another
machine means running that script rather than pulling an image, and the
installation does not travel with the image. `/home/ubuntu/disk/lab/xilinx` is
therefore load-bearing state that nothing in the container declares — the
provisioning script is where it is written down.

## The installer

The toolchain is installed with AMD's **web installer** rather than the offline
package. We only want one device family, so the offline route would mean
downloading roughly 90 GB to install about 60 GB; the web installer pulls only
what the config selects. The cost is that installing needs network access and an
AMD account at install time, and that the install is not reproducible offline —
if AMD withdraws a release, this script can no longer produce it. Credentials
stay out of the repo: `xsetup -b AuthTokenGen` prompts once and stores a token
under `$HOME/.Xilinx`, which the provisioning script requires before it will
start an install.

## Considered options

**Bake it into the image.** Rejected on the disk arithmetic above.

**Install by hand and `docker commit`.** Rejected because the resulting image
cannot be rebuilt from anything in the repo, which is the property this
repo's entire toolchain setup exists to preserve.
