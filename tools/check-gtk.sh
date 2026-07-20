#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The GTK compile check that check-targets.sh cannot do.
#
# check-targets cross-compiles every other cfg'd backend in seconds, but
# not the Linux one: gtk-sys needs the distro's pkg-config world, so it
# builds nowhere but the container. That left the GTK backend — which
# carries the most hand-written layout code of any backend, an entire
# GtkLayoutManager — reachable only through validate-linux, i.e. going
# from "written" straight to a full suite run. Every bug in the first
# cut of the flex layout manager needed docker to surface.
#
# This is the missing rung: a `cargo check` of the Linux target in the
# cached image. With a warm target-linux it answers in seconds, which
# makes it usable in the edit loop the way check-targets is.
#
# It never skips. A gate that quietly passes when docker is down would
# be exactly the false green the repo's fourth invariant forbids — the
# absence of a check must be loud, or it reads as "GTK is fine".
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

# Same target dir the suite uses, so this shares its incremental state
# rather than fighting it; never the mac target dir, which holds
# host-arch artifacts.
if docker run --rm -v "$ROOT:/work" kaya-linux bash -c '
    cd /work || exit 1
    export CARGO_TARGET_DIR=/work/target-linux
    cargo check --lib --quiet 2>&1
'; then
    echo "check-gtk: OK"
else
    echo "check-gtk: FAIL" >&2
    exit 1
fi
