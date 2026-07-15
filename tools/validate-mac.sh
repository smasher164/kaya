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
cargo build --lib --example milestone2 --example entry || exit 1
tools/gen-header.sh --check || exit 1
tools/gen-bindings.sh --check || exit 1
# The Python surface's guard and mirror semantics, checked headlessly
# (records queue; the core is never entered).
python3 bindings/python/kaya_app_checks.py >/dev/null || { echo "kaya_app checks: FAIL"; exit 1; }
# Fast cross-language/-platform gates: catch cfg'd-backend and guest
# breakage here, in seconds, not on an emulator or VM.
tools/check-targets.sh || exit 1
tools/swift-typecheck.sh || exit 1
tools/java-typecheck.sh || exit 1

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
cp bindings/ocaml/kaya_ml_stubs.c bindings/ocaml/kaya_wire.ml \
    bindings/ocaml/kaya_runtime.ml bindings/ocaml/kaya_app.ml \
    crates/kaya/examples/milestone2.ml crates/kaya/examples/entry.ml \
    crates/kaya/examples/gallery.ml target/ocaml/
(cd target/ocaml && ocamlfind ocamlopt \
    -package ctypes,ctypes-foreign,threads.posix -linkpkg \
    kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml kaya_app.ml milestone2.ml \
    -o milestone2-ocaml) >/dev/null
(cd target/ocaml && ocamlfind ocamlopt \
    -package ctypes,ctypes-foreign,threads.posix -linkpkg \
    kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml kaya_app.ml entry.ml \
    -o entry-ocaml) >/dev/null
(cd target/ocaml && ocamlfind ocamlopt \
    -package ctypes,ctypes-foreign,threads.posix -linkpkg \
    kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml kaya_app.ml gallery.ml \
    -o gallery-ocaml) >/dev/null

# The Haskell guest, likewise compiled once (its intermediates go to
# target/haskell via -outputdir).
mkdir -p target/haskell
ghc -threaded -O -ibindings/haskell -outputdir target/haskell \
    -o target/haskell/milestone2-hs \
    bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/milestone2.hs \
    -L"$ROOT/target/debug" -lkaya \
    -optl-Wl,-rpath,"$ROOT/target/debug" >/dev/null
mkdir -p target/haskell-entry
ghc -threaded -O -ibindings/haskell -outputdir target/haskell-entry \
    -o target/haskell/entry-hs \
    bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/entry.hs \
    -L"$ROOT/target/debug" -lkaya \
    -optl-Wl,-rpath,"$ROOT/target/debug" >/dev/null
mkdir -p target/haskell-gallery
ghc -threaded -O -ibindings/haskell -outputdir target/haskell-gallery \
    -o target/haskell/gallery-hs \
    bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/gallery.hs \
    -L"$ROOT/target/debug" -lkaya \
    -optl-Wl,-rpath,"$ROOT/target/debug" >/dev/null

# All six guests against the AppKit backend.
run rust cargo run --quiet --example milestone2
run python python3 crates/kaya/examples/milestone2.py
run go go run crates/kaya/examples/milestone2.go
run csharp env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet run --project crates/kaya/examples/milestone2.csproj
run ocaml env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/milestone2-ocaml
run haskell target/haskell/milestone2-hs

# The entry scene (uncontrolled text field; text arrives as occurrences
# the app folds into its own state), every language against AppKit. The
# inner env overrides run()'s KAYA_SELFTEST=1 with the entry script.
run entry-rust env KAYA_SELFTEST=entry cargo run --quiet --example entry
run entry-python env KAYA_SELFTEST=entry python3 crates/kaya/examples/entry.py
run entry-go env KAYA_SELFTEST=entry go run crates/kaya/examples/entry.go
run entry-csharp env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet run --project crates/kaya/examples/entry.csproj
run entry-ocaml env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/entry-ocaml
run entry-haskell env KAYA_SELFTEST=entry target/haskell/entry-hs

# The gallery scene (row + checkbox; toggles arrive as occurrences the
# app answers with the status signal), every language against AppKit.
run gallery-rust env KAYA_SELFTEST=gallery cargo run --quiet --example gallery
run gallery-python env KAYA_SELFTEST=gallery python3 crates/kaya/examples/gallery.py
run gallery-go env KAYA_SELFTEST=gallery go run crates/kaya/examples/gallery.go
run gallery-csharp env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet run --project crates/kaya/examples/gallery.csproj
run gallery-ocaml env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/gallery-ocaml
run gallery-haskell env KAYA_SELFTEST=gallery target/haskell/gallery-hs

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
run entry-rust-swiftui env KAYA_SELFTEST=entry cargo run --quiet --example entry
run entry-python-swiftui env KAYA_SELFTEST=entry python3 crates/kaya/examples/entry.py
run entry-go-swiftui env KAYA_SELFTEST=entry go run crates/kaya/examples/entry.go
run entry-csharp-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet run --project crates/kaya/examples/entry.csproj
run entry-ocaml-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/entry-ocaml
run entry-haskell-swiftui env KAYA_SELFTEST=entry target/haskell/entry-hs
run gallery-rust-swiftui env KAYA_SELFTEST=gallery cargo run --quiet --example gallery
run gallery-python-swiftui env KAYA_SELFTEST=gallery python3 crates/kaya/examples/gallery.py
run gallery-go-swiftui env KAYA_SELFTEST=gallery go run crates/kaya/examples/gallery.go
run gallery-csharp-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet run --project crates/kaya/examples/gallery.csproj
run gallery-ocaml-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/gallery-ocaml
run gallery-haskell-swiftui env KAYA_SELFTEST=gallery target/haskell/gallery-hs
unset KAYA_BACKEND KAYA_SWIFTUI_LIB

# The one-line verdict: suites accumulate failures rather than abort,
# so a truncated log must still end with the answer.
if [ "$status" = 0 ]; then echo "validate-mac: ALL PASS"; else echo "validate-mac: FAILURES ABOVE"; fi
exit "$status"
