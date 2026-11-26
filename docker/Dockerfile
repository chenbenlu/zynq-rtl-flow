# syntax=docker/dockerfile:1
# =============================================================================
# Sparse CNN toolchain images
#   Stage 1 (builder):  compile Verilator from a pinned source tag
#   Stage 2 (runtime):  Verilator + Verible + GTKWave + Python/cocotb venv
#                       -> the dev image, published to GHCR for CI + Dev Container
#   Stage 3 (vivado):   runtime + AMD toolchain runtime deps, build host only
# Pinned versions keep the image reproducible across local + CI (GHCR).
# =============================================================================

ARG UBUNTU_VERSION=24.04

# -----------------------------------------------------------------------------
# Stage 1: build Verilator (apt ships a version too old for cocotb 2.x --timing)
# -----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS builder

ARG VERILATOR_TAG=v5.042
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates perl python3 make autoconf g++ flex bison \
        ccache help2man zlib1g-dev \
        libfl-dev libfl2 \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${VERILATOR_TAG}" \
        https://github.com/verilator/verilator.git /tmp/verilator \
    && cd /tmp/verilator \
    && autoconf \
    && ./configure --prefix=/opt/verilator \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf /tmp/verilator

# -----------------------------------------------------------------------------
# Stage 2: runtime
# -----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ARG VERIBLE_TAG=v0.0-4063-gf831ec18
ARG OSS_CAD_SUITE_TAG=2026-08-01
ENV DEBIAN_FRONTEND=noninteractive

# Runtime deps: g++/perl/make to compile the Verilator model per run, zlib for
# FST traces, Python venv, GTKWave for waveforms, lcov for genhtml coverage
# reports, sudo for the dev user.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git make \
        g++ perl zlib1g ccache \
        python3 python3-venv python3-pip python3-dev \
        gtkwave \
        lcov \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# Verilator from the builder stage.
COPY --from=builder /opt/verilator /opt/verilator

# Verible: pinned prebuilt static binaries.
RUN curl -fsSL \
        "https://github.com/chipsalliance/verible/releases/download/${VERIBLE_TAG}/verible-${VERIBLE_TAG}-linux-static-x86_64.tar.gz" \
        -o /tmp/verible.tar.gz \
    && mkdir -p /opt/verible \
    && tar -xzf /tmp/verible.tar.gz -C /opt/verible --strip-components=1 \
    && chmod -R a+rX /opt/verible \
    && rm /tmp/verible.tar.gz

# oss-cad-suite: Yosys + eqy + sby + SMT/AIG solvers, for `make sec`
# (sequential equivalence checking). Deliberately NOT added to PATH — its bin/
# ships its own verilator and cocotb-config, which would shadow the pinned
# Verilator v5.042 and break the cocotb flow. scripts/sec.sh picks it up via
# OSS_CAD_SUITE instead.
RUN curl -fsSL \
        "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_SUITE_TAG}/oss-cad-suite-linux-x64-$(echo "${OSS_CAD_SUITE_TAG}" | tr -d '-').tgz" \
        -o /tmp/oss-cad-suite.tgz \
    && mkdir -p /opt/oss-cad-suite \
    && tar -xzf /tmp/oss-cad-suite.tgz -C /opt/oss-cad-suite --strip-components=1 \
    && chmod -R a+rX /opt/oss-cad-suite \
    && rm /tmp/oss-cad-suite.tgz
ENV OSS_CAD_SUITE=/opt/oss-cad-suite

# Python virtualenv with cocotb 2.x + verification deps.
# NOTE: keep these versions in sync with pyproject.toml (single source of truth).
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "${VIRTUAL_ENV}"
ENV PATH="${VIRTUAL_ENV}/bin:/opt/verilator/bin:/opt/verible/bin:${PATH}"
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir \
        "cocotb>=2.0,<3.0" \
        "cocotbext-axi>=0.1.25" \
        "numpy>=1.26" \
        "pytest>=8.0" \
        "pytest-cov>=5.0"

# Non-root user so files created in a mounted workspace stay user-owned and to
# match the devcontainer remoteUser. Ubuntu 24.04's base image ships a default
# "ubuntu" user at UID/GID 1000; remove it so "dev" can take 1000 and line up
# with the typical host UID. Matching UIDs keeps bind-mounted files (including a
# mounted ~/.claude with 0600 credentials) readable without a UID remap.
RUN userdel --remove ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && groupadd --gid 1000 dev \
    && useradd --create-home --shell /bin/bash --uid 1000 --gid 1000 dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev

USER dev
WORKDIR /workspace

CMD ["bash"]

