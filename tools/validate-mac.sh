#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Run every milestone-0 validation natively on macOS: the Rust example,
# Python over the function floor, and Go and C# over the direct ring.
# Run inside the dev shell (direnv or `nix develop`), with a logged-in
# GUI session; each suite opens a window briefly.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=tools/lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"
# The one Python import mechanism: the kaya package resolves from
# here (the guests' sys.path shims are gone).
export PYTHONPATH="$ROOT/bindings/python"

# Phase timing: greppable "TIMING <phase> <n>s" lines say where a
# run's wall time went — build, legs, or capture — so the dev loop's
# bottleneck is measured, never guessed.
KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}

# --lib as well as --example: the foreign guests load the cdylib, and
# --example alone would leave a stale libkaya.dylib in place. The header
# check keeps guests from compiling against an ABI the source has left
# behind.
cargo build --lib --example milestone2 --example entry \
    --example gallery --example todos --example reorder --example feed \
    --example grow --example layout || exit 1
tools/gen-header.sh --check || exit 1
tools/gen-bindings.sh --check || exit 1
tools/gen-guests.sh --check || exit 1
tools/check-steps.sh || exit 1
# The Python surface's guard and mirror semantics, checked headlessly
# (records queue; the core is never entered).
python3 bindings/python/kaya_app_checks.py >/dev/null || { echo "kaya_app checks: FAIL"; exit 1; }
# Fast cross-language/-platform gates: catch cfg'd-backend and guest
# breakage here, in seconds, not on an emulator or VM.
tools/check-targets.sh || exit 1
tools/check-shell.sh || exit 1
tools/check-sugar-surface.sh || exit 1
tools/check-wheel.sh || exit 1
tools/check-abort.sh || exit 1
tools/check-verbs.sh || exit 1
tools/swift-typecheck.sh || exit 1
tools/java-typecheck.sh || exit 1
timing core-build+gates

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

# Recording mode (KAYA_RECORD=1): ONE suite-long ScreenCaptureKit
# stream films every leg. The filter is display-scoped but
# include-listed — only guest windows are composited, so the human's
# screen never appears — and parallel legs tile into slots
# (KAYA_WIN_SLOT) so their crops never overlap. One stream on purpose:
# concurrent SCK window streams starve and die where a single stream
# is reliable; parallelism scales by adding tiles, not streams.
# Per-leg videos and stills are derived from the suite film by crop.
if [ -n "${KAYA_RECORD:-}" ]; then
    JOBS="${KAYA_JOBS:-8}"
    command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null \
        || { echo "recording mode needs ffmpeg/ffprobe — run inside nix develop"; exit 1; }
    tools/harness-extract.sh --selftest || exit 1
    RECORDINGS="$ROOT/target/recordings/mac"
    rm -rf "$RECORDINGS"
    mkdir -p "$RECORDINGS"
    # The binary's path+content is its identity to the capture stack,
    # and REBUILDING IN PLACE POISONS IT: after enough rebuilds at one
    # path, shareable-content queries for that identity hang or return
    # bogus TCC declines — and the poisoned state survives reboots. A
    # content-hashed name gives each source version one stable, fresh
    # identity, built at most once.
    REC_BIN="target/tools/record-suite-$(shasum tools/record-suite/main.swift | cut -c1-12)"
    if [ ! -x "$REC_BIN" ]; then
        mkdir -p target/tools
        rm -f target/tools/record-suite-*
        kaya_swiftc -O \
            -framework ScreenCaptureKit -framework AVFoundation \
            -o "$REC_BIN" tools/record-suite/main.swift || exit 1
    fi
    # Screen-capture health dies quietly: probe first and abort with
    # instructions instead of failing every leg.
    if ! "$REC_BIN" --probe; then
        echo "recording mode: screen capture probe failed."
        echo "check Screen Recording permission for this terminal/app in System"
        echo "Settings -> Privacy & Security -> Screen & System Audio Recording."
        exit 1
    fi
    PIDFILE="$RECORDINGS/pids"
    : >"$PIDFILE"
    "$REC_BIN" "$RECORDINGS/suite.mov" "$PIDFILE" >"$RECORDINGS/rec.log" 2>&1 &
    REC_PID=$!
fi

