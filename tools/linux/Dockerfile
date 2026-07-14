# Linux validation environment for kaya milestone 0. GTK4 development
# libraries, the four validation languages, and Xvfb for a headless
# display. Built and run by tools/validate-linux.sh; the repo is mounted
# at /work and built inside the container (no cross-compilation: the GTK
# libraries live here).
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang pkg-config libgtk-4-dev \
    curl ca-certificates \
    python3 golang \
    xvfb xauth imagemagick x11-utils \
    weston \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
RUN curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/local/dotnet \
    && rm /tmp/dotnet-install.sh

ENV PATH=/root/.cargo/bin:/usr/local/dotnet:$PATH
# Toolchain policy: clang everywhere (cgo, cc crate).
ENV CC=clang
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

WORKDIR /work
