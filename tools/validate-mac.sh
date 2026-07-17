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
tools/check-sugar-surface.sh || exit 1
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
            # The confusing failure class: verdict printed OK but the
            # leg still failed — the process never exited (a broken
            # Stage::finish exit path, once bitten on GTK and WinUI).
            if grep -q "KAYA_SELFTEST: OK" "$LEGS_DIR/$name.log" 2>/dev/null; then
                echo "$name: note — verdict was OK but the process did not exit cleanly (finish()/exit-path bug?)"
            fi
            status=1
        fi
        echo "$name: $verdict"
    done
    leg_names=()
}

# The OCaml guests: one dune build covers the binding library and all
# four scenes (dune-project at the repo root scopes to bindings/ and
# guests/).
dune build || exit 1

# The Haskell guests: one cabal build for the binding library and all
# four scenes; list-bin locates the outputs.
(cd guests/haskell && cabal build all \
    --extra-lib-dirs="$ROOT/target/debug" \
    --ghc-options="-optl-Wl,-rpath,$ROOT/target/debug" -v0) || exit 1
hs_bin() { (cd guests/haskell && cabal list-bin "$1" -v0); }

# dotnet run and go run rebuild per invocation; build each guest once
# and let the legs exec the outputs.
dotnet build --nologo -v q guests/csharp/kaya-guests.csproj >/dev/null || exit 1
CS_GUEST="guests/csharp/bin/Debug/net10.0/kaya-guests.dll"
mkdir -p target/go-guests
for guest in milestone2 entry gallery todos encodebench; do
    go build -o "target/go-guests/$guest" "dev.kaya/guests/go/$guest" || exit 1
done

# The encode-benchmark leg: the generated encoders must clear their
# floor rates (structural-regression guard, not a race).
CS_GUEST="$CS_GUEST" tools/bench-encode.sh || exit 1

# All guests against the AppKit backend.
run rust target/debug/examples/milestone2
run python python3 guests/python/milestone2.py
run go target/go-guests/milestone2
run csharp env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run ocaml env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/milestone2.exe
run haskell "$(hs_bin milestone2)"

# The entry scene (uncontrolled text field; text arrives as occurrences
# the app folds into its own state), every language against AppKit. The
# inner env overrides run()'s KAYA_SELFTEST=1 with the entry script.
run entry-rust env KAYA_SELFTEST=entry target/debug/examples/entry
run entry-python env KAYA_SELFTEST=entry python3 guests/python/entry.py
run entry-go env KAYA_SELFTEST=entry target/go-guests/entry
run entry-csharp env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run entry-ocaml env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/entry.exe
run entry-haskell env KAYA_SELFTEST=entry "$(hs_bin entry)"

# The gallery scene (row + checkbox; toggles arrive as occurrences the
# app answers with the status signal), every language against AppKit.
run gallery-rust env KAYA_SELFTEST=gallery target/debug/examples/gallery
run gallery-python env KAYA_SELFTEST=gallery python3 guests/python/gallery.py
run gallery-go env KAYA_SELFTEST=gallery target/go-guests/gallery
run gallery-csharp env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run gallery-ocaml env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/gallery.exe
run gallery-haskell env KAYA_SELFTEST=gallery "$(hs_bin gallery)"

# The todos scene (records + field projection), every language against
# AppKit.
run todos-rust env KAYA_SELFTEST=todos target/debug/examples/todos
run todos-python env KAYA_SELFTEST=todos python3 guests/python/todos.py
run todos-go env KAYA_SELFTEST=todos target/go-guests/todos
run todos-csharp env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run todos-ocaml env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/todos.exe
run todos-haskell env KAYA_SELFTEST=todos "$(hs_bin todos)"

drain

# The same guests against the SwiftUI backend, selected at runtime:
# identical examples, KAYA_BACKEND=swiftui.
tools/swiftui/build-dylib.sh >/dev/null
export KAYA_BACKEND=swiftui
export KAYA_SWIFTUI_LIB="$ROOT/target/swiftui/libkaya_swiftui.dylib"
# The Swift interpreter reads the scene script from the environment
# (the Rust backends embed theirs at build time). Comments stripped:
# some transports fold newlines into `;`, and a leading comment must
# not swallow the folded script.
scene_script() { grep -v '^#' "tools/scenes/$1.steps"; }
export KAYA_SELFTEST_SCRIPT="$(scene_script milestone2)"
run rust-swiftui target/debug/examples/milestone2
run python-swiftui python3 guests/python/milestone2.py
run go-swiftui target/go-guests/milestone2
run csharp-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run ocaml-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/milestone2.exe
run haskell-swiftui "$(hs_bin milestone2)"
export KAYA_SELFTEST_SCRIPT="$(scene_script entry)"
run entry-rust-swiftui env KAYA_SELFTEST=entry target/debug/examples/entry
run entry-python-swiftui env KAYA_SELFTEST=entry python3 guests/python/entry.py
run entry-go-swiftui env KAYA_SELFTEST=entry target/go-guests/entry
run entry-csharp-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run entry-ocaml-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/entry.exe
run entry-haskell-swiftui env KAYA_SELFTEST=entry "$(hs_bin entry)"
export KAYA_SELFTEST_SCRIPT="$(scene_script gallery)"
run gallery-rust-swiftui env KAYA_SELFTEST=gallery target/debug/examples/gallery
run gallery-python-swiftui env KAYA_SELFTEST=gallery python3 guests/python/gallery.py
run gallery-go-swiftui env KAYA_SELFTEST=gallery target/go-guests/gallery
run gallery-csharp-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run gallery-ocaml-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/gallery.exe
run gallery-haskell-swiftui env KAYA_SELFTEST=gallery "$(hs_bin gallery)"
export KAYA_SELFTEST_SCRIPT="$(scene_script todos)"
run todos-rust-swiftui env KAYA_SELFTEST=todos target/debug/examples/todos
run todos-python-swiftui env KAYA_SELFTEST=todos python3 guests/python/todos.py
run todos-go-swiftui env KAYA_SELFTEST=todos target/go-guests/todos
run todos-csharp-swiftui env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run todos-ocaml-swiftui env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/todos.exe
run todos-haskell-swiftui env KAYA_SELFTEST=todos "$(hs_bin todos)"
unset KAYA_BACKEND KAYA_SWIFTUI_LIB KAYA_SELFTEST_SCRIPT
drain

# The one-line verdict: suites accumulate failures rather than abort,
# so a truncated log must still end with the answer.
if [ "$status" = 0 ]; then echo "validate-mac: ALL PASS"; else echo "validate-mac: FAILURES ABOVE"; fi
exit "$status"
