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
# Regenerate bindings/<lang> from kaya::spec (kaya-bindgen). The one
# spelling of the invocation, so nobody reruns it ad hoc with swallowed
# stderr or an unchecked exit code — a generator that fails to compile
# must never read as "nothing changed".
#
# Usage: tools/gen-bindings.sh [--check]
# --check regenerates in memory and fails if the checked-in files are
# out of date, touching nothing (the gen-header.sh pattern). The
# validation scripts run this so stale or ungeneratable bindings fail
# loudly at the gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/tools/kaya-bindgen"

# Exit codes propagate through set -e; compile errors stay on stderr.
cargo run --quiet -- "$ROOT" "$@"
