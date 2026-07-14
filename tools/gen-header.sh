#!/usr/bin/env bash
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
