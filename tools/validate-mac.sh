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
cargo build --lib --example milestone2 --example entry \
    --example gallery --example todos || exit 1
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

# Legs run in a background pool (KAYA_JOBS wide, KAYA_JOBS=1 for the
# old serial behavior): every guest is its own process with a
# self-contained selftest, so nothing couples one leg to another. Each
# leg logs to its own file; verdicts print in submission order at
# drain, and a FAIL prints its log.
JOBS="${KAYA_JOBS:-8}"
LEGS_DIR="$(mktemp -d)"
trap 'rm -rf "$LEGS_DIR"' EXIT
leg_names=()
leg_pids=()

run() {
    local name="$1"
    shift
    if [ "$JOBS" = 1 ]; then
        echo "== $name =="
        if KAYA_SELFTEST=1 timeout 120 "$@"; then
            echo "$name: PASS"
        else
            echo "$name: FAIL"
            status=1
        fi
        return
    fi
    (
        if KAYA_SELFTEST=1 timeout 120 "$@" >"$LEGS_DIR/$name.log" 2>&1; then
            echo PASS >"$LEGS_DIR/$name.verdict"
        else
            echo FAIL >"$LEGS_DIR/$name.verdict"
        fi
    ) &
    leg_pids+=($!)
    leg_names+=("$name")
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do
        wait -n || true
    done
}

# Collect the pool: print verdicts in submission order, logs for
# failures only.
# Wait on the leg jobs by pid — never a bare `wait`, which would also
# wait on unrelated background children (the Linux suite's Weston runs
# forever; a bare wait deadlocked here once).
drain() {
    if [ ${#leg_pids[@]} -gt 0 ]; then
        wait "${leg_pids[@]}" 2>/dev/null || true
    fi
    leg_pids=()
    local name verdict
    for name in "${leg_names[@]}"; do
        verdict=$(cat "$LEGS_DIR/$name.verdict" 2>/dev/null || echo FAIL)
        echo "== $name =="
        if [ "$verdict" != PASS ]; then
            cat "$LEGS_DIR/$name.log" 2>/dev/null
            status=1
        fi
        echo "$name: $verdict"
    done
    leg_names=()
}

# The OCaml guest compiles once and runs in both backend passes.
# (ocamlopt writes its intermediates beside the source, hence the copy.)
mkdir -p target/ocaml
cp bindings/ocaml/kaya_ml_stubs.c bindings/ocaml/kaya_wire.ml \
    bindings/ocaml/kaya_runtime.ml bindings/ocaml/kaya_app.ml \
    crates/kaya/examples/milestone2.ml crates/kaya/examples/entry.ml \
    crates/kaya/examples/gallery.ml crates/kaya/examples/todos.ml target/ocaml/
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
(cd target/ocaml && ocamlfind ocamlopt \
    -package ctypes,ctypes-foreign,threads.posix -linkpkg \
    kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml kaya_app.ml todos.ml \
    -o todos-ocaml) >/dev/null

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
mkdir -p target/haskell-todos
ghc -threaded -O -ibindings/haskell -outputdir target/haskell-todos \
    -o target/haskell/todos-hs \
    bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/todos.hs \
    -L"$ROOT/target/debug" -lkaya \
    -optl-Wl,-rpath,"$ROOT/target/debug" >/dev/null

# dotnet run and go run rebuild per invocation; build each guest once
# and let the legs exec the outputs.
for guest in milestone2 entry gallery todos; do
    KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
        dotnet build --nologo -v q "crates/kaya/examples/$guest.csproj" >/dev/null || exit 1
done
mkdir -p target/go-guests
for guest in milestone2 entry gallery todos; do
    go build -o "target/go-guests/$guest" "crates/kaya/examples/$guest.go" || exit 1
done
dotnet_dll() {
    case "$1" in
        milestone2) echo "crates/kaya/examples/bin/Debug/net10.0/milestone2.dll" ;;
        *) echo "crates/kaya/examples/bin-$1/Debug/net10.0/$1.dll" ;;
    esac
}

# All guests against the AppKit backend.
run rust target/debug/examples/milestone2
run python python3 crates/kaya/examples/milestone2.py
run go target/go-guests/milestone2
run csharp env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$(dotnet_dll milestone2)"
run ocaml env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/milestone2-ocaml
run haskell target/haskell/milestone2-hs

