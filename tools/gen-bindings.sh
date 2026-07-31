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

# The generator's source, hashed. Sorted so the shell's glob order
# cannot change the answer, and content-only — a touched file with the
# same bytes is not a different generator (the mtime-versus-hash lesson,
# docs/traps.md).
kaya_generator_id() {
    cat "$1"/tools/kaya-bindgen/src/*.rs | shasum -a 256 | cut -c1-16
}
cd "$ROOT/tools/kaya-bindgen"

# Exit codes propagate through set -e; compile errors stay on stderr.
#
# KAYA_REGENERATING exempts this one build from the staleness refusal in
# crates/kaya/build.rs. The generator DEPENDS on the kaya crate, so
# without it a generator edit would deadlock: the build of the tool that
# fixes the staleness would be the thing the staleness stops.
KAYA_REGENERATING=1 cargo run --quiet -- "$ROOT" "$@"

# THE GENERATOR'S OWN FINGERPRINT, stamped beside what it produced.
#
# `--check` above is the authoritative answer — it regenerates and
# diffs — but it only answers when someone runs it, and a generator
# edit that was never regenerated is invisible until then: the bindings
# still compile, the guest still runs, and the arm you just wrote is
# simply absent. That cost two debugging rounds in one afternoon
# (docs/traps.md). The stamp makes the same question answerable in
# milliseconds, so a cheap gate can ask it constantly.
#
# Written only on a real generation; --check must not move it, or the
# stamp would certify the very staleness it exists to catch.
if [ "${1:-}" != "--check" ]; then
    kaya_generator_id "$ROOT" >"$ROOT/bindings/.generator-id"
fi
