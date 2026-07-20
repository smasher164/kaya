#!/usr/bin/env bash
# Runs inside the container (see tools/validate-linux.sh): builds kaya
# against the container's GTK and runs the milestone-0 validations under
# both display protocols — X11 (Xvfb) and Wayland (headless Weston). The
# repo is mounted at /work; Linux build artifacts go to target-linux so
# they never collide with the host's target directory.
set -uo pipefail

cd /work || exit 1
export CARGO_TARGET_DIR=/work/target-linux
# harness-extract.sh (recording mode) refuses to run outside the dev
# shell, and the container is not one — it is the pinned image, which is
# the same guarantee by other means. Hand it the fingerprint it checks
# for so recording mode works in here; without this every leg passed and
# then produced no stills at all.
KAYA_DEV_SHELL="$(cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
export KAYA_DEV_SHELL
# The one Python import mechanism: the kaya package resolves from
# here (the guests' sys.path shims are gone).
export PYTHONPATH=/work/bindings/python
# Dune resolves external libraries through OCAMLPATH, which only opam
# env provides — the image's bare PATH export is enough for ocamlfind
# (its config is baked in) but not for dune.
eval "$(opam env 2>/dev/null)" || true

# --lib builds the cdylib (libkaya.so) that the foreign suites load;
# --example alone would build only the rlib it depends on.
cargo build --lib --example milestone2 --example entry --example gallery --example todos --example reorder --example feed --example grow --example layout || exit 1

LIB="$CARGO_TARGET_DIR/debug/libkaya.so"
status=0

