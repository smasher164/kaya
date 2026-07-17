#!/usr/bin/env bash
# The encode-benchmark leg: pins "derives target the encoder, not a
# value tree" (DESIGN.md, milestone 3) as a suite gate. Each FFI
# binding encodes 200k collection_insert records through its generated
# wire encoder and must clear a floor rate with ~10x headroom — only a
# structural regression (per-record reflection, tree building) trips
# it. Rust is exempt: its guest surface hands TxOps over an in-process
# channel and never serializes; C is the floor and its encoder is the
# struct layout itself.
#
# Expects the guests already built (validate-mac builds them first);
# each program prints "ENCODE_BENCH: OK (<lang>: <rate> rec/s)".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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