# One recorded leg: claim a tile, launch the guest into it, register
# its pid with the suite recorder, and release the guest's gate once
# the recorder reports the window tracked — a leg cannot outrun its
# recording. Stills come later, from the suite film, after the
# recorder stops. Returns nonzero only for a guest failure; recording
# gaps surface at extraction (a leg with no WINDOW record fails the
# stills-count guard, loudly).
run_recorded() {
    local name="$1"
    shift
    local dir="$RECORDINGS/$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    # Claim a free tile; slots equal the pool width, so one is always
    # freed before the pool admits another leg.
    local slot=
    while [ -z "$slot" ]; do
        local i=0
        while [ "$i" -lt "$JOBS" ]; do
            if mkdir "$RECORDINGS/.slot-$i" 2>/dev/null; then
                slot=$i
                break
            fi
            i=$((i + 1))
        done
        [ -n "$slot" ] || sleep 0.1
    done
    local failed=0
    KAYA_SELFTEST="${KAYA_SELFTEST:-1}" KAYA_HARNESS_GATE="$dir/go" \
        KAYA_WIN_SLOT="$slot" "$@" >"$dir/leg.log" 2>&1 &
    local leg_pid=$!
    echo "$leg_pid" >>"$PIDFILE"
    echo "$leg_pid" >"$dir/pid"
    local warm=0
    while [ "$warm" -lt 300 ]; do
        grep -q "TRACKING $leg_pid\$" "$RECORDINGS/rec.log" 2>/dev/null && break
        kill -0 "$leg_pid" 2>/dev/null || break
        sleep 0.05
        warm=$((warm + 1))
    done
    : >"$dir/go"
    # Bounded: a hung guest fails the leg instead of wedging the suite.
    local waited=0
    while kill -0 "$leg_pid" 2>/dev/null && [ "$waited" -lt 240 ]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    if kill -0 "$leg_pid" 2>/dev/null; then
        kill -9 "$leg_pid" 2>/dev/null
        echo "$name: guest did not exit within 120s"
        failed=1
    fi
    wait "$leg_pid" 2>/dev/null || failed=1
    rmdir "$RECORDINGS/.slot-$slot" 2>/dev/null
    if [ "$failed" != 0 ]; then
        cat "$dir/leg.log"
        return 1
    fi
}

# Stop the suite recorder and derive every leg's stills from the film.
# The recorder drains until frames quiesce before finalizing (no fixed
# grace); its exit is still nobody's word but its own — bound it.
rec_suite_stop() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    kill -INT "$REC_PID" 2>/dev/null
    local w=0
    while kill -0 "$REC_PID" 2>/dev/null && [ "$w" -lt 50 ]; do
        sleep 0.5
        w=$((w + 1))
    done
    if kill -0 "$REC_PID" 2>/dev/null; then
        echo "recording: recorder did not exit within 25s of SIGINT; killing"
        kill -9 "$REC_PID" 2>/dev/null
        status=1
    fi
    wait "$REC_PID" 2>/dev/null
    local anchor scale
    anchor=$(sed -n 's/RECORDING_START //p' "$RECORDINGS/rec.log")
    scale=$(sed -n 's/SCALE //p' "$RECORDINGS/rec.log" | awk 'NR==1{print}')
    if [ -z "$anchor" ] || [ -z "$scale" ]; then
        echo "recording: no anchor in rec.log — no stills"
        cat "$RECORDINGS/rec.log"
        status=1
        return
    fi
    # Legs share the one film; extractions are independent — run them
    # all at once and collect verdicts after. The packet index is
    # scanned once here, not 48 times in the workers.
    ffprobe -v quiet -select_streams v -show_entries packet=pts_time -of csv=p=0 \
        "$RECORDINGS/suite.mov" 2>/dev/null | sort -n >"$RECORDINGS/.pts"
    export KAYA_PTS_INDEX="$RECORDINGS/.pts"
    local dir
    local pids=()
    for dir in "$RECORDINGS"/*/; do
        [ -f "$dir/pid" ] || continue
        (
            pid=$(cat "$dir/pid")
            line=$(grep "^WINDOW $pid " "$RECORDINGS/rec.log" | tail -1 || true)
            if [ -z "$line" ]; then
                echo "$(basename "$dir"): never tracked by the recorder"
                exit 1
            fi
            read -r _ _ x y wd ht <<<"$line"
            crop=$(awk -v s="$scale" -v x="$x" -v y="$y" -v w="$wd" -v h="$ht" \
                'BEGIN{printf "crop=%d:%d:%d:%d", w*s, h*s, x*s, y*s}')
            echo "$crop" >"$dir/crop"
            tools/harness-extract.sh "$RECORDINGS/suite.mov" "$dir/leg.log" \
                "$anchor" "$dir/steps" "$crop"
        ) >"$dir/extract.log" 2>&1 || : >"$dir/extract-failed" &
        pids+=($!)
    done
    [ ${#pids[@]} -eq 0 ] || wait "${pids[@]}" 2>/dev/null || true
    unset KAYA_PTS_INDEX
    for dir in "$RECORDINGS"/*/; do
        [ -f "$dir/extract.log" ] || continue
        cat "$dir/extract.log"
        [ ! -e "$dir/extract-failed" ] || status=1
    done
}

