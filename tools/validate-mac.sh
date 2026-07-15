#!/usr/bin/env bash
# Run every milestone-0 validation natively on macOS: the Rust example,
# Python over the function floor, and Go and C# over the direct ring.
# Run inside the dev shell (direnv or `nix develop`), with a logged-in
# GUI session; each suite opens a window briefly.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --lib as well as --example: the foreign guests load the cdylib, and
# --example alone would leave a stale libkaya.dylib in place. The header
# check keeps guests from compiling against an ABI the source has left
# behind.
cargo build --lib --example milestone2 || exit 1
tools/gen-header.sh --check || exit 1

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

# The OCaml guest compiles once and runs in both backend passes.
# (ocamlopt writes its intermediates beside the source, hence the copy.)
mkdir -p target/ocaml
cp crates/kaya/examples/milestone2.ml crates/kaya/examples/milestone2_ml_stubs.c target/ocaml/
(cd target/ocaml && ocamlfind ocamlopt \
    -package ctypes,ctypes-foreign,threads.posix -linkpkg \
    milestone2_ml_stubs.c milestone2.ml -o milestone2-ocaml) >/dev/null

# The Haskell guest, likewise compiled once (ghc also writes its
# intermediates beside the source).
mkdir -p target/haskell
cp crates/kaya/examples/milestone2.hs crates/kaya/examples/milestone2_hs_stubs.c \
    target/haskell/
(cd target/haskell && ghc -threaded -O -o milestone2-hs \
    milestone2_hs_stubs.c milestone2.hs \
    -L"$ROOT/target/debug" -lkaya \
    -optl-Wl,-rpath,"$ROOT/target/debug") >/dev/null

# All six guests against the AppKit backend.
run rust cargo run --quiet --example milestone2
run python python3 crates/kaya/examples/milestone2.py
run go go run crates/kaya/examples/milestone2.go
run csharp env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet run --project crates/kaya/examples/milestone2.csproj
run ocaml env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/milestone2-ocaml
run haskell target/haskell/milestone2-hs

# The same six guests against the SwiftUI backend, selected at runtime:
# identical examples, KAYA_BACKEND=swiftui.
tools/swiftui/build-dylib.sh >/dev/null
export KAYA_BACKEND=swiftui
export KAYA_SWIFTUI_LIB="$ROOT/target/swiftui/libkaya_swiftui.dylib"
run rust-swiftui cargo run --quiet --example milestone2
run python-swiftui python3 crates/kaya/examples/milestone2.py
run go-swiftui go run crates/kaya/examples/milestone2.go
run csharp-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet run --project crates/kaya/examples/milestone2.csproj
run ocaml-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/milestone2-ocaml
run haskell-swiftui target/haskell/milestone2-hs
unset KAYA_BACKEND KAYA_SWIFTUI_LIB

exit "$status"
