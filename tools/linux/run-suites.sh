#!/usr/bin/env bash
# Runs inside the container (see tools/validate-linux.sh): builds kaya
# against the container's GTK and runs the milestone-0 validations under
# both display protocols — X11 (Xvfb) and Wayland (headless Weston). The
# repo is mounted at /work; Linux build artifacts go to target-linux so
# they never collide with the host's target directory.
set -uo pipefail

cd /work
export CARGO_TARGET_DIR=/work/target-linux

# --lib builds the cdylib (libkaya.so) that the foreign suites load;
# --example alone would build only the rlib it depends on.
cargo build --lib --example milestone2 || exit 1

LIB="$CARGO_TARGET_DIR/debug/libkaya.so"
status=0

# dotnet writes obj/bin next to the csproj; build in a scratch copy so the
# host's in-tree dotnet artifacts (different RID) are untouched.
mkdir -p /tmp/cs
cp crates/kaya/examples/milestone2.cs crates/kaya/examples/milestone2.csproj \
    bindings/csharp/*.cs /tmp/cs/

# Headless Weston for the Wayland leg.
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
weston --backend=headless --socket=kaya-wayland &>/tmp/weston.log &
WESTON_PID=$!
sleep 2

run() {
    local proto="$1" name="$2"
    shift 2
    echo "== $name ($proto) =="
    local ok=1
    case "$proto" in
        x11)
            KAYA_SELFTEST=1 GDK_BACKEND=x11 timeout 180 xvfb-run -a "$@" || ok=0
            ;;
        wayland)
            KAYA_SELFTEST=1 GDK_BACKEND=wayland WAYLAND_DISPLAY=kaya-wayland \
                timeout 180 "$@" || ok=0
            ;;
    esac
    if [ "$ok" = 1 ]; then
        echo "$name ($proto): PASS"
    else
        echo "$name ($proto): FAIL"
        status=1
    fi
}

# The C guest: the ABI's home language over the function floor.
clang crates/kaya/examples/milestone2.c \
    -I crates/kaya/include -I bindings/c \
    -o /tmp/milestone2-c \
    -L "$CARGO_TARGET_DIR/debug" -lkaya -Wl,-rpath,"$CARGO_TARGET_DIR/debug" \
    || status=1

# The OCaml guest (direct ring: Bigarray data path + noalloc cursor
# stubs). ocamlopt writes its intermediates beside the source, hence the
# copy. The foreign half's findlib name differs across ctypes
# packagings; take whichever exists.
FOREIGN=ctypes-foreign
ocamlfind list 2>/dev/null | grep -q "^ctypes-foreign" || FOREIGN=ctypes.foreign
mkdir -p /tmp/ocaml
cp bindings/ocaml/kaya_ml_stubs.c bindings/ocaml/kaya_wire.ml \
    bindings/ocaml/kaya_runtime.ml bindings/ocaml/kaya_app.ml \
    crates/kaya/examples/milestone2.ml /tmp/ocaml/
(cd /tmp/ocaml && ocamlfind ocamlopt \
    -package "ctypes,$FOREIGN,threads.posix" -linkpkg \
    kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml kaya_app.ml milestone2.ml \
    -o milestone2-ocaml) || status=1

# The Haskell guest (direct ring: inline peeks + the same cursor stubs).
mkdir -p /tmp/haskell
ghc -threaded -O -ibindings/haskell -outputdir /tmp/haskell \
    -o /tmp/haskell/milestone2-hs \
    bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/milestone2.hs \
    -L"$CARGO_TARGET_DIR/debug" -lkaya \
    -optl-Wl,-rpath,"$CARGO_TARGET_DIR/debug" || status=1

for proto in x11 wayland; do
    run "$proto" rust "$CARGO_TARGET_DIR/debug/examples/milestone2"
    run "$proto" c /tmp/milestone2-c
    run "$proto" python env KAYA_LIB="$LIB" python3 crates/kaya/examples/milestone2.py
    run "$proto" go go run crates/kaya/examples/milestone2.go
    run "$proto" csharp env KAYA_LIB="$LIB" dotnet run --project /tmp/cs/milestone2.csproj
    run "$proto" ocaml env KAYA_LIB="$LIB" /tmp/ocaml/milestone2-ocaml
    run "$proto" haskell /tmp/haskell/milestone2-hs
done

kill "$WESTON_PID" 2>/dev/null

# Best-effort screenshot of the running scene (X11 leg) for visual
# validation.
xvfb-run -a bash -c "
    \"$CARGO_TARGET_DIR/debug/examples/milestone2\" &
    sleep 3
    import -window root /work/target-linux/shot-linux.png
    kill %1
" 2>/dev/null || true

# The one-line verdict: suites accumulate failures rather than abort,
# so a truncated log must still end with the answer.
if [ "$status" = 0 ]; then echo "run-suites: ALL PASS"; else echo "run-suites: FAILURES ABOVE"; fi
exit "$status"
