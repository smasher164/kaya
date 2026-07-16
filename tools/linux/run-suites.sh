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
cargo build --lib --example milestone2 --example entry --example gallery --example todos || exit 1

LIB="$CARGO_TARGET_DIR/debug/libkaya.so"
status=0

# dotnet writes obj/bin next to the csproj; build in a scratch copy so the
# host's in-tree dotnet artifacts (different RID) are untouched.
mkdir -p /tmp/cs
cp crates/kaya/examples/milestone2.cs crates/kaya/examples/milestone2.csproj \
    crates/kaya/examples/entry.cs crates/kaya/examples/entry.csproj \
    crates/kaya/examples/gallery.cs crates/kaya/examples/gallery.csproj \
    crates/kaya/examples/todos.cs crates/kaya/examples/todos.csproj \
    bindings/csharp/*.cs /tmp/cs/

# Headless Weston for the Wayland leg.
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
weston --backend=headless --socket=kaya-wayland &>/tmp/weston.log &
WESTON_PID=$!
sleep 2

# Legs run in a background pool (KAYA_JOBS wide, KAYA_JOBS=1 for the
# old serial behavior): xvfb-run -a gives each X11 leg its own display,
# and Wayland clients share the one headless compositor. Verdicts print
# in submission order at drain; a FAIL prints its log.
JOBS="${KAYA_JOBS:-8}"
LEGS_DIR="$(mktemp -d)"
leg_names=()
leg_pids=()

run() {
    local proto="$1" name="$2"
    shift 2
    if [ "$JOBS" = 1 ]; then
        echo "== $name ($proto) =="
        if run_one "$proto" "$@"; then
            echo "$name ($proto): PASS"
        else
            echo "$name ($proto): FAIL"
            status=1
        fi
        return
    fi
    (
        if run_one "$proto" "$@" >"$LEGS_DIR/$name-$proto.log" 2>&1; then
            echo PASS >"$LEGS_DIR/$name-$proto.verdict"
        else
            echo FAIL >"$LEGS_DIR/$name-$proto.verdict"
        fi
    ) &
    leg_pids+=($!)
    leg_names+=("$name-$proto")
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do
        wait -n || true
    done
}

run_one() {
    local proto="$1"
    shift
    case "$proto" in
        x11)
            KAYA_SELFTEST=1 GDK_BACKEND=x11 timeout 180 xvfb-run -a "$@"
            ;;
        wayland)
            KAYA_SELFTEST=1 GDK_BACKEND=wayland WAYLAND_DISPLAY=kaya-wayland \
                timeout 180 "$@"
            ;;
    esac
}

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

# The C guests: the ABI's home language over the function floor.
clang crates/kaya/examples/milestone2.c \
    -I crates/kaya/include -I bindings/c \
    -o /tmp/milestone2-c \
    -L "$CARGO_TARGET_DIR/debug" -lkaya -Wl,-rpath,"$CARGO_TARGET_DIR/debug" \
    || status=1
clang crates/kaya/examples/entry.c \
    -I crates/kaya/include -I bindings/c \
    -o /tmp/entry-c \
    -L "$CARGO_TARGET_DIR/debug" -lkaya -Wl,-rpath,"$CARGO_TARGET_DIR/debug" \
    || status=1
clang crates/kaya/examples/gallery.c \
    -I crates/kaya/include -I bindings/c \
    -o /tmp/gallery-c \
    -L "$CARGO_TARGET_DIR/debug" -lkaya -Wl,-rpath,"$CARGO_TARGET_DIR/debug" \
    || status=1
clang crates/kaya/examples/todos.c \
    -I crates/kaya/include -I bindings/c \
    -o /tmp/todos-c \
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
    crates/kaya/examples/milestone2.ml crates/kaya/examples/entry.ml \
    crates/kaya/examples/gallery.ml crates/kaya/examples/todos.ml /tmp/ocaml/
(cd /tmp/ocaml && ocamlfind ocamlopt \
    -package "ctypes,$FOREIGN,threads.posix" -linkpkg \
    kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml kaya_app.ml milestone2.ml \
    -o milestone2-ocaml) || status=1
(cd /tmp/ocaml && ocamlfind ocamlopt \
    -package "ctypes,$FOREIGN,threads.posix" -linkpkg \
    kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml kaya_app.ml entry.ml \
    -o entry-ocaml) || status=1
(cd /tmp/ocaml && ocamlfind ocamlopt \
    -package "ctypes,$FOREIGN,threads.posix" -linkpkg \
    kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml kaya_app.ml gallery.ml \
    -o gallery-ocaml) || status=1
(cd /tmp/ocaml && ocamlfind ocamlopt \
    -package "ctypes,$FOREIGN,threads.posix" -linkpkg \
    kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml kaya_app.ml todos.ml \
    -o todos-ocaml) || status=1

# The Haskell guest (direct ring: inline peeks + the same cursor stubs).
mkdir -p /tmp/haskell
ghc -threaded -O -ibindings/haskell -outputdir /tmp/haskell \
    -o /tmp/haskell/milestone2-hs \
    bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/milestone2.hs \
    -L"$CARGO_TARGET_DIR/debug" -lkaya \
    -optl-Wl,-rpath,"$CARGO_TARGET_DIR/debug" || status=1
mkdir -p /tmp/haskell-entry
ghc -threaded -O -ibindings/haskell -outputdir /tmp/haskell-entry \
    -o /tmp/haskell/entry-hs \
    bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/entry.hs \
    -L"$CARGO_TARGET_DIR/debug" -lkaya \
    -optl-Wl,-rpath,"$CARGO_TARGET_DIR/debug" || status=1
mkdir -p /tmp/haskell-gallery
ghc -threaded -O -ibindings/haskell -outputdir /tmp/haskell-gallery \
    -o /tmp/haskell/gallery-hs \
    bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/gallery.hs \
    -L"$CARGO_TARGET_DIR/debug" -lkaya \
    -optl-Wl,-rpath,"$CARGO_TARGET_DIR/debug" || status=1
mkdir -p /tmp/haskell-todos
ghc -threaded -O -ibindings/haskell -outputdir /tmp/haskell-todos \
    -o /tmp/haskell/todos-hs \
    bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/todos.hs \
    -L"$CARGO_TARGET_DIR/debug" -lkaya \
    -optl-Wl,-rpath,"$CARGO_TARGET_DIR/debug" || status=1

# dotnet run and go run rebuild per invocation; build each guest once
# and let the legs exec the outputs.
for guest in milestone2 entry gallery todos; do
    KAYA_LIB="$LIB" dotnet build --nologo -v q "/tmp/cs/$guest.csproj" >/dev/null || status=1
done
mkdir -p /tmp/go-guests
for guest in milestone2 entry gallery todos; do
    go build -o "/tmp/go-guests/$guest" "crates/kaya/examples/$guest.go" || status=1
done
dotnet_dll() {
    case "$1" in
        milestone2) echo "/tmp/cs/bin/Debug/net10.0/milestone2.dll" ;;
        *) echo "/tmp/cs/bin-$1/Debug/net10.0/$1.dll" ;;
    esac
}

for proto in x11 wayland; do
    run "$proto" rust "$CARGO_TARGET_DIR/debug/examples/milestone2"
    run "$proto" c /tmp/milestone2-c
    run "$proto" python env KAYA_LIB="$LIB" python3 crates/kaya/examples/milestone2.py
    run "$proto" go /tmp/go-guests/milestone2
    run "$proto" csharp env KAYA_LIB="$LIB" dotnet exec "$(dotnet_dll milestone2)"
    run "$proto" ocaml env KAYA_LIB="$LIB" /tmp/ocaml/milestone2-ocaml
    run "$proto" haskell /tmp/haskell/milestone2-hs
    # The entry scene: the inner env overrides run()'s KAYA_SELFTEST=1.
    run "$proto" entry-rust env KAYA_SELFTEST=entry "$CARGO_TARGET_DIR/debug/examples/entry"
    run "$proto" entry-c env KAYA_SELFTEST=entry /tmp/entry-c
    run "$proto" entry-python env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        python3 crates/kaya/examples/entry.py
    run "$proto" entry-go env KAYA_SELFTEST=entry /tmp/go-guests/entry
    run "$proto" entry-csharp env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        dotnet exec "$(dotnet_dll entry)"
    run "$proto" entry-ocaml env KAYA_SELFTEST=entry KAYA_LIB="$LIB" /tmp/ocaml/entry-ocaml
    run "$proto" entry-haskell env KAYA_SELFTEST=entry /tmp/haskell/entry-hs
    # The gallery scene (row + checkbox): the toggle arrives as an
    # occurrence the app answers with the status signal.
    run "$proto" gallery-rust env KAYA_SELFTEST=gallery "$CARGO_TARGET_DIR/debug/examples/gallery"
    run "$proto" gallery-c env KAYA_SELFTEST=gallery /tmp/gallery-c
    run "$proto" gallery-python env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        python3 crates/kaya/examples/gallery.py
    run "$proto" gallery-go env KAYA_SELFTEST=gallery /tmp/go-guests/gallery
    run "$proto" gallery-csharp env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        dotnet exec "$(dotnet_dll gallery)"
    run "$proto" gallery-ocaml env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" /tmp/ocaml/gallery-ocaml
    run "$proto" gallery-haskell env KAYA_SELFTEST=gallery /tmp/haskell/gallery-hs
    # The todos scene (records + field projection): one field's delta
    # travels; the items-left label proves the fold.
    run "$proto" todos-rust env KAYA_SELFTEST=todos "$CARGO_TARGET_DIR/debug/examples/todos"
    run "$proto" todos-c env KAYA_SELFTEST=todos /tmp/todos-c
    run "$proto" todos-python env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        python3 crates/kaya/examples/todos.py
    run "$proto" todos-go env KAYA_SELFTEST=todos /tmp/go-guests/todos
    run "$proto" todos-csharp env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        dotnet exec "$(dotnet_dll todos)"
    run "$proto" todos-ocaml env KAYA_SELFTEST=todos KAYA_LIB="$LIB" /tmp/ocaml/todos-ocaml
    run "$proto" todos-haskell env KAYA_SELFTEST=todos /tmp/haskell/todos-hs
done
drain

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
