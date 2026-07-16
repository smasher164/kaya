# Linux validation environment for kaya milestone 0. GTK4 development
# libraries, the four validation languages, and Xvfb for a headless
# display. Built and run by tools/validate-linux.sh; the repo is mounted
# at /work and built inside the container (no cross-compilation: the GTK
# libraries live here).
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang pkg-config libgtk-4-dev \
    curl ca-certificates git \
    python3 golang \
    ocaml-nox opam libffi-dev \
    ghc cabal-install \
    xvfb xauth imagemagick x11-utils \
    weston \
    && rm -rf /var/lib/apt/lists/*

# ctypes-foreign via opam on the system compiler: Debian's ctypes deb
# omits the foreign (libffi) half entirely — its META even dangles.
RUN opam init -a --bare --disable-sandboxing \
    && opam switch create default ocaml-system \
    && opam install -y ocamlfind ctypes ctypes-foreign dune ppxlib
ENV PATH=/root/.opam/default/bin:$PATH

# cabal needs a package index even for local-only builds; fetch it once
# in the image, not per run.
RUN cabal update

RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
RUN curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/local/dotnet \
    && rm /tmp/dotnet-install.sh

ENV PATH=/root/.cargo/bin:/usr/local/dotnet:$PATH
# Toolchain policy: clang everywhere (cgo, cc crate).
ENV CC=clang
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

WORKDIR /work
