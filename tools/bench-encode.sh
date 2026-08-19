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
# The encode-benchmark leg (DESIGN.md, milestone 3: "derives target the
# encoder, not a value tree"): each FFI binding encodes 200k
# collection_insert records through its generated wire encoder and must
# clear a floor rate with ~10x headroom. Rust is exempt — its guest
# surface never serializes; C is the floor.
#
# Expects the guests already built; each prints
# "ENCODE_BENCH: OK (<lang>: <rate> rec/s)".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export PYTHONPATH="$ROOT/bindings/python"

CS_GUEST="${CS_GUEST:-guests/csharp/bin/Debug/net10.0/kaya-guests.dll}"

status=0

run() {
    local name="$1"
    shift
    local out
    if out=$("$@" 2>&1) && grep -q "ENCODE_BENCH: OK" <<<"$out"; then
        echo "$out"
    else
        echo "$out"
        echo "bench-encode: $name FAIL"
        status=1
    fi
}

run python python3 guests/python/encode_bench.py
run go target/go-guests/encodebench
run csharp env KAYA_SELFTEST=encodebench dotnet exec "$CS_GUEST"
run ocaml _build/default/guests/ocaml/encodebench.exe
run haskell "$(cd guests/haskell && cabal list-bin encodebench -v0)"

if [ "$status" -ne 0 ]; then
    echo "bench-encode: FAIL"
    exit 1
fi
echo "bench-encode: ALL OK"
