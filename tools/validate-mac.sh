#!/usr/bin/env bash
# Run every milestone-0 validation natively on macOS: the Rust example,
# Python over the function floor, and Go and C# over the direct ring.
# Run inside the dev shell (direnv or `nix develop`), with a logged-in
# GUI session; each suite opens a window briefly.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

cargo build --example milestone0 || exit 1

status=0
run() {
    local name="$1"
    shift
    echo "== $name =="
    if KAYA_SELFTEST=1 timeout 120 "$@"; then
        echo "$name: PASS"
    else
        echo "$name: FAIL"
        status=1
    fi
}

# All four guests against the AppKit backend.
run rust cargo run --quiet --example milestone0
run python python3 crates/kaya/examples/milestone0.py
run go go run crates/kaya/examples/milestone0.go
run csharp env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet run --project crates/kaya/examples/milestone0.csproj

# The same four guests against the SwiftUI backend, selected at runtime:
# identical examples, KAYA_BACKEND=swiftui.
tools/swiftui/build-dylib.sh >/dev/null
export KAYA_BACKEND=swiftui
export KAYA_SWIFTUI_LIB="$ROOT/target/swiftui/libkaya_swiftui.dylib"
run rust-swiftui cargo run --quiet --example milestone0
run python-swiftui python3 crates/kaya/examples/milestone0.py
run go-swiftui go run crates/kaya/examples/milestone0.go
run csharp-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet run --project crates/kaya/examples/milestone0.csproj
unset KAYA_BACKEND KAYA_SWIFTUI_LIB

exit "$status"
