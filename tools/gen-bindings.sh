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
# Regenerate bindings/<lang> from kaya::spec (kaya-bindgen) — the one
# spelling of the invocation.
#
# Usage: tools/gen-bindings.sh [--check]   (--check fails on stale or
# ungeneratable bindings and touches nothing)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The generator's source, hashed: content-only, not mtime
# (docs/traps.md).
kaya_generator_id() {
    cat "$1"/tools/kaya-bindgen/src/*.rs | shasum -a 256 | cut -c1-16
}
cd "$ROOT/tools/kaya-bindgen"

# KAYA_REGENERATING exempts this one build from the staleness refusal in
# crates/kaya/build.rs: the generator depends on the kaya crate, so
# without it a generator edit deadlocks against its own staleness.
KAYA_REGENERATING=1 cargo run --quiet -- "$ROOT" "$@"

# The generator's own fingerprint, stamped beside what it produced, so a
# cheap gate can ask "was this regenerated?" in milliseconds
# (docs/traps.md). Written only on a real generation — --check must not
# move it, or the stamp certifies the staleness it exists to catch.
if [ "${1:-}" != "--check" ]; then
    kaya_generator_id "$ROOT" >"$ROOT/bindings/.generator-id"
fi
