# syntax=docker/dockerfile:1
# =============================================================================
# Vivado image — runtime dependencies for the AMD toolchain.
#
# The toolchain itself is NOT in this image. It is installed on the build host's
# persistent disk and bind-mounted in at /tools/Xilinx; see
# docs/adr/0001-vivado-installed-on-persistent-disk.md for why, and
# scripts/provision-vivado.sh for how it gets there. This image therefore stays
# around 1 GB instead of 100 GB, and is never pushed to a registry.
#
# Build with scripts/vivado-run.sh build.
# =============================================================================

ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive

# Vivado/Vitis are 64-bit binaries linked against a fairly wide set of X, font
# and legacy system libraries. The installer's own dependency check is silent
# about most of them; missing ones surface much later as a GUI that will not
# start or a synthesis run that dies in a shared library.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git make g++ libc6-dev \
        unzip zip xz-utils tar \
        locales net-tools iproute2 \
        libncurses6 libtinfo6 \
        libx11-6 libxext6 libxrender1 libxtst6 libxi6 libsm6 libice6 \
        libxft2 libxrandr2 libxcursor1 libxinerama1 libxss1 \
        libfontconfig1 libfreetype6 fonts-dejavu-core \
        libglib2.0-0 libgtk-3-0 libnss3 libasound2t64 \
        libjpeg-turbo8 libpng16-16 \
        ocl-icd-libopencl1 opencl-headers \
        graphviz \
        python3 python3-venv \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# Vivado still links against libtinfo.so.5, which Ubuntu dropped after 20.04.
# The ABI it uses is unchanged, so pointing the old soname at the current
# library is the accepted workaround; without it the tools abort at startup.
RUN ln -sf /lib/x86_64-linux-gnu/libtinfo.so.6 /lib/x86_64-linux-gnu/libtinfo.so.5

# The installer and several tools misbehave under the C locale.
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Match the build host's user so that files written into the bind-mounted
# workspace and toolchain stay owned by it.
ARG USER_UID=1000
ARG USER_GID=1000
RUN userdel --remove ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && groupadd --gid ${USER_GID} dev \
    && useradd --create-home --shell /bin/bash --uid ${USER_UID} --gid ${USER_GID} dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

# Where the bind-mounted toolchain appears. Nothing is installed here at build
# time — the directory exists so the mount has somewhere to land.
ENV XILINX_ROOT=/tools/Xilinx
RUN mkdir -p ${XILINX_ROOT} && chown dev:dev ${XILINX_ROOT}

USER dev
WORKDIR /workspace
CMD ["bash"]