# The entry scene (uncontrolled text field; text arrives as occurrences
# the app folds into its own state), every language against AppKit. The
# inner env overrides run()'s KAYA_SELFTEST=1 with the entry script.
run entry-rust env KAYA_SELFTEST=entry target/debug/examples/entry
run entry-python env KAYA_SELFTEST=entry python3 crates/kaya/examples/entry.py
run entry-go env KAYA_SELFTEST=entry target/go-guests/entry
run entry-csharp env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$(dotnet_dll entry)"
run entry-ocaml env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/entry-ocaml
run entry-haskell env KAYA_SELFTEST=entry target/haskell/entry-hs

# The gallery scene (row + checkbox; toggles arrive as occurrences the
# app answers with the status signal), every language against AppKit.
run gallery-rust env KAYA_SELFTEST=gallery target/debug/examples/gallery
run gallery-python env KAYA_SELFTEST=gallery python3 crates/kaya/examples/gallery.py
run gallery-go env KAYA_SELFTEST=gallery target/go-guests/gallery
run gallery-csharp env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$(dotnet_dll gallery)"
run gallery-ocaml env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/gallery-ocaml
run gallery-haskell env KAYA_SELFTEST=gallery target/haskell/gallery-hs

# The todos scene (records + field projection), every language against
# AppKit.
run todos-rust env KAYA_SELFTEST=todos target/debug/examples/todos
run todos-python env KAYA_SELFTEST=todos python3 crates/kaya/examples/todos.py
run todos-go env KAYA_SELFTEST=todos target/go-guests/todos
run todos-csharp env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$(dotnet_dll todos)"
run todos-ocaml env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/todos-ocaml
run todos-haskell env KAYA_SELFTEST=todos target/haskell/todos-hs

drain

# The same guests against the SwiftUI backend, selected at runtime:
# identical examples, KAYA_BACKEND=swiftui.
tools/swiftui/build-dylib.sh >/dev/null
export KAYA_BACKEND=swiftui
export KAYA_SWIFTUI_LIB="$ROOT/target/swiftui/libkaya_swiftui.dylib"
run rust-swiftui target/debug/examples/milestone2
run python-swiftui python3 crates/kaya/examples/milestone2.py
run go-swiftui target/go-guests/milestone2
run csharp-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$(dotnet_dll milestone2)"
run ocaml-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/milestone2-ocaml
run haskell-swiftui target/haskell/milestone2-hs
run entry-rust-swiftui env KAYA_SELFTEST=entry target/debug/examples/entry
run entry-python-swiftui env KAYA_SELFTEST=entry python3 crates/kaya/examples/entry.py
run entry-go-swiftui env KAYA_SELFTEST=entry target/go-guests/entry
run entry-csharp-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$(dotnet_dll entry)"
run entry-ocaml-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/entry-ocaml
run entry-haskell-swiftui env KAYA_SELFTEST=entry target/haskell/entry-hs
run gallery-rust-swiftui env KAYA_SELFTEST=gallery target/debug/examples/gallery
run gallery-python-swiftui env KAYA_SELFTEST=gallery python3 crates/kaya/examples/gallery.py
run gallery-go-swiftui env KAYA_SELFTEST=gallery target/go-guests/gallery
run gallery-csharp-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$(dotnet_dll gallery)"
run gallery-ocaml-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/gallery-ocaml
run gallery-haskell-swiftui env KAYA_SELFTEST=gallery target/haskell/gallery-hs
run todos-rust-swiftui env KAYA_SELFTEST=todos target/debug/examples/todos
run todos-python-swiftui env KAYA_SELFTEST=todos python3 crates/kaya/examples/todos.py
run todos-go-swiftui env KAYA_SELFTEST=todos target/go-guests/todos
run todos-csharp-swiftui env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$(dotnet_dll todos)"
run todos-ocaml-swiftui env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    target/ocaml/todos-ocaml
run todos-haskell-swiftui env KAYA_SELFTEST=todos target/haskell/todos-hs
unset KAYA_BACKEND KAYA_SWIFTUI_LIB
drain

# The one-line verdict: suites accumulate failures rather than abort,
# so a truncated log must still end with the answer.
if [ "$status" = 0 ]; then echo "validate-mac: ALL PASS"; else echo "validate-mac: FAILURES ABOVE"; fi
exit "$status"
