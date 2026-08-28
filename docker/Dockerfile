# syntax=docker/dockerfile:1
# =============================================================================
# Sparse CNN simulation toolchain image
#   Stage 1 (builder):  compile Verilator from a pinned source tag
#   Stage 2 (runtime):  Verilator + Verible + GTKWave + Python/cocotb venv
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
