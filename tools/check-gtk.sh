#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The GTK compile check that check-targets.sh cannot do: gtk-sys needs
# the distro's pkg-config world, so the Linux backend builds nowhere but
# the container. A `cargo check` in the cached image, seconds warm.
#
# It never skips — a gate that quietly passes when docker is down reads
# as "GTK is fine".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

if ! docker info >/dev/null 2>&1; then
    echo "check-gtk: docker is not running — cannot compile the GTK backend." >&2
    echo "check-gtk: start Docker and retry (tools/probe-env.sh reports environments)." >&2
    exit 1
fi

# `docker image ls -q` and not `docker image inspect`: with Docker
# Desktop's containerd image store, inspect reports "No such image" for
# an image that `docker run` starts perfectly well, which would turn
# this gate into a permanent false failure.
if [ -z "$(docker image ls -q kaya-linux 2>/dev/null)" ]; then
    echo "check-gtk: the kaya-linux image is missing — run tools/validate-linux.sh once to build it." >&2
    exit 1
fi

# Same target dir the suite uses; never the mac one, which holds
# host-arch artifacts.
if docker run --rm -v "$ROOT:/work" kaya-linux bash -c '
    cd /work || exit 1
    export CARGO_TARGET_DIR=/work/target-linux
    # BOTH feature configurations, the check-targets rule: without
    # --features harness the Stage impl is configured out entirely.
    # (No apostrophes in here: the block is inside a single-quoted
    # bash -c string and one would close it.)
    cargo check --locked --lib --quiet 2>&1 \
        && cargo check --locked --lib --quiet --features harness 2>&1
'; then
    echo "check-gtk: OK"
else
    echo "check-gtk: FAIL" >&2
    exit 1
fi