# Count live leg subshells only: recorders and emulators are
# background jobs of this same shell, and a jobs-based gate counts
# them too — with enough of them it deadlocks the queue outright.
running_legs() {
    local n=0 p
    for p in "${leg_pids[@]}"; do
        kill -0 "$p" 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
}

run() {
    local name="$1"
    shift
    if [ -n "${KAYA_RECORD:-}" ]; then
        (
            if run_recorded "$name" "$@" >"$LEGS_DIR/$name.log" 2>&1; then
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
        return
    fi
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
    # Watchdog: a wedged pool must die loudly in minutes, not
    # silently absorb tens of them (the deadlock class this gate once
    # had). No slot freeing for 3 minutes is never legitimate — legs
    # are bounded far tighter.
    local spins=0
    while [ "$(running_legs)" -ge "$JOBS" ]; do
        spins=$((spins + 1))
        if [ "$spins" -gt 900 ]; then
            echo "pool wedged: $(running_legs) legs running, none finishing; queued=${#leg_names[@]}" >&2
            exit 1
        fi
        sleep 0.2
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
for guest in milestone2 entry gallery todos reorder feed encodebench; do
    go build -o "target/go-guests/$guest" "dev.kaya/guests/go/$guest" || exit 1
done

# The encode-benchmark leg: the generated encoders must clear their
# floor rates (structural-regression guard, not a race).
CS_GUEST="$CS_GUEST" tools/bench-encode.sh || exit 1
timing guest-builds+bench

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

# The reorder scene (order as collection data; expect_order reads the
# toolkit's child order), every language against AppKit.
run reorder-rust env KAYA_SELFTEST=reorder target/debug/examples/reorder
run reorder-python env KAYA_SELFTEST=reorder python3 guests/python/reorder.py
run reorder-go env KAYA_SELFTEST=reorder target/go-guests/reorder
run reorder-csharp env KAYA_SELFTEST=reorder KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run reorder-ocaml env KAYA_SELFTEST=reorder KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/reorder.exe
run reorder-haskell env KAYA_SELFTEST=reorder "$(hs_bin reorder)"

# The feed scene (sum-typed elements: per-variant templates, promote =
# variant-change restamp, match-refined witnessed field writes), every
# language against AppKit.
run feed-rust env KAYA_SELFTEST=feed target/debug/examples/feed
run feed-python env KAYA_SELFTEST=feed python3 guests/python/feed.py
run feed-go env KAYA_SELFTEST=feed target/go-guests/feed
run feed-csharp env KAYA_SELFTEST=feed KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run feed-ocaml env KAYA_SELFTEST=feed KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/feed.exe
run feed-haskell env KAYA_SELFTEST=feed "$(hs_bin feed)"

# The grow scene (the layout contract: a column of nothing but growers
# splits weight/Sigma-weight, read back as shares). Rust only so far —
# the scene lands depth-first like every other, and the remaining seven
# guests come with the breadth phase.
run grow-rust env KAYA_SELFTEST=grow target/debug/examples/grow
# The layout scene: the cross-backend observation vehicle. It asserts
# only that the tree built (layout itself is checked by the grow scene's
# shares), but it is the scene the recordings are compared from, so it
# has to be a recorded leg on every backend.
run layout-rust env KAYA_SELFTEST=layout target/debug/examples/layout

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
KAYA_SELFTEST_SCRIPT="$(scene_script milestone2)"
export KAYA_SELFTEST_SCRIPT
run rust-swiftui target/debug/examples/milestone2
run python-swiftui python3 guests/python/milestone2.py
run go-swiftui target/go-guests/milestone2
run csharp-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run ocaml-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/milestone2.exe
run haskell-swiftui "$(hs_bin milestone2)"
KAYA_SELFTEST_SCRIPT="$(scene_script entry)"
export KAYA_SELFTEST_SCRIPT
run entry-rust-swiftui env KAYA_SELFTEST=entry target/debug/examples/entry
run entry-python-swiftui env KAYA_SELFTEST=entry python3 guests/python/entry.py
run entry-go-swiftui env KAYA_SELFTEST=entry target/go-guests/entry
run entry-csharp-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run entry-ocaml-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/entry.exe
run entry-haskell-swiftui env KAYA_SELFTEST=entry "$(hs_bin entry)"
KAYA_SELFTEST_SCRIPT="$(scene_script gallery)"
export KAYA_SELFTEST_SCRIPT
run gallery-rust-swiftui env KAYA_SELFTEST=gallery target/debug/examples/gallery
run gallery-python-swiftui env KAYA_SELFTEST=gallery python3 guests/python/gallery.py
run gallery-go-swiftui env KAYA_SELFTEST=gallery target/go-guests/gallery
run gallery-csharp-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run gallery-ocaml-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/gallery.exe
run gallery-haskell-swiftui env KAYA_SELFTEST=gallery "$(hs_bin gallery)"
KAYA_SELFTEST_SCRIPT="$(scene_script todos)"
export KAYA_SELFTEST_SCRIPT
run todos-rust-swiftui env KAYA_SELFTEST=todos target/debug/examples/todos
run todos-python-swiftui env KAYA_SELFTEST=todos python3 guests/python/todos.py
run todos-go-swiftui env KAYA_SELFTEST=todos target/go-guests/todos
run todos-csharp-swiftui env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run todos-ocaml-swiftui env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/todos.exe
run todos-haskell-swiftui env KAYA_SELFTEST=todos "$(hs_bin todos)"
KAYA_SELFTEST_SCRIPT="$(scene_script reorder)"
export KAYA_SELFTEST_SCRIPT
run reorder-rust-swiftui env KAYA_SELFTEST=reorder target/debug/examples/reorder
run reorder-python-swiftui env KAYA_SELFTEST=reorder python3 guests/python/reorder.py
run reorder-go-swiftui env KAYA_SELFTEST=reorder target/go-guests/reorder
run reorder-csharp-swiftui env KAYA_SELFTEST=reorder KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run reorder-ocaml-swiftui env KAYA_SELFTEST=reorder KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/reorder.exe
run reorder-haskell-swiftui env KAYA_SELFTEST=reorder "$(hs_bin reorder)"
KAYA_SELFTEST_SCRIPT="$(scene_script feed)"
export KAYA_SELFTEST_SCRIPT
run feed-rust-swiftui env KAYA_SELFTEST=feed target/debug/examples/feed
run feed-python-swiftui env KAYA_SELFTEST=feed python3 guests/python/feed.py
run feed-go-swiftui env KAYA_SELFTEST=feed target/go-guests/feed
run feed-csharp-swiftui env KAYA_SELFTEST=feed KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run feed-ocaml-swiftui env KAYA_SELFTEST=feed KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/feed.exe
run feed-haskell-swiftui env KAYA_SELFTEST=feed "$(hs_bin feed)"

# The layout and grow scenes against the SwiftUI interpreter — the same
# examples, KAYA_BACKEND=swiftui. Each scene exports its OWN script:
# the Rust backends embed theirs at build time, but the interpreter
# reads KAYA_SELFTEST_SCRIPT from the environment, so a leg that does
# not set it silently runs the previous group's script against this
# scene's tree.
KAYA_SELFTEST_SCRIPT="$(scene_script grow)"
export KAYA_SELFTEST_SCRIPT
run grow-rust-swiftui env KAYA_SELFTEST=grow target/debug/examples/grow
drain
KAYA_SELFTEST_SCRIPT="$(scene_script layout)"
export KAYA_SELFTEST_SCRIPT
run layout-rust-swiftui env KAYA_SELFTEST=layout target/debug/examples/layout
unset KAYA_BACKEND KAYA_SWIFTUI_LIB KAYA_SELFTEST_SCRIPT
drain
timing legs

rec_suite_stop
[ -z "${KAYA_RECORD:-}" ] || timing recording-stop+stills

# The one-line verdict: suites accumulate failures rather than abort,
# so a truncated log must still end with the answer.
if [ "$status" = 0 ]; then echo "validate-mac: ALL PASS"; else echo "validate-mac: FAILURES ABOVE"; fi
exit "$status"
