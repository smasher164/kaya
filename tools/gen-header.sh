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
# Regenerate crates/kaya/include/kaya.h from the Rust source. The one
# spelling of the cbindgen invocation, so the header cannot drift by
# being regenerated with different flags (or forgotten).
#
# Usage: tools/gen-header.sh [--check]
#
# --check regenerates into a temp file and fails if the checked-in
# header is out of date, touching nothing. The validation scripts run
# this so a stale header fails loudly instead of letting guests compile
# against yesterday's ABI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HEADER=crates/kaya/include/kaya.h

if [ "${1:-}" = "--check" ]; then
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    cbindgen --config crates/kaya/cbindgen.toml --crate kaya \
        --output "$tmp" crates/kaya 2>/dev/null
    if ! diff -u "$HEADER" "$tmp"; then
        echo "$HEADER is stale; regenerate with tools/gen-header.sh" >&2
        exit 1
    fi
else
    cbindgen --config crates/kaya/cbindgen.toml --crate kaya \
        --output "$HEADER" crates/kaya
fi