# dotnet writes obj/bin next to the csproj; build in a scratch copy so the
# host's in-tree dotnet artifacts (different RID) are untouched.
mkdir -p /tmp/cs
cp guests/csharp/*.cs guests/csharp/kaya-guests.csproj bindings/csharp/*.cs /tmp/cs/

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
        if run_one "$proto" "$name" "$@"; then
            echo "$name ($proto): PASS"
        else
            echo "$name ($proto): FAIL"
            status=1
        fi
        return
    fi
    (
        if run_one "$proto" "$name" "$@" >"$LEGS_DIR/$name-$proto.log" 2>&1; then
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

# Recording mode (KAYA_RECORD=1): every leg — both protocols — runs
# inside its own Xvfb and is filmed there by record-leg.sh (wayland
# via a nested per-leg Weston on the X11 backend). One window per
# private display: the film is the leg, no crops or tiling needed.
# 24-bit screens either way; x11grab cannot encode the 8-bit default.
run_one() {
    local proto="$1" name="$2"
    shift 2
    if [ -n "${KAYA_RECORD:-}" ]; then
        local dir="/work/target-linux/recordings/$name-$proto"
        rm -rf "$dir"
        case "$proto" in
            x11)
                KAYA_SELFTEST=1 GDK_BACKEND=x11 timeout 180 \
                    xvfb-run -a -s "-screen 0 1024x768x24" \
                    /work/tools/linux/record-leg.sh x11 "$dir" "$@"
                ;;
            wayland)
                KAYA_SELFTEST=1 GDK_BACKEND=wayland timeout 180 \
                    xvfb-run -a -s "-screen 0 1024x768x24" \
                    /work/tools/linux/record-leg.sh wayland "$dir" "$@"
                ;;
        esac
        return
    fi
    case "$proto" in
        x11)
            KAYA_SELFTEST=1 GDK_BACKEND=x11 timeout 180 \
                xvfb-run -a -s "-screen 0 1024x768x24" "$@"
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

# The C guests: the ABI's home language over the function floor.
make -C guests/c TARGET_DIR="$CARGO_TARGET_DIR/debug" OUT=/tmp/c-guests || status=1

# The OCaml guests: one dune build for the binding library and all
# four scenes. Its own build dir: _build is shared with the host
# through the repo mount, and dune keys targets on source hashes, not
# platform — without this the container gets handed mac binaries as
# "fresh" (the same disease target-linux/ exists to prevent for cargo).
dune build --build-dir=_build-linux || status=1

# The Haskell guests: one cabal build; list-bin locates the outputs.
# The rpath travels via ghc-options — macOS resolves libkaya by its
# absolute install name, Linux only by rpath or LD_LIBRARY_PATH.
(cd guests/haskell && cabal build all \
    --extra-lib-dirs="$CARGO_TARGET_DIR/debug" \
    --ghc-options="-optl-Wl,-rpath,$CARGO_TARGET_DIR/debug" -v0) || status=1
hs_bin() { (cd guests/haskell && cabal list-bin "$1" -v0); }

# dotnet run and go run rebuild per invocation; build each guest once
# and let the legs exec the outputs.
dotnet build --nologo -v q /tmp/cs/kaya-guests.csproj >/dev/null || status=1
CS_GUEST="/tmp/cs/bin/Debug/net10.0/kaya-guests.dll"
mkdir -p /tmp/go-guests
for guest in milestone2 entry gallery todos reorder feed grow layout; do
    go build -o "/tmp/go-guests/$guest" "dev.kaya/guests/go/$guest" || status=1
done

for proto in x11 wayland; do
    run "$proto" rust "$CARGO_TARGET_DIR/debug/examples/milestone2"
    run "$proto" c /tmp/c-guests/milestone2
    run "$proto" python env KAYA_LIB="$LIB" python3 guests/python/milestone2.py
    run "$proto" go /tmp/go-guests/milestone2
    run "$proto" csharp env KAYA_LIB="$LIB" dotnet exec "$CS_GUEST"
    run "$proto" ocaml env KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/milestone2.exe
    run "$proto" haskell "$(hs_bin milestone2)"
    # The entry scene: the inner env overrides run()'s KAYA_SELFTEST=1.
    run "$proto" entry-rust env KAYA_SELFTEST=entry "$CARGO_TARGET_DIR/debug/examples/entry"
    run "$proto" entry-c env KAYA_SELFTEST=entry /tmp/c-guests/entry
    run "$proto" entry-python env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        python3 guests/python/entry.py
    run "$proto" entry-go env KAYA_SELFTEST=entry /tmp/go-guests/entry
    run "$proto" entry-csharp env KAYA_SELFTEST=entry KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" entry-ocaml env KAYA_SELFTEST=entry KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/entry.exe
    run "$proto" entry-haskell env KAYA_SELFTEST=entry "$(hs_bin entry)"
    # The gallery scene (row + checkbox): the toggle arrives as an
    # occurrence the app answers with the status signal.
    run "$proto" gallery-rust env KAYA_SELFTEST=gallery "$CARGO_TARGET_DIR/debug/examples/gallery"
    run "$proto" gallery-c env KAYA_SELFTEST=gallery /tmp/c-guests/gallery
    run "$proto" gallery-python env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        python3 guests/python/gallery.py
    run "$proto" gallery-go env KAYA_SELFTEST=gallery /tmp/go-guests/gallery
    run "$proto" gallery-csharp env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" gallery-ocaml env KAYA_SELFTEST=gallery KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/gallery.exe
    run "$proto" gallery-haskell env KAYA_SELFTEST=gallery "$(hs_bin gallery)"
    # The todos scene (records + field projection): one field's delta
    # travels; the items-left label proves the fold.
    run "$proto" todos-rust env KAYA_SELFTEST=todos "$CARGO_TARGET_DIR/debug/examples/todos"
    run "$proto" todos-c env KAYA_SELFTEST=todos /tmp/c-guests/todos
    run "$proto" todos-python env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        python3 guests/python/todos.py
    run "$proto" todos-go env KAYA_SELFTEST=todos /tmp/go-guests/todos
    run "$proto" todos-csharp env KAYA_SELFTEST=todos KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" todos-ocaml env KAYA_SELFTEST=todos KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/todos.exe
    run "$proto" todos-haskell env KAYA_SELFTEST=todos "$(hs_bin todos)"
    # The reorder scene (order as collection data): expect_order reads
    # the toolkit's actual child order back after each keyed move.
    run "$proto" reorder-rust env KAYA_SELFTEST=reorder "$CARGO_TARGET_DIR/debug/examples/reorder"
    run "$proto" reorder-c env KAYA_SELFTEST=reorder /tmp/c-guests/reorder
    run "$proto" reorder-python env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" \
        python3 guests/python/reorder.py
    run "$proto" reorder-go env KAYA_SELFTEST=reorder /tmp/go-guests/reorder
    run "$proto" reorder-csharp env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" reorder-ocaml env KAYA_SELFTEST=reorder KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/reorder.exe
    run "$proto" reorder-haskell env KAYA_SELFTEST=reorder "$(hs_bin reorder)"
    # The feed scene (sum-typed elements): per-variant templates,
    # promote = variant-change restamp, witnessed field writes.
    run "$proto" feed-rust env KAYA_SELFTEST=feed "$CARGO_TARGET_DIR/debug/examples/feed"
    run "$proto" feed-c env KAYA_SELFTEST=feed /tmp/c-guests/feed
    run "$proto" feed-python env KAYA_SELFTEST=feed KAYA_LIB="$LIB" \
        python3 guests/python/feed.py
    run "$proto" feed-go env KAYA_SELFTEST=feed /tmp/go-guests/feed
    run "$proto" feed-csharp env KAYA_SELFTEST=feed KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" feed-ocaml env KAYA_SELFTEST=feed KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/feed.exe
    run "$proto" feed-haskell env KAYA_SELFTEST=feed "$(hs_bin feed)"
    # The grow scene (the layout contract: both containers hold
    # nothing but growers, splits read back as shares plus root-fills),
    # every sugar-tier language. The C floor stays out on purpose — its
    # scenes document the explicit wire, and grow there is a separate
    # exercise (see the ledger).
    run "$proto" grow-rust env KAYA_SELFTEST=grow "$CARGO_TARGET_DIR/debug/examples/grow"
    run "$proto" grow-python env KAYA_SELFTEST=grow KAYA_LIB="$LIB" \
        python3 guests/python/grow.py
    run "$proto" grow-go env KAYA_SELFTEST=grow /tmp/go-guests/grow
    run "$proto" grow-csharp env KAYA_SELFTEST=grow KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" grow-ocaml env KAYA_SELFTEST=grow KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/grow.exe
    run "$proto" grow-haskell env KAYA_SELFTEST=grow "$(hs_bin grow)"
    # The layout scene: the cross-backend observation vehicle the
    # recordings are compared from, so it has to be a recorded leg here
    # too — in every language.
    run "$proto" layout-rust env KAYA_SELFTEST=layout "$CARGO_TARGET_DIR/debug/examples/layout"
    run "$proto" layout-python env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        python3 guests/python/layout.py
    run "$proto" layout-go env KAYA_SELFTEST=layout /tmp/go-guests/layout
    run "$proto" layout-csharp env KAYA_SELFTEST=layout KAYA_LIB="$LIB" \
        dotnet exec "$CS_GUEST"
    run "$proto" layout-ocaml env KAYA_SELFTEST=layout KAYA_LIB="$LIB" _build-linux/default/guests/ocaml/layout.exe
    run "$proto" layout-haskell env KAYA_SELFTEST=layout "$(hs_bin layout)"
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