# -----------------------------------------------------------------------------
# Stage 3: vivado — runtime dependencies for the AMD toolchain.
#
# The toolchain itself is NOT in this image. It is installed on the build host's
# persistent disk and bind-mounted in at the same absolute path it was installed
# to (settings64.sh sources its sub-scripts by absolute path, so the mount point
# is not ours to choose); see docs/adr/0001-vivado-installed-on-persistent-disk.md
# for why, and scripts/provision-vivado.sh for how it gets there. Building on the
# runtime stage puts simulation and synthesis in one container; the image is
# never pushed to a registry (docs/adr/0008-...).
#
# Build with scripts/vivado-run.sh build.
# -----------------------------------------------------------------------------
FROM runtime AS vivado

USER root

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
        libsecret-1-0 libyaml-0-2 libgdk-pixbuf-2.0-0 \
        libjpeg-turbo8 libpng16-16 \
        ocl-icd-libopencl1 opencl-headers \
        graphviz \
        x11-utils xvfb \
        python3 python3-venv \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# x11-utils and xvfb are for the command-line tools, not the GUI. The AMD
# launchers probe the display with xlsclients and, finding none, start their own
# Xvfb; without either, xsct and the Vitis Python console abort with "<tool> is
# not available on the system" before reading any input. Nothing in that message
# mentions X, so it reads like a broken install rather than a container two
# packages short. The GUI itself needs neither — it draws on the host's X socket.

# The runtime library set above is what the installed toolchain's own
# scripts/installLibs.sh asks for (libsecret, libyaml, gdk-pixbuf, gtk, nss,
# ncurses, tinfo, xss, asound). That script installs host packages as root; we
# declare the same dependencies here instead, so the container stays the only
# place they are needed and nothing is installed on the build host.

# Vivado still links against libtinfo.so.5, which Ubuntu dropped after 20.04.
# The ABI it uses is unchanged, so pointing the old soname at the current
# library is the accepted workaround; without it the tools abort at startup.
RUN ln -sf /lib/x86_64-linux-gnu/libtinfo.so.6 /lib/x86_64-linux-gnu/libtinfo.so.5

# The bundled FlexLM tools (lmutil, which the licence diagnostics shell out to)
# are built against the LSB runtime and ask for the loader by its LSB name. It
# is the ordinary loader under another name, and modern Ubuntu ships only the
# ordinary one. Without this the binary reports "No such file or directory"
# about *itself*, which is a thoroughly misleading way to say "missing loader".
RUN ln -sf /lib64/ld-linux-x86-64.so.2 /lib64/ld-lsb-x86-64.so.3

# Several AMD wrapper scripts have a #!/bin/sh shebang but use bash syntax.
# Ubuntu points /bin/sh at dash, which rejects it with "Syntax error: Bad fd
# number" — an error that says nothing about the actual cause.
# dpkg-reconfigure honours the debconf priority rather than a preseed here, so
# the link is set directly — deterministic, and visible to anyone reading this.
RUN ln -sf /bin/bash /bin/sh

# Vivado builds the "Host : ... running 64-bit <os>" line that it stamps into
# every generated file by reading /etc/os-release, and on Ubuntu 24.04 it
# splices the VERSION and VERSION_CODENAME lines in raw rather than taking one
# field. In a report that is cosmetic noise. In the Verilog that IP Integrator
# generates for a block design it is fatal: the extra lines land outside the
# comment, the netlist no longer parses, the wrapper cannot be validated, and
# Vivado quietly substitutes a different top module — so implementation
# succeeds while building the wrong design. Dropping the two fields costs the
# OS name in a header ("unknown") and nothing else; apt has already run.
RUN sed -i -E '/^(VERSION|VERSION_CODENAME)=/d' /etc/os-release

# The installer and several tools misbehave under the C locale.
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Under rootful docker, match the caller's UID/GID so files written into the
# bind-mounted workspace stay owned by them. Rootless podman builds with the
# defaults and runs as the caller via --userns=keep-id (scripts/vivado-run.sh).
# The runtime stage's dev user is 1000.
ARG USER_UID=1000
ARG USER_GID=1000
RUN if [ "${USER_GID}" != 1000 ]; then groupmod --gid "${USER_GID}" dev; fi \
    && if [ "${USER_UID}" != 1000 ]; then usermod --uid "${USER_UID}" dev; fi \
    && chown -R "${USER_UID}:${USER_GID}" /home/dev

# No mount point is created here: it is whatever absolute path the toolchain was
# installed to on the host, and the run wrapper supplies it via XILINX_ROOT.

USER dev
WORKDIR /workspace
CMD ["bash"]
