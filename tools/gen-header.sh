#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Regenerate crates/kaya/include/kaya.h from the Rust source — the one
# spelling of the cbindgen invocation.
#
# Usage: tools/gen-header.sh [--check]   (--check fails on a stale
# header and touches nothing)
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
