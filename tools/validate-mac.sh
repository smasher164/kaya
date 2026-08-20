#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Run every milestone-0 validation natively on macOS. Run inside the
# dev shell, with a logged-in GUI session; each suite opens a window
# briefly.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=tools/lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"
# The one Python import mechanism: the kaya package resolves from
# here (the guests' sys.path shims are gone).
export PYTHONPATH="$ROOT/bindings/python"

# Phase timing: greppable "TIMING <phase> <n>s" lines.
KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}

# --lib as well as --example: the foreign guests load the cdylib, and
# --example alone would leave a stale libkaya.dylib in place.
# THE scene list: the mechanical per-scene surfaces below derive from
# it — one registration per new scene; the leg blocks stay explicit
# because they encode per-language coverage decisions.
SCENES="background stall milestone2 entry gallery todos reorder feed grow layout align window panels confirm nav split scroll progress select radio grid textarea sections menus commands a11y a11yrows filedialog clipboard undo dirty ranges save styling toolbar identity assets"
# Depth-slice scenes: a rust example + steps exist, the language sweep
# has not landed — built and run rust-only until their guests arrive,
# when they move into SCENES.
#
# A scene goes STRAIGHT INTO SCENES when all eight guests already exist
# by the time this lane's arm lands, because a depth entry would then
# hold seven legs off a backend that has the feature (identity and
# assets both did). Which scenes carry a C FLOOR guest is
# guests/c/Makefile's SCENES, read from the other side by check-steps'
# sweep_c_floor.
DEPTH_SCENES="typeface panes"
BUILD_EXAMPLES=()
for s in $SCENES $DEPTH_SCENES; do BUILD_EXAMPLES+=(--example "$s"); done
cargo build --locked --lib "${BUILD_EXAMPLES[@]}" || exit 1
# The library the legs load must be the one this build produced —
# a build whose failure went unnoticed leaves the previous one in
# place and every verdict below is then about stale code.
tools/build-id.sh --verify target/debug/libkaya.dylib || exit 1

# STAGE THE RUST GUESTS OUT OF THE BUILD DIRECTORY, and run them from
# here. Not tidiness — 48% of this lane's leg time was one line of
# CoreFoundation: launching an unbundled executable registers it with
# LaunchServices, and `_LSApplicationCheckIn` enumerates the
# executable's CONTAINING DIRECTORY. `target/debug/examples` had reached
# 776,613 entries and 3.8 GB; the same binary took 7.7s from there
# against 0.13s from a two-entry directory (measured 2026-08-10,
# docs/deferred.md). It is also what made the five-lane matrix a coin
# flip, by pushing split-rust past the 120s per-leg timeout.
#
# The staged list DERIVES FROM $SCENES, like BUILD_EXAMPLES above, so a
# new scene cannot be built and then left running out of the build
# directory.
RUST_GUESTS="$ROOT/target/rust-guests"
rm -rf "$RUST_GUESTS"
mkdir -p "$RUST_GUESTS" || exit 1
for s in $SCENES $DEPTH_SCENES; do
    cp "$ROOT/target/debug/examples/$s" "$RUST_GUESTS/$s" || exit 1
done
# THE GUARD, on the path nobody can avoid: this staging is worthless if
# the directory it stages INTO is itself large, and the only way that
# happens is someone pointing it somewhere else. Checked here rather
# than in a gate because a lane that quietly went back to 30s legs
# would read as "the machine is busy" for another six months.
staged=$(find "$RUST_GUESTS" -maxdepth 1 | wc -l | tr -d ' ')
if [ "$staged" -gt 64 ]; then
    echo "validate-mac: the rust guest staging directory holds $staged entries." \
        "It exists to be SMALL — macOS enumerates an unbundled executable's" \
        "siblings on every launch, and that walk was 7.7s per leg when this" \
        "was target/debug/examples. Stage somewhere clean." >&2
    exit 1
fi
# THE GATE SWEEP, and the artifacts it reads, in one entry point.
# tools/gates.sh owns the list, BUILDS libkaya and the SwiftUI
# interpreter before any gate reads them, and refuses a verdict unless
# the number that ran equals the number declared. tools/check-gates.sh
# holds this file, that list and CLAUDE.md's rung 2 to one census, and
# refuses this file the right to invoke a gate directly.
# NOTHING TO STAGE FOR ASSETS, AND HERE IS WHY, CHECKED. The guests call
# `asset(name)`; with no KAYA_ASSET_DIR set the core falls through to
# the compile-time repo-relative default and this lane runs from the
# repo root, so guests/assets is exactly where that points. Written
# down at the site because the next person to add an asset reads this
# file looking for a staging line, and its absence has to be an answer
# (docs/assets-plan.md A5.4).
#
# LOUD, AND BEFORE ANY LEG RUNS: without the root, every guest that
# names an asset dies inside its build closure on eight legs at once.
if [ ! -f "$ROOT/guests/assets/fonts/sora-wght.ttf" ]; then
    echo "validate-mac: the asset root guests/assets is not where the core's" >&2
    echo "  repo-relative default points. This lane stages nothing because it" >&2
    echo "  runs from the repo root; check that before doubting the guests." >&2
    exit 1
fi
echo "assets: the root resolves by the repo-relative default ($(find "$ROOT/guests/assets" -type f | wc -l | tr -d ' ') files)"

tools/gates.sh || exit 1
timing core-build+gates

status=0

# Legs run in a background pool (KAYA_JOBS wide, KAYA_JOBS=1 for the
# old serial behavior): every guest is its own process with a
# self-contained selftest, so nothing couples one leg to another. Each
# leg logs to its own file; verdicts print in submission order at
# drain, and a FAIL prints its log.
JOBS="${KAYA_JOBS:-8}"
LEGS_DIR="$(mktemp -d)"

# ── THE MAC FILE-PANEL VIEW MODE, ROTATED RATHER THAN INHERITED ──────
# NSOpenPanel's file browser publishes a DIFFERENT accessibility
# identifier per view mode, and the mode is machine-wide
# (`NSGlobalDomain NSNavPanelFileListModeForOpenMode2`: 1 columns, 2
# list, 3 icons), written by any application's open panel for every
# application on the box (docs/traps.md).
#
# The interpreter reads all three shapes (KayaPanelShape), but the lane
# used to run whichever mode the machine was in, so two readers and one
# of the two selection idioms — whose wrong choice is a SILENT WRONG
# FILE — were dead code on any given run. So the lane sets the mode
# itself and splits the eight legs across the three.
#
# WRITING A MACHINE-WIDE USER PREFERENCE IS A SIDE EFFECT ON THE
# DEVELOPER'S BOX. The original is captured before the first change,
# restored on EXIT/INT/TERM, and — because SIGKILL runs no trap —
# written to a stamp file the next run restores from first.
PANEL_MODE_KEY=NSNavPanelFileListModeForOpenMode2
PANEL_MODE_STAMP="$ROOT/target/panel-mode.orig"

# "unset" is a real value here: the key may be absent, and restoring to
# absent is a delete, not a write of some guessed default.
panel_mode_read() { defaults read -g "$PANEL_MODE_KEY" 2>/dev/null || echo unset; }

panel_mode_write() { # value | unset
    if [ "$1" = unset ]; then
        defaults delete -g "$PANEL_MODE_KEY" 2>/dev/null || true
    else
        defaults write -g "$PANEL_MODE_KEY" -int "$1"
    fi
}

# Idempotent, and it VERIFIES rather than assumes: the stamp is removed
# only once the box reads back the value it started with. A restore that
# failed keeps the stamp, so the next run and probe-env both still see
# the debt.
panel_mode_restore() {
    [ -f "$PANEL_MODE_STAMP" ] || return 0
    local want back
    want="$(cat "$PANEL_MODE_STAMP")"
    panel_mode_write "$want"
    back="$(panel_mode_read)"
    if [ "$back" != "$want" ]; then
        echo "validate-mac: FAILED to put $PANEL_MODE_KEY back: wanted $want," \
            "reads $back. By hand: defaults write -g $PANEL_MODE_KEY -int $want" >&2
        return 1
    fi
    rm -f "$PANEL_MODE_STAMP"
}

# Put the panel in one mode for the group of legs that follows, and say
# so in the log. The mode is printed as a FACT for every group, passing
# or failing — the 2026-08-06 outage cost two hours of diagnosis for a
# value nothing logged.
PANEL_MODES_RUN=""
panel_mode_set() { # mode name
    if [ ! -f "$PANEL_MODE_STAMP" ]; then
        mkdir -p "$(dirname "$PANEL_MODE_STAMP")"
        panel_mode_read >"$PANEL_MODE_STAMP"
    fi
    panel_mode_write "$1"
    local back
    back="$(panel_mode_read)"
    # A ROTATION THAT DID NOT TAKE PROVES NOTHING: it leaves the other
    # two readers exactly as unexercised as before and the legs still
    # pass, which is the vacuous-guard shape this project keeps paying
    # for. The write is read back and the lane refuses rather than
    # pretend it rotated.
    if [ "$back" != "$1" ]; then
        echo "validate-mac: $PANEL_MODE_KEY did not take — wrote $1, reads \"$back\"" >&2
        status=1
        return 1
    fi
    PANEL_MODES_RUN="$PANEL_MODES_RUN $1"
    echo "== file panel view mode $1 ($2); restoring $(cat "$PANEL_MODE_STAMP") at exit"
}

# Which of the three modes no leg ran under. Deleting a group — or a
# refused write — leaves a lane that still reports ALL PASS while one of
# the interpreter's three readers goes back to being dead code, which is
# the silence this whole block exists to end. So the census is checked
# rather than assumed, on the one path every mac run takes.
panel_modes_missing() {
    local m out=""
    for m in 1 2 3; do
        case " $PANEL_MODES_RUN " in
            *" $m "*) ;;
            *) out="$out $m" ;;
        esac
    done
    printf '%s' "$out"
}

# A previous run that was SIGKILLed, or a machine that lost power, left
# the box rotated and its original value on disk. Hand it back HERE,
# before this run reads anything, and say so out loud.
if [ -f "$PANEL_MODE_STAMP" ]; then
    echo "validate-mac: an earlier run left the file-panel view mode changed;" \
        "restoring $(cat "$PANEL_MODE_STAMP")"
    panel_mode_restore || status=1
fi

trap 'rm -rf "$LEGS_DIR"; panel_mode_restore' EXIT
# EXIT alone is not enough for ^C: whether a signal death runs the EXIT
# trap depends on the shell and on whether the signal is trapped, and a
# lane interrupted mid-rotation must still hand the box back. Restore,
# then re-raise so the caller still sees a signal death.
trap 'panel_mode_restore; trap - INT; kill -INT $$' INT
trap 'panel_mode_restore; trap - TERM; kill -TERM $$' TERM
leg_names=()
leg_pids=()

# Recording mode (KAYA_RECORD=1): ONE suite-long ScreenCaptureKit stream
# films every leg. The filter is display-scoped but include-listed —
# only guest windows are composited — and parallel legs tile into slots
# (KAYA_WIN_SLOT) so their crops never overlap. One stream on purpose:
# concurrent SCK window streams starve and die where a single stream is
# reliable.
if [ -n "${KAYA_RECORD:-}" ]; then
    JOBS="${KAYA_JOBS:-8}"
    command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null \
        || { echo "recording mode needs ffmpeg/ffprobe — run inside nix develop"; exit 1; }
    tools/harness-extract.sh --selftest || exit 1
    RECORDINGS="$ROOT/target/recordings/mac"
    rm -rf "$RECORDINGS"
    mkdir -p "$RECORDINGS"
    # The binary's path+content is its identity to the capture stack, and
    # REBUILDING IN PLACE POISONS IT: after enough rebuilds at one path,
    # shareable-content queries for that identity hang or return bogus TCC
    # declines, and the poisoned state survives reboots. A content-hashed
    # name gives each source version one stable, fresh identity.
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

# One recorded leg: claim a tile, launch the guest into it, register its
# pid with the suite recorder, and release the guest's gate once the
# recorder reports the window tracked — a leg cannot outrun its
# recording. Returns nonzero only for a guest failure; recording gaps
# surface at extraction.
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
    anchor=$(grep '^RECORDING_START ' "$RECORDINGS/rec.log" | cut -d' ' -f2-)
    scale=$(grep '^SCALE ' "$RECORDINGS/rec.log" | head -1 | cut -d' ' -f2-)
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
            crop=$(python3 -c '
import sys
s, x, y, w, h = (float(v) for v in sys.argv[1:6])
print("crop=%d:%d:%d:%d" % (w * s, h * s, x * s, y * s))' "$scale" "$x" "$y" "$wd" "$ht")
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
            local t0=$SECONDS
            if run_recorded "$name" "$@" >"$LEGS_DIR/$name.log" 2>&1; then
                echo PASS >"$LEGS_DIR/$name.verdict"
            else
                echo FAIL >"$LEGS_DIR/$name.verdict"
            fi
            echo $((SECONDS - t0)) >"$LEGS_DIR/$name.secs"
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
        local t0=$SECONDS
        if KAYA_SELFTEST=1 timeout 120 "$@"; then
            echo "$name: PASS ($((SECONDS - t0))s)"
        else
            echo "$name: FAIL ($((SECONDS - t0))s)"
            status=1
        fi
        return
    fi
    (
        # Per-leg wall time rides the verdict, so a bottleneck hunt greps
        # instead of guessing.
        local t0=$SECONDS
        if KAYA_SELFTEST=1 timeout 120 "$@" >"$LEGS_DIR/$name.log" 2>&1; then
            echo PASS >"$LEGS_DIR/$name.verdict"
        else
            echo FAIL >"$LEGS_DIR/$name.verdict"
        fi
        echo $((SECONDS - t0)) >"$LEGS_DIR/$name.secs"
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
            # leg still failed. Two causes share it and the note may not
            # pick one (invariant 3 — the linux twin of this note guessed
            # "exit-path bug?" while the real cause was a wrapper clause,
            # twice): a nonzero guest exit (the Stage::finish class), or
            # a wrapper around the guest failing after the verdict.
            if grep -q "KAYA_SELFTEST: OK" "$LEGS_DIR/$name.log" 2>/dev/null; then
                echo "$name: note — verdict was OK but the leg exited nonzero: the guest's exit path, or a wrapper clause failing after the verdict — its sentence, if any, is above"
            fi
            # A SILENT leg has two very different meanings and the bare
            # verdict cannot tell them apart — split by duration because the
            # mac timeout is a KILL: a killed guest loses whatever its
            # block-buffered stdout was holding, so an empty log there means
            # "hung with its trace in the buffer", not "never started". Read
            # the wrong way (2026-07-25) it sends you hunting a startup
            # failure while the real answer needs `sample $pid`.
            if ! grep -q "KAYA_HARNESS" "$LEGS_DIR/$name.log" 2>/dev/null; then
                if [ "$(cat "$LEGS_DIR/$name.secs" 2>/dev/null || echo 0)" -ge 115 ]; then
                    echo "$name: note — NO OUTPUT, and it ran to the 120s timeout." \
                        "It was KILLED: its buffered trace died with it, so this is" \
                        "a HANG, not a failure to start. Reproduce it and sample the" \
                        "live process — that is what named the accessibility legs'" \
                        "layout stall (docs/traps.md)."
                else
                    echo "$name: note — NO OUTPUT AT ALL and it exited early. The" \
                        "guest never reached the harness: a bad library load, a" \
                        "missing display, or a blocking connect at startup. Look" \
                        "before the scene, not inside it."
                fi
            fi
            status=1
        fi
        echo "$name: $verdict ($(cat "$LEGS_DIR/$name.secs" 2>/dev/null || echo '?')s)"
    done
    leg_names=()
}

# The guest builds are per-language INDEPENDENT, so they run as a pool
# (measured 2026-07-22: 29-38s serial, bounded by the slowest language
# when pooled). Each job logs to its own file; any failure prints its
# log and dies — no silent partial builds.
BUILDS_DIR="$(mktemp -d)"
build_names=()
build_pids=()
run_build() {
    local name="$1"
    shift
    ("$@") >"$BUILDS_DIR/$name.log" 2>&1 &
    build_pids+=($!)
    build_names+=("$name")
}

build_ocaml() {
    # One dune build covers the binding library and all scenes
    # (dune-project at the repo root scopes to bindings/ and guests/).
    dune build
}

build_haskell() {
    # One cabal build for the binding library and all scenes.
    cd guests/haskell && cabal build all \
        --extra-lib-dirs="$ROOT/target/debug" \
        --ghc-options="-L$ROOT/target/debug -optl-Wl,-rpath,$ROOT/target/debug" -v0
}

build_csharp() {
    # dotnet run rebuilds per invocation; build once, legs exec it.
    dotnet build --nologo -v q guests/csharp/kaya-guests.csproj >/dev/null
}

build_go() {
    # ONE BINARY FOR EVERY SCENE. guests/go/cmd is the only main package in
    # the guest tree: it imports every scene library and picks one from
    # KAYA_SELFTEST. A scene with no Go body has no import and no table key
    # in guests/go/cmd/scenes.go, so nothing here can go looking for it.
    #
    # encodebench is guest-only (no rust example) and is a benchmark rather
    # than a scene — its own main package, which tools/bench-encode.sh runs
    # from this directory.
    mkdir -p target/go-guests
    go build -o target/go-guests/kaya-go dev.kaya/guests/go/cmd || return 1
    go build -o target/go-guests/encodebench dev.kaya/guests/go/encodebench
}

build_swift() {
    # The same bindings the iOS bundles compile, linked against
    # libkaya.dylib — the fleet's modern-stamp legs. swiftc allows
    # top-level code only in a file named main.swift, so each scene
    # gets its own staging dir and the compiles pool.
    mkdir -p target/swift-guests
    local guest pids=() names=()
    # DEPTH_SCENES too: a depth slice's guests arrive one language at a
    # time, and the file test below is what decides — a scene whose
    # Swift guest has not landed yet is skipped, not a build failure.
    for guest in $SCENES $DEPTH_SCENES; do
        [ -f "guests/swift/$guest.swift" ] || continue
        local dir="target/swift-guests/.stage-$guest"
        rm -rf "$dir"
        mkdir -p "$dir"
        cp "guests/swift/$guest.swift" "$dir/main.swift"
        local companions=()
        if [ -f "guests/swift/$guest+Kaya.swift" ]; then
            companions=("guests/swift/$guest+Kaya.swift")
        fi
        kaya_swiftc -import-objc-header crates/kaya/include/kaya.h \
            bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift \
            bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift \
            "${companions[@]}" "$dir/main.swift" \
            -L target/debug -lkaya \
            -Xlinker -rpath -Xlinker "$ROOT/target/debug" \
            -o "target/swift-guests/$guest" >"$dir/build.log" 2>&1 &
        pids+=($!)
        names+=("$guest")
    done
    local i=0 status=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            cat "target/swift-guests/.stage-${names[$i]}/build.log"
            status=1
        fi
        i=$((i + 1))
    done
    rm -rf target/swift-guests/.stage-*
    return "$status"
}

build_c() {
    # THE C FLOOR. The floor guests build and pass here unchanged, because
    # kaya::run dlopens the SwiftUI interpreter for a C guest exactly as it
    # does for a Go or Swift one.
    #
    # THE SCENES THIS LANE ACTUALLY RUNS, not the Makefile's whole list: a
    # guest built here and run nowhere is the false-coverage shape
    # check-steps was written against, and its sweep_c_floor reads this
    # very assignment — every name here must have a leg below. SCENES is a
    # command-line override, so the Makefile keeps one list.
    make -C guests/c SCENES="undo dirty ranges save a11yrows styling assets" TARGET_DIR="$ROOT/target/debug" \
        OUT="$ROOT/target/c-guests"
}

build_java() {
    # The shared binding + the desktop transport + every scene + the
    # Main selector, one javac.
    rm -rf target/java-guests
    mkdir -p target/java-guests
    javac -encoding UTF-8 -d target/java-guests \
        bindings/java-desktop/dev/kaya/KayaRing.java \
        bindings/java/dev/kaya/*.java \
        guests/java/dev/kaya/milestone2kt/*.java \
        guests/java-desktop/dev/kaya/milestone2kt/Main.java
}

run_build ocaml build_ocaml
run_build haskell build_haskell
run_build csharp build_csharp
run_build go build_go
run_build swift build_swift
run_build java build_java
run_build c build_c
build_status=0
i=0
for pid in "${build_pids[@]}"; do
    if ! wait "$pid"; then
        echo "guest build FAILED: ${build_names[$i]}" >&2
        cat "$BUILDS_DIR/${build_names[$i]}.log" >&2
        build_status=1
    fi
    i=$((i + 1))
done
rm -rf "$BUILDS_DIR"
[ "$build_status" = 0 ] || exit 1
hs_bin() { (cd guests/haskell && cabal list-bin "$1" -v0); }
CS_GUEST="guests/csharp/bin/Debug/net10.0/kaya-guests.dll"

# The encode-benchmark leg: the generated encoders must clear their
# floor rates (structural-regression guard, not a race).
CS_GUEST="$CS_GUEST" tools/bench-encode.sh || exit 1
timing guest-builds+bench

# Every guest against the SwiftUI backend, the one macOS backend.
# The build's exit status is load-bearing: unchecked, a swiftc failure
# left the PREVIOUS dylib in place and 152 legs false-PASSed against
# stale code (2026-07-22). A failed build must kill the lane, not
# degrade it to yesterday's interpreter.
export KAYA_SWIFTUI_LIB="$ROOT/target/swiftui/libkaya_swiftui.dylib"
# The Swift interpreter reads the scene script from the environment
# (the Rust backends embed theirs at build time). Comments stripped:
# some transports fold newlines into `;`, and a leading comment must
# not swallow the folded script.
scene_script() { grep -v '^#' "tools/scenes/$1.steps"; }
KAYA_SELFTEST_SCRIPT="$(scene_script milestone2)"
export KAYA_SELFTEST_SCRIPT
run rust-swiftui "$RUST_GUESTS"/milestone2
run python-swiftui python3 guests/python/milestone2.py
run go-swiftui target/go-guests/kaya-go
run csharp-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run ocaml-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/milestone2.exe
run haskell-swiftui "$(hs_bin milestone2)"
run swift-swiftui target/swift-guests/milestone2
run java-swiftui env KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
KAYA_SELFTEST_SCRIPT="$(scene_script entry)"
export KAYA_SELFTEST_SCRIPT
run entry-rust-swiftui env KAYA_SELFTEST=entry "$RUST_GUESTS"/entry
run entry-python-swiftui env KAYA_SELFTEST=entry python3 guests/python/entry.py
run entry-go-swiftui env KAYA_SELFTEST=entry target/go-guests/kaya-go
run entry-csharp-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run entry-ocaml-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/entry.exe
run entry-haskell-swiftui env KAYA_SELFTEST=entry "$(hs_bin entry)"
run entry-swift-swiftui env KAYA_SELFTEST=entry target/swift-guests/entry
run entry-java-swiftui env KAYA_SELFTEST=entry KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
KAYA_SELFTEST_SCRIPT="$(scene_script gallery)"
export KAYA_SELFTEST_SCRIPT
run gallery-rust-swiftui env KAYA_SELFTEST=gallery "$RUST_GUESTS"/gallery
run gallery-python-swiftui env KAYA_SELFTEST=gallery python3 guests/python/gallery.py
run gallery-go-swiftui env KAYA_SELFTEST=gallery target/go-guests/kaya-go
run gallery-csharp-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run gallery-ocaml-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/gallery.exe
run gallery-haskell-swiftui env KAYA_SELFTEST=gallery "$(hs_bin gallery)"
run gallery-swift-swiftui env KAYA_SELFTEST=gallery target/swift-guests/gallery
run gallery-java-swiftui env KAYA_SELFTEST=gallery KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
KAYA_SELFTEST_SCRIPT="$(scene_script todos)"
export KAYA_SELFTEST_SCRIPT
run todos-rust-swiftui env KAYA_SELFTEST=todos "$RUST_GUESTS"/todos
run todos-python-swiftui env KAYA_SELFTEST=todos python3 guests/python/todos.py
run todos-go-swiftui env KAYA_SELFTEST=todos target/go-guests/kaya-go
run todos-csharp-swiftui env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run todos-ocaml-swiftui env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/todos.exe
run todos-haskell-swiftui env KAYA_SELFTEST=todos "$(hs_bin todos)"
run todos-swift-swiftui env KAYA_SELFTEST=todos target/swift-guests/todos
run todos-java-swiftui env KAYA_SELFTEST=todos KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
KAYA_SELFTEST_SCRIPT="$(scene_script reorder)"
export KAYA_SELFTEST_SCRIPT
run reorder-rust-swiftui env KAYA_SELFTEST=reorder "$RUST_GUESTS"/reorder
run reorder-python-swiftui env KAYA_SELFTEST=reorder python3 guests/python/reorder.py
run reorder-go-swiftui env KAYA_SELFTEST=reorder target/go-guests/kaya-go
run reorder-csharp-swiftui env KAYA_SELFTEST=reorder KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run reorder-ocaml-swiftui env KAYA_SELFTEST=reorder KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/reorder.exe
run reorder-haskell-swiftui env KAYA_SELFTEST=reorder "$(hs_bin reorder)"
run reorder-swift-swiftui env KAYA_SELFTEST=reorder target/swift-guests/reorder
run reorder-java-swiftui env KAYA_SELFTEST=reorder KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
KAYA_SELFTEST_SCRIPT="$(scene_script feed)"
export KAYA_SELFTEST_SCRIPT
run feed-rust-swiftui env KAYA_SELFTEST=feed "$RUST_GUESTS"/feed
run feed-python-swiftui env KAYA_SELFTEST=feed python3 guests/python/feed.py
run feed-go-swiftui env KAYA_SELFTEST=feed target/go-guests/kaya-go
run feed-csharp-swiftui env KAYA_SELFTEST=feed KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run feed-ocaml-swiftui env KAYA_SELFTEST=feed KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/feed.exe
run feed-haskell-swiftui env KAYA_SELFTEST=feed "$(hs_bin feed)"
run feed-swift-swiftui env KAYA_SELFTEST=feed target/swift-guests/feed
run feed-java-swiftui env KAYA_SELFTEST=feed KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

# The layout and grow scenes against the SwiftUI interpreter. Each
# scene exports its OWN script: the Rust backends embed theirs at build
# time, but the interpreter reads KAYA_SELFTEST_SCRIPT from the
# environment, so a leg that does not set it silently runs the previous
# group's script against this scene's tree.
KAYA_SELFTEST_SCRIPT="$(scene_script grow)"
export KAYA_SELFTEST_SCRIPT
run grow-rust-swiftui env KAYA_SELFTEST=grow "$RUST_GUESTS"/grow
run grow-python-swiftui env KAYA_SELFTEST=grow python3 guests/python/grow.py
run grow-go-swiftui env KAYA_SELFTEST=grow target/go-guests/kaya-go
run grow-csharp-swiftui env KAYA_SELFTEST=grow KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run grow-ocaml-swiftui env KAYA_SELFTEST=grow KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/grow.exe
run grow-haskell-swiftui env KAYA_SELFTEST=grow "$(hs_bin grow)"
run grow-swift-swiftui env KAYA_SELFTEST=grow target/swift-guests/grow
run grow-java-swiftui env KAYA_SELFTEST=grow KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
drain
# The align scene: the cross-axis contract (center + baseline), every
# language.
# The window scene: the primary surface's props — the title
# materialized in the real title bar, the advisory 640x400 honored.
# Desktop-only by design (phones reject the size request by physics).
KAYA_SELFTEST_SCRIPT="$(scene_script window)"
export KAYA_SELFTEST_SCRIPT
run window-rust-swiftui env KAYA_SELFTEST=window "$RUST_GUESTS"/window
run window-python-swiftui env KAYA_SELFTEST=window python3 guests/python/window.py
run window-go-swiftui env KAYA_SELFTEST=window target/go-guests/kaya-go
run window-csharp-swiftui env KAYA_SELFTEST=window KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet "$CS_GUEST"
run window-ocaml-swiftui env KAYA_SELFTEST=window KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/window.exe
run window-haskell-swiftui env KAYA_SELFTEST=window "$(hs_bin window)"
run window-swift-swiftui env KAYA_SELFTEST=window target/swift-guests/window
run window-java-swiftui env KAYA_SELFTEST=window KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

# The panels scene: the auxiliary-window grammar. Rust depth; the
# language sweep rides the phase's next slice.
KAYA_SELFTEST_SCRIPT="$(scene_script panels)"
export KAYA_SELFTEST_SCRIPT
run panels-rust-swiftui env KAYA_SELFTEST=panels "$RUST_GUESTS"/panels
run panels-python-swiftui env KAYA_SELFTEST=panels python3 guests/python/panels.py
run panels-go-swiftui env KAYA_SELFTEST=panels target/go-guests/kaya-go
run panels-csharp-swiftui env KAYA_SELFTEST=panels KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet "$CS_GUEST"
run panels-ocaml-swiftui env KAYA_SELFTEST=panels KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/panels.exe
run panels-haskell-swiftui env KAYA_SELFTEST=panels "$(hs_bin panels)"
run panels-swift-swiftui env KAYA_SELFTEST=panels target/swift-guests/panels
run panels-java-swiftui env KAYA_SELFTEST=panels KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script nav)"
export KAYA_SELFTEST_SCRIPT
run nav-rust-swiftui env KAYA_SELFTEST=nav "$RUST_GUESTS"/nav
run nav-python-swiftui env KAYA_SELFTEST=nav python3 guests/python/nav.py
run nav-go-swiftui env KAYA_SELFTEST=nav target/go-guests/kaya-go
run nav-csharp-swiftui env KAYA_SELFTEST=nav KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run nav-ocaml-swiftui env KAYA_SELFTEST=nav KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/nav.exe
run nav-haskell-swiftui env KAYA_SELFTEST=nav "$(hs_bin nav)"
run nav-swift-swiftui env KAYA_SELFTEST=nav target/swift-guests/nav
run nav-java-swiftui env KAYA_SELFTEST=nav KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script split)"
export KAYA_SELFTEST_SCRIPT
run split-rust-swiftui env KAYA_SELFTEST=split "$RUST_GUESTS"/split
run split-python-swiftui env KAYA_SELFTEST=split python3 guests/python/split.py
run split-go-swiftui env KAYA_SELFTEST=split target/go-guests/kaya-go
run split-csharp-swiftui env KAYA_SELFTEST=split KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run split-ocaml-swiftui env KAYA_SELFTEST=split KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/split.exe
run split-haskell-swiftui env KAYA_SELFTEST=split "$(hs_bin split)"
run split-swift-swiftui env KAYA_SELFTEST=split target/swift-guests/split
run split-java-swiftui env KAYA_SELFTEST=split KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

# The panes DEPTH slice (docs/multicolumn-plan.md §2): the rust leg on
# this backend is the whole roster until breadth fans the guest out.
KAYA_SELFTEST_SCRIPT="$(scene_script panes)"
export KAYA_SELFTEST_SCRIPT
run panes-rust-swiftui env KAYA_SELFTEST=panes "$RUST_GUESTS"/panes

# The listdetail scene: THE SAME GUESTS, asserting list-detail's bare
# invariant at whatever width the host gives — a scene selects a
# SCRIPT, never an app. Desktop-redundant on this lane and carried
# anyway, because the file is shared verbatim with the phone lanes
# where it is the only list-detail coverage there is.
KAYA_SELFTEST_SCRIPT="$(scene_script listdetail)"
export KAYA_SELFTEST_SCRIPT
run listdetail-rust-swiftui env KAYA_SELFTEST=listdetail "$RUST_GUESTS"/split
run listdetail-python-swiftui env KAYA_SELFTEST=listdetail python3 guests/python/split.py
run listdetail-go-swiftui env KAYA_SELFTEST=listdetail target/go-guests/kaya-go
run listdetail-csharp-swiftui env KAYA_SELFTEST=listdetail KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run listdetail-ocaml-swiftui env KAYA_SELFTEST=listdetail KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/split.exe
run listdetail-haskell-swiftui env KAYA_SELFTEST=listdetail "$(hs_bin split)"
run listdetail-swift-swiftui env KAYA_SELFTEST=listdetail target/swift-guests/split
run listdetail-java-swiftui env KAYA_SELFTEST=listdetail KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

# The background scene: work off the app thread, posted back. DEPTH
# TIER — rust only until the sweep lands the other seven. Its worker
# parks until a click releases it, so a binding that ran background
# work ON the app thread cannot deliver its own release and this leg
# TIMES OUT rather than failing an assertion: the deadlock is the gate
# (docs/background-work-plan.md §5).
KAYA_SELFTEST_SCRIPT="$(scene_script background)"
export KAYA_SELFTEST_SCRIPT
run background-rust-swiftui env KAYA_SELFTEST=background "$RUST_GUESTS"/background
run background-python-swiftui env KAYA_SELFTEST=background python3 guests/python/background.py
run background-go-swiftui env KAYA_SELFTEST=background target/go-guests/kaya-go
run background-csharp-swiftui env KAYA_SELFTEST=background KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run background-ocaml-swiftui env KAYA_SELFTEST=background KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/background.exe
run background-haskell-swiftui env KAYA_SELFTEST=background "$(hs_bin background)"
run background-swift-swiftui env KAYA_SELFTEST=background target/swift-guests/background
run background-java-swiftui env KAYA_SELFTEST=background KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

# The filedialog scene: the picker's request/result grammar and the
# capability it hands back, driving REAL NSOpenPanel chrome over
# accessibility, so it needs a logged-in GUI session.
#
# THE EIGHT LEGS ARE SPLIT ACROSS THE THREE PANEL VIEW MODES rather
# than all inheriting whichever one the machine is in (panel_mode_set
# above says why). The mode is a property of the PANEL, read by one
# language-independent reader, so crossing it with the language axis
# would buy nothing.
#
# A drain BEFORE the first group as well, because a mode is set for
# whatever is running, not for a leg.
KAYA_SELFTEST_SCRIPT="$(scene_script filedialog)"
export KAYA_SELFTEST_SCRIPT
drain
panel_mode_set 1 columns
run filedialog-rust-swiftui env KAYA_SELFTEST=filedialog "$RUST_GUESTS"/filedialog
run filedialog-python-swiftui env KAYA_SELFTEST=filedialog python3 guests/python/filedialog.py
run filedialog-go-swiftui env KAYA_SELFTEST=filedialog target/go-guests/kaya-go
drain
panel_mode_set 2 list
run filedialog-csharp-swiftui env KAYA_SELFTEST=filedialog KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run filedialog-ocaml-swiftui env KAYA_SELFTEST=filedialog KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/filedialog.exe
run filedialog-haskell-swiftui env KAYA_SELFTEST=filedialog "$(hs_bin filedialog)"
drain
panel_mode_set 3 icons
run filedialog-swift-swiftui env KAYA_SELFTEST=filedialog target/swift-guests/filedialog
run filedialog-java-swiftui env KAYA_SELFTEST=filedialog KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
drain
panel_modes_gap="$(panel_modes_missing)"
if [ -n "$panel_modes_gap" ]; then
    echo "validate-mac: the filedialog legs ran panel view modes \"$PANEL_MODES_RUN\" —" \
        "mode(s)$panel_modes_gap were exercised by nothing (1 columns, 2 list, 3 icons)." \
        "One of KayaPanelShape's three readers in swift/KayaSwiftUI.swift is dead code" \
        "this run, which is exactly how 2026-08-06 happened" >&2
    status=1
fi
panel_mode_restore || status=1

# The save scene: the round trip an editor walks (docs/save-plan.md
# D5), driving REAL NSSavePanel chrome over accessibility.
#
# NO PANEL VIEW MODE IS SET FOR IT, and that is measured rather than an
# omission: a save panel's COLLAPSED form publishes no file browser at
# all, its collapsed/expanded state is a DIFFERENT machine-wide
# preference (NSNavPanelExpandedStateForSaveMode), and the reader never
# looks for rows. Setting a mode here would exercise nothing and would
# leave a preference behind for the legs above.
KAYA_SELFTEST_SCRIPT="$(scene_script save)"
export KAYA_SELFTEST_SCRIPT
drain
# EACH SAVE LEG ALONE BETWEEN DRAINS, and the reason is the panel, not
# the scene: macOS remembers a save panel's last directory as a USER
# PREFERENCE shared by every process, so nine guests opening panels in
# one pool trample it — measured 2026-08-10, a leg asserting its own
# kaya-save-<pid> directory was shown a SIBLING leg's.
run save-rust-swiftui env KAYA_SELFTEST=save "$RUST_GUESTS"/save
# Java's leg rides the same script, and it is the only one that also
# proves a BINDING fix: until this milestone dev.kaya.KayaApp wrapped
# every mode's descriptor in a FileInputStream, so no Java app could
# write to a picked file on any platform (docs/save-plan.md D3). The
# save-back step is the first Java in the tree that writes through a
# picked handle — with the old binding it never reaches the file.
drain
run save-java-swiftui env KAYA_SELFTEST=save KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
drain
run save-python-swiftui env KAYA_SELFTEST=save python3 guests/python/save.py
drain
run save-go-swiftui env KAYA_SELFTEST=save target/go-guests/kaya-go
drain
run save-swift-swiftui env KAYA_SELFTEST=save target/swift-guests/save
drain
run save-haskell-swiftui env KAYA_SELFTEST=save "$(hs_bin save)"
drain
run save-csharp-swiftui env KAYA_SELFTEST=save KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
drain
run save-ocaml-swiftui env KAYA_SELFTEST=save KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/save.exe
# The C floor's save guest, which waits on no sugar: it decodes
# `file_dialog_result` by hand and tells the two dialogs apart by the id
# it minted, because on the wire the picker's answer and the save
# panel's ARE one record (docs/save-plan.md D2). It is the tier where
# the redeem-a-handle-then-write sequence is legible.
drain
run save-c-swiftui env KAYA_SELFTEST=save target/c-guests/save
drain

# THE TEXT EDITOR (docs/editor-plan.md), the only script on this lane
# that drives an APP rather than a feature.
#
# GO ALONE, AND NOT A DEPTH SLICE WAITING ON SEVEN BINDINGS: the plan
# chose Go so a BINDING's awkward corners would show, so there is no
# rust example and `editor` is in neither SCENES nor DEPTH_SCENES (both
# derive a `cargo build --example` this app does not want).
#
# ALONE BETWEEN DRAINS, for both reasons this file states elsewhere: it
# opens real NSSavePanel and NSOpenPanel chrome, whose last directory
# macOS remembers as a USER PREFERENCE shared by every process
# (measured 2026-08-10), and it injects REAL key events.
KAYA_SELFTEST_SCRIPT="$(scene_script editor)"
export KAYA_SELFTEST_SCRIPT
drain
run editor-go-swiftui env KAYA_SELFTEST=editor target/go-guests/kaya-go
drain

# THE STAMPED-ACCESSIBILITY SCENE (docs/tpl-props-plan.md P3): two
# entries stamped from one template, each carrying its own row's a11y
# identity, read back from the platform's real tree. A SEPARATE scene
# because the a11y scene asserts containers ordinally and a For's
# column would shift `column#0` per language.
KAYA_SELFTEST_SCRIPT="$(scene_script a11yrows)"
export KAYA_SELFTEST_SCRIPT
run a11yrows-rust-swiftui env KAYA_SELFTEST=a11yrows "$RUST_GUESTS"/a11yrows
run a11yrows-python-swiftui env KAYA_SELFTEST=a11yrows python3 guests/python/a11yrows.py
run a11yrows-go-swiftui env KAYA_SELFTEST=a11yrows target/go-guests/kaya-go
run a11yrows-csharp-swiftui env KAYA_SELFTEST=a11yrows KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run a11yrows-ocaml-swiftui env KAYA_SELFTEST=a11yrows KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/a11yrows.exe
run a11yrows-haskell-swiftui env KAYA_SELFTEST=a11yrows "$(hs_bin a11yrows)"
run a11yrows-swift-swiftui env KAYA_SELFTEST=a11yrows target/swift-guests/a11yrows
run a11yrows-java-swiftui env KAYA_SELFTEST=a11yrows KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
run a11yrows-c-swiftui env KAYA_SELFTEST=a11yrows target/c-guests/a11yrows
drain

# THE STYLING SCENE (docs/styling-plan.md slice 1): the brand accent,
# the role tier and the window inset. `heading` is frozen from the real
# tree (measured: SwiftUI's .isHeader IS the AXHeading role on macOS);
# the inset is asserted by measurement. The C floor rides too, spelling
# the brand record, the role prop and the inset wprop as the generated
# primitives they are (invariant 5's documentation tier).
KAYA_SELFTEST_SCRIPT="$(scene_script styling)"
export KAYA_SELFTEST_SCRIPT
run styling-rust-swiftui env KAYA_SELFTEST=styling "$RUST_GUESTS"/styling
run styling-python-swiftui env KAYA_SELFTEST=styling python3 guests/python/styling.py
run styling-go-swiftui env KAYA_SELFTEST=styling target/go-guests/kaya-go
run styling-swift-swiftui env KAYA_SELFTEST=styling target/swift-guests/styling
run styling-csharp-swiftui env KAYA_SELFTEST=styling KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run styling-ocaml-swiftui env KAYA_SELFTEST=styling KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/styling.exe
run styling-haskell-swiftui env KAYA_SELFTEST=styling "$(hs_bin styling)"
run styling-java-swiftui env KAYA_SELFTEST=styling KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
run styling-c-swiftui env KAYA_SELFTEST=styling target/c-guests/styling
drain

# The typeface scene: the brand typeface swaps the FAMILY and nothing
# else. A DEPTH slice — rust only, mac only — and the one assertion
# that matters reads the RESOLVED family off the real NSTextField and
# NSTextView, never the request: every font API on this platform
# renders something for a family it does not have.
KAYA_SELFTEST_SCRIPT="$(scene_script typeface)"
export KAYA_SELFTEST_SCRIPT
run typeface-rust-swiftui env KAYA_SELFTEST=typeface "$RUST_GUESTS"/typeface
drain

# The toolbar scene: the `primary` bit as real window chrome
# (docs/chrome-plan.md C2). Both assertions read the REAL NSToolbar.
# ENABLEMENT IS NOT NSToolbarItem.isEnabled, which stays true for a
# visibly disabled SwiftUI button — the read goes through the
# accessibility tree, where the disable actually lands.
#
# No C floor guest: guests/c/toolbar.c does not exist and the floor's
# Makefile SCENES does not name it, which check-steps' sweep_c_floor
# reads from the other side.
#
# POOLED: the scene's `click` is in-process, no chord is pressed, no
# window is closed, and every read is of this leg's own window.
KAYA_SELFTEST_SCRIPT="$(scene_script toolbar)"
export KAYA_SELFTEST_SCRIPT
run toolbar-rust-swiftui env KAYA_SELFTEST=toolbar "$RUST_GUESTS"/toolbar
run toolbar-python-swiftui env KAYA_SELFTEST=toolbar python3 guests/python/toolbar.py
run toolbar-go-swiftui env KAYA_SELFTEST=toolbar target/go-guests/kaya-go
run toolbar-swift-swiftui env KAYA_SELFTEST=toolbar target/swift-guests/toolbar
run toolbar-csharp-swiftui env KAYA_SELFTEST=toolbar KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run toolbar-ocaml-swiftui env KAYA_SELFTEST=toolbar KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/toolbar.exe
run toolbar-haskell-swiftui env KAYA_SELFTEST=toolbar "$(hs_bin toolbar)"
run toolbar-java-swiftui env KAYA_SELFTEST=toolbar KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
drain

# The identity scene (docs/app-identity-plan.md).
#
# THESE LEGS PUT A DOCK TILE ON THE SCREEN, and that is ruling 2 rather
# than a side effect. An `.accessory` app — every other leg on this
# lane, so a suite never steals the human's keyboard — has NO DOCK TILE
# to put a picture in: measured, the setter succeeded, the image read
# back at 512x512, and the Dock did not move one pixel. So an app that
# DECLARES an identity becomes `.regular`. They do not ACTIVATE
# (KAYA_ACTIVATE=1 gates that), so the tiles appear and go without
# taking the front.
#
# THE POLICY IS RAISED LATE, which was the plan's one open question:
# the identity arrives while the app is building its first screen. It
# works — captured 2026-08-18, the declared mark in this machine's Dock
# beside thirteen rounded system icons, unmasked.
#
# POOLED: the scene's `click` is in-process, no chord is pressed, no
# window is closed, and both icon reads are of this process's own
# AppKit state.
#
# NO C FLOOR LEG: guests/c/identity.c does not exist and the floor's
# Makefile SCENES does not name it, which check-steps' sweep_c_floor
# reads from the other side.
KAYA_SELFTEST_SCRIPT="$(scene_script identity)"
export KAYA_SELFTEST_SCRIPT
run identity-rust-swiftui env KAYA_SELFTEST=identity "$RUST_GUESTS"/identity
run identity-python-swiftui env KAYA_SELFTEST=identity python3 guests/python/identity.py
run identity-go-swiftui env KAYA_SELFTEST=identity target/go-guests/kaya-go
run identity-swift-swiftui env KAYA_SELFTEST=identity target/swift-guests/identity
run identity-csharp-swiftui env KAYA_SELFTEST=identity KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run identity-ocaml-swiftui env KAYA_SELFTEST=identity KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/identity.exe
run identity-haskell-swiftui env KAYA_SELFTEST=identity "$(hs_bin identity)"
run identity-java-swiftui env KAYA_SELFTEST=identity KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
drain

# The assets conformance scene (docs/assets-plan.md).
#
# THIS LANE STAGES NOTHING, and that is the assertion: no
# KAYA_ASSET_DIR is exported anywhere below, so the core resolves the
# root by its compile-time repo-relative default — and the frozen
# census in tools/scenes/assets.steps is what proves it found the whole
# root rather than one file.
#
# ALL NINE TIERS, including the C FLOOR — the only scene that has one
# beside the eight hosted guests, because the floor is where
# `kaya_asset_open` and `kaya_asset_blob` are documented longhand.
KAYA_SELFTEST_SCRIPT="$(scene_script assets)"
export KAYA_SELFTEST_SCRIPT
run assets-rust-swiftui env KAYA_SELFTEST=assets "$RUST_GUESTS"/assets
run assets-python-swiftui env KAYA_SELFTEST=assets python3 guests/python/assets.py
run assets-go-swiftui env KAYA_SELFTEST=assets target/go-guests/kaya-go
run assets-swift-swiftui env KAYA_SELFTEST=assets target/swift-guests/assets
run assets-csharp-swiftui env KAYA_SELFTEST=assets KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run assets-ocaml-swiftui env KAYA_SELFTEST=assets KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/assets.exe
run assets-haskell-swiftui env KAYA_SELFTEST=assets "$(hs_bin assets)"
run assets-java-swiftui env KAYA_SELFTEST=assets KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
run assets-c-swiftui env KAYA_SELFTEST=assets target/c-guests/assets
drain

# The clipboard scene: one clip in several representations, and the
# privileged read. Still a DEPTH slice while the bindings fan out, and
# it drives the platform's own clipboard tools as child processes —
# pbcopy, pbpaste, osascript and sips — so every assertion crosses a
# process boundary rather than reading back what kaya itself wrote.
KAYA_SELFTEST_SCRIPT="$(scene_script clipboard)"
export KAYA_SELFTEST_SCRIPT
# The leading drain completes the drain/run/drain bracket check-steps
# pins on every runner's clipboard legs: one system clipboard per
# session, so no clipboard leg may share the pool with anything.
drain
run clipboard-rust-swiftui env KAYA_SELFTEST=clipboard "$RUST_GUESTS"/clipboard
drain
run clipboard-python-swiftui env KAYA_SELFTEST=clipboard python3 guests/python/clipboard.py
drain
run clipboard-go-swiftui env KAYA_SELFTEST=clipboard target/go-guests/kaya-go
drain
run clipboard-swift-swiftui env KAYA_SELFTEST=clipboard target/swift-guests/clipboard
drain
run clipboard-csharp-swiftui env KAYA_SELFTEST=clipboard KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
drain
run clipboard-ocaml-swiftui env KAYA_SELFTEST=clipboard KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/clipboard.exe
drain
run clipboard-haskell-swiftui env KAYA_SELFTEST=clipboard "$(hs_bin clipboard)"
drain
run clipboard-java-swiftui env KAYA_SELFTEST=clipboard KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
drain

# The undo scene: one history over two tiers, walked newest-first
# (docs/undo-plan.md §3).
#
# ALONE BETWEEN DRAINS, and the reason is the `type` verb rather than
# the scene: it delivers REAL KEYSTROKES, and a backend that ever
# synthesizes those at the system level puts them on the input queue of
# whatever is FRONTMOST (docs/traps.md). The mac arm delivers them
# in-process, so this bracket currently buys insurance.
KAYA_SELFTEST_SCRIPT="$(scene_script undo)"
export KAYA_SELFTEST_SCRIPT
drain
run undo-rust-swiftui env KAYA_SELFTEST=undo "$RUST_GUESTS"/undo
drain
# The AMBIENT tier's undo guest: a handler does not open its transaction
# here, so the group is named from inside it (kaya.undoable).
run undo-python-swiftui env KAYA_SELFTEST=undo python3 guests/python/undo.py
drain
# The HANDLE tier's undo guest, beside its clipboard sibling: the group
# is named on the transaction the handler was handed (tx.Undoable), and
# the clear that finishes the form is the posted second one — Go's
# spelling of "another transaction, right after this one", since a
# handler already holds one and Build-in-Build is refused.
run undo-go-swiftui env KAYA_SELFTEST=undo target/go-guests/kaya-go
drain
# The C floor's undo guest: the head-of-batch undo_group record spelled
# out, and the only reader of the undone/redone body that decodes it by
# hand instead of through a binding's fold.
run undo-c-swiftui env KAYA_SELFTEST=undo target/c-guests/undo
drain
run undo-haskell-swiftui env KAYA_SELFTEST=undo "$(hs_bin undo)"
drain
run undo-swift-swiftui env KAYA_SELFTEST=undo target/swift-guests/undo
drain
run undo-csharp-swiftui env KAYA_SELFTEST=undo KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
drain
run undo-ocaml-swiftui env KAYA_SELFTEST=undo KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/undo.exe
drain
run undo-java-swiftui env KAYA_SELFTEST=undo KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
drain

KAYA_SELFTEST_SCRIPT="$(scene_script scroll)"
export KAYA_SELFTEST_SCRIPT
run scroll-rust-swiftui env KAYA_SELFTEST=scroll "$RUST_GUESTS"/scroll
run scroll-python-swiftui env KAYA_SELFTEST=scroll python3 guests/python/scroll.py
run scroll-go-swiftui env KAYA_SELFTEST=scroll target/go-guests/kaya-go
run scroll-csharp-swiftui env KAYA_SELFTEST=scroll KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run scroll-ocaml-swiftui env KAYA_SELFTEST=scroll KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/scroll.exe
run scroll-haskell-swiftui env KAYA_SELFTEST=scroll "$(hs_bin scroll)"
run scroll-swift-swiftui env KAYA_SELFTEST=scroll target/swift-guests/scroll
run scroll-java-swiftui env KAYA_SELFTEST=scroll KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script progress)"
export KAYA_SELFTEST_SCRIPT
run progress-rust-swiftui env KAYA_SELFTEST=progress "$RUST_GUESTS"/progress
run progress-python-swiftui env KAYA_SELFTEST=progress python3 guests/python/progress.py
run progress-go-swiftui env KAYA_SELFTEST=progress target/go-guests/kaya-go
run progress-csharp-swiftui env KAYA_SELFTEST=progress KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run progress-ocaml-swiftui env KAYA_SELFTEST=progress KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/progress.exe
run progress-haskell-swiftui env KAYA_SELFTEST=progress "$(hs_bin progress)"
run progress-swift-swiftui env KAYA_SELFTEST=progress target/swift-guests/progress
run progress-java-swiftui env KAYA_SELFTEST=progress KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script select)"
export KAYA_SELFTEST_SCRIPT
run select-rust-swiftui env KAYA_SELFTEST=select "$RUST_GUESTS"/select
run select-python-swiftui env KAYA_SELFTEST=select python3 guests/python/select.py
run select-go-swiftui env KAYA_SELFTEST=select target/go-guests/kaya-go
run select-csharp-swiftui env KAYA_SELFTEST=select KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run select-ocaml-swiftui env KAYA_SELFTEST=select KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/select.exe
run select-haskell-swiftui env KAYA_SELFTEST=select "$(hs_bin select)"
run select-swift-swiftui env KAYA_SELFTEST=select target/swift-guests/select
run select-java-swiftui env KAYA_SELFTEST=select KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script radio)"
export KAYA_SELFTEST_SCRIPT
run radio-rust-swiftui env KAYA_SELFTEST=radio "$RUST_GUESTS"/radio
run radio-python-swiftui env KAYA_SELFTEST=radio python3 guests/python/radio.py
run radio-go-swiftui env KAYA_SELFTEST=radio target/go-guests/kaya-go
run radio-csharp-swiftui env KAYA_SELFTEST=radio KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run radio-ocaml-swiftui env KAYA_SELFTEST=radio KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/radio.exe
run radio-haskell-swiftui env KAYA_SELFTEST=radio "$(hs_bin radio)"
run radio-swift-swiftui env KAYA_SELFTEST=radio target/swift-guests/radio
run radio-java-swiftui env KAYA_SELFTEST=radio KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script grid)"
export KAYA_SELFTEST_SCRIPT
run grid-rust-swiftui env KAYA_SELFTEST=grid "$RUST_GUESTS"/grid
run grid-python-swiftui env KAYA_SELFTEST=grid python3 guests/python/grid.py
run grid-go-swiftui env KAYA_SELFTEST=grid target/go-guests/kaya-go
run grid-csharp-swiftui env KAYA_SELFTEST=grid KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run grid-ocaml-swiftui env KAYA_SELFTEST=grid KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/grid.exe
run grid-haskell-swiftui env KAYA_SELFTEST=grid "$(hs_bin grid)"
run grid-swift-swiftui env KAYA_SELFTEST=grid target/swift-guests/grid
run grid-java-swiftui env KAYA_SELFTEST=grid KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script textarea)"
export KAYA_SELFTEST_SCRIPT
run textarea-rust-swiftui env KAYA_SELFTEST=textarea "$RUST_GUESTS"/textarea
run textarea-python-swiftui env KAYA_SELFTEST=textarea python3 guests/python/textarea.py
run textarea-go-swiftui env KAYA_SELFTEST=textarea target/go-guests/kaya-go
run textarea-csharp-swiftui env KAYA_SELFTEST=textarea KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run textarea-ocaml-swiftui env KAYA_SELFTEST=textarea KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/textarea.exe
run textarea-haskell-swiftui env KAYA_SELFTEST=textarea "$(hs_bin textarea)"
run textarea-swift-swiftui env KAYA_SELFTEST=textarea target/swift-guests/textarea
run textarea-java-swiftui env KAYA_SELFTEST=textarea KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script sections)"
export KAYA_SELFTEST_SCRIPT
run sections-rust-swiftui env KAYA_SELFTEST=sections "$RUST_GUESTS"/sections
run sections-python-swiftui env KAYA_SELFTEST=sections python3 guests/python/sections.py
run sections-go-swiftui env KAYA_SELFTEST=sections target/go-guests/kaya-go
run sections-csharp-swiftui env KAYA_SELFTEST=sections KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run sections-ocaml-swiftui env KAYA_SELFTEST=sections KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/sections.exe
run sections-haskell-swiftui env KAYA_SELFTEST=sections "$(hs_bin sections)"
run sections-swift-swiftui env KAYA_SELFTEST=sections target/swift-guests/sections
run sections-java-swiftui env KAYA_SELFTEST=sections KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script menus)"
export KAYA_SELFTEST_SCRIPT
run menus-rust-swiftui env KAYA_SELFTEST=menus "$RUST_GUESTS"/menus
run menus-python-swiftui env KAYA_SELFTEST=menus python3 guests/python/menus.py
run menus-go-swiftui env KAYA_SELFTEST=menus target/go-guests/kaya-go
run menus-csharp-swiftui env KAYA_SELFTEST=menus KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run menus-ocaml-swiftui env KAYA_SELFTEST=menus KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/menus.exe
run menus-haskell-swiftui env KAYA_SELFTEST=menus "$(hs_bin menus)"
run menus-swift-swiftui env KAYA_SELFTEST=menus target/swift-guests/menus
run menus-java-swiftui env KAYA_SELFTEST=menus KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

# The a11y scene: the two universal accessibility props read back out
# of the PLATFORM'S OWN accessibility tree, over EVERY widget kind.
# Asserts both halves — names DERIVED by the control from its own
# caption, and names AUTHORED where there is no caption.
# These legs run POOLED like every other scene. They were serialized
# for a few hours on 2026-07-25 while the read's hangs were misread as
# contention; the defect was a lock inversion inside the read itself
# (docs/traps.md), and the barrier came back out.
KAYA_SELFTEST_SCRIPT="$(scene_script a11y)"
export KAYA_SELFTEST_SCRIPT
run a11y-rust-swiftui env KAYA_SELFTEST=a11y "$RUST_GUESTS"/a11y
run a11y-python-swiftui env KAYA_SELFTEST=a11y python3 guests/python/a11y.py
run a11y-go-swiftui env KAYA_SELFTEST=a11y target/go-guests/kaya-go
run a11y-csharp-swiftui env KAYA_SELFTEST=a11y KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run a11y-ocaml-swiftui env KAYA_SELFTEST=a11y KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/a11y.exe
run a11y-haskell-swiftui env KAYA_SELFTEST=a11y "$(hs_bin a11y)"
run a11y-swift-swiftui env KAYA_SELFTEST=a11y target/swift-guests/a11y
run a11y-java-swiftui env KAYA_SELFTEST=a11y KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

# The commands scene, the DEPTH slice (rust only until the sweep): a
# chord on every leaf kind — a checkable command and one option of a
# group, not just plain actions — the punctuation keys those chords
# need, and the `settings` role, which macOS shows in the APPLICATION
# menu while the item stays addressable where the app declared it.
KAYA_SELFTEST_SCRIPT="$(scene_script commands)"
export KAYA_SELFTEST_SCRIPT
run commands-rust-swiftui env KAYA_SELFTEST=commands "$RUST_GUESTS"/commands
run commands-python-swiftui env KAYA_SELFTEST=commands python3 guests/python/commands.py
run commands-go-swiftui env KAYA_SELFTEST=commands target/go-guests/kaya-go
run commands-csharp-swiftui env KAYA_SELFTEST=commands KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run commands-ocaml-swiftui env KAYA_SELFTEST=commands KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/commands.exe
run commands-haskell-swiftui env KAYA_SELFTEST=commands "$(hs_bin commands)"
run commands-swift-swiftui env KAYA_SELFTEST=commands target/swift-guests/commands
run commands-java-swiftui env KAYA_SELFTEST=commands KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

# The confirm scene: the REAL platform dialog, all three answer paths.
# The stall diagnostic (crates/kaya/src/stall.rs): the one scene that
# deliberately blocks the app thread, in EVERY LANGUAGE — a diagnostic
# that only fired for Rust guests would leave seven bindings exactly as
# blind as before.
#
# ITS OWN SCRIPT EXPORT, like every group here. KAYA_SELFTEST_SCRIPT is
# exported once per scene and PERSISTS, so a leg placed after another
# scene's export silently runs that scene's steps — which this one did.
KAYA_SELFTEST_SCRIPT="$(scene_script stall)"
export KAYA_SELFTEST_SCRIPT
run stall-rust-swiftui env KAYA_SELFTEST=stall "$RUST_GUESTS"/stall
run stall-python-swiftui env KAYA_SELFTEST=stall python3 guests/python/stall.py
run stall-go-swiftui env KAYA_SELFTEST=stall target/go-guests/kaya-go
run stall-csharp-swiftui env KAYA_SELFTEST=stall KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run stall-ocaml-swiftui env KAYA_SELFTEST=stall KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/stall.exe
run stall-haskell-swiftui env KAYA_SELFTEST=stall "$(hs_bin stall)"
run stall-swift-swiftui env KAYA_SELFTEST=stall target/swift-guests/stall
run stall-java-swiftui env KAYA_SELFTEST=stall KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

KAYA_SELFTEST_SCRIPT="$(scene_script confirm)"
export KAYA_SELFTEST_SCRIPT
run confirm-rust-swiftui env KAYA_SELFTEST=confirm "$RUST_GUESTS"/confirm
run confirm-python-swiftui env KAYA_SELFTEST=confirm python3 guests/python/confirm.py
run confirm-go-swiftui env KAYA_SELFTEST=confirm target/go-guests/kaya-go
run confirm-csharp-swiftui env KAYA_SELFTEST=confirm KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run confirm-ocaml-swiftui env KAYA_SELFTEST=confirm KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/confirm.exe
run confirm-haskell-swiftui env KAYA_SELFTEST=confirm "$(hs_bin confirm)"
run confirm-swift-swiftui env KAYA_SELFTEST=confirm target/swift-guests/confirm
run confirm-java-swiftui env KAYA_SELFTEST=confirm KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main

# The dirty scene (docs/dirty-plan.md). The app declares one boolean
# and macOS shows the dot in the close button; expect_dirty reads that
# dot back through the accessibility tree (AXEdited on the close
# button — measured to be exactly where it lives), never the model.
#
# DEPTH until the sugar lands in the other seven bindings. The C floor
# does not wait on them: it takes no sugar at all, so its guest is
# writable the day the wire constant exists.
KAYA_SELFTEST_SCRIPT="$(scene_script dirty)"
export KAYA_SELFTEST_SCRIPT
run dirty-rust-swiftui env KAYA_SELFTEST=dirty "$RUST_GUESTS"/dirty
# Python's guest: the prop is a keyword argument on the window
# construct, and setting it later is THAT CONSTRUCT CALLED AGAIN —
# `app.window(dirty=True)` without the `with`, since a handler already
# runs inside the transaction the binding opened. No loose function:
# a window attribute lives nowhere but the construct (DESIGN.md).
run dirty-python-swiftui env KAYA_SELFTEST=dirty python3 guests/python/dirty.py
# OCaml's guest: the prop is a labelled argument on the window construct
# ([~dirty]), and setting it later is that construct called again inside
# the handler — an ambient binding's handler already IS the transaction.
run dirty-ocaml-swiftui env KAYA_SELFTEST=dirty KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/dirty.exe
# The C floor's dirty guest: the prop spelled as the SET_WINDOW_PROP
# record it is. It is also the floor's first reader of close_requested
# and alert_result, neither of which the generator emits a parser for,
# so the veto/confirm composition is decoded by hand here.
run dirty-c-swiftui env KAYA_SELFTEST=dirty target/c-guests/dirty
run dirty-go-swiftui env KAYA_SELFTEST=dirty target/go-guests/kaya-go
run dirty-haskell-swiftui env KAYA_SELFTEST=dirty "$(hs_bin dirty)"
run dirty-swift-swiftui env KAYA_SELFTEST=dirty target/swift-guests/dirty
run dirty-csharp-swiftui env KAYA_SELFTEST=dirty KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"

# The text-ranges scene. Every assertion reads the PLATFORM'S
# accessibility tree, never kaya's memory of what it declared.
#
# DEPTH, rust-only, until the sugar reaches the other seven bindings
# and the four other backends grow their arms — which is why gtk.rs,
# winui/mod.rs, KayaCompose.kt and this file's iOS half all carry
# `depth_stub("ranges")`.
KAYA_SELFTEST_SCRIPT="$(scene_script ranges)"
export KAYA_SELFTEST_SCRIPT
run ranges-rust-swiftui env KAYA_SELFTEST=ranges "$RUST_GUESTS"/ranges
run ranges-python-swiftui env KAYA_SELFTEST=ranges python3 guests/python/ranges.py
# The C floor's ranges guest, which does not wait on the seven sugar
# bindings because it takes no sugar. It is also where the unit ruling
# is most legible — `at - doc` is a pointer difference into the app's
# own buffer, i.e. a UTF-8 byte offset, and the frozen 57/203/753 are
# those bytes rather than the 51/197/747 a UTF-16 counter would give.
run ranges-c-swiftui env KAYA_SELFTEST=ranges target/c-guests/ranges
# The C# guest, where the unit ruling costs something rather than being
# free: .NET's IndexOf answers in UTF-16 code units, so this leg passes
# only if the binding's TextRange.In converted — an unconverted hit
# decorates `e 02:` instead of `alpha`, six characters early, and the
# scene's frozen offsets say so (watched failing, docs/probes/ranges-csharp.md).
run ranges-csharp-swiftui env KAYA_SELFTEST=ranges KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run ranges-go-swiftui env KAYA_SELFTEST=ranges target/go-guests/kaya-go
run ranges-java-swiftui env KAYA_SELFTEST=ranges KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
run ranges-haskell-swiftui env KAYA_SELFTEST=ranges "$(hs_bin ranges)"
run ranges-swift-swiftui env KAYA_SELFTEST=ranges target/swift-guests/ranges
run ranges-ocaml-swiftui env KAYA_SELFTEST=ranges KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/ranges.exe
KAYA_SELFTEST_SCRIPT="$(scene_script align)"
export KAYA_SELFTEST_SCRIPT
run align-rust-swiftui env KAYA_SELFTEST=align "$RUST_GUESTS"/align
run align-python-swiftui env KAYA_SELFTEST=align python3 guests/python/align.py
run align-go-swiftui env KAYA_SELFTEST=align target/go-guests/kaya-go
run align-csharp-swiftui env KAYA_SELFTEST=align KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run align-ocaml-swiftui env KAYA_SELFTEST=align KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/align.exe
run align-haskell-swiftui env KAYA_SELFTEST=align "$(hs_bin align)"
run align-swift-swiftui env KAYA_SELFTEST=align target/swift-guests/align
run align-java-swiftui env KAYA_SELFTEST=align KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
drain
KAYA_SELFTEST_SCRIPT="$(scene_script layout)"
export KAYA_SELFTEST_SCRIPT
run layout-rust-swiftui env KAYA_SELFTEST=layout "$RUST_GUESTS"/layout
run layout-python-swiftui env KAYA_SELFTEST=layout python3 guests/python/layout.py
run layout-go-swiftui env KAYA_SELFTEST=layout target/go-guests/kaya-go
run layout-csharp-swiftui env KAYA_SELFTEST=layout KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    dotnet exec "$CS_GUEST"
run layout-ocaml-swiftui env KAYA_SELFTEST=layout KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    _build/default/guests/ocaml/layout.exe
run layout-haskell-swiftui env KAYA_SELFTEST=layout "$(hs_bin layout)"
run layout-swift-swiftui env KAYA_SELFTEST=layout target/swift-guests/layout
run layout-java-swiftui env KAYA_SELFTEST=layout KAYA_LIB="$ROOT/target/debug/libkaya.dylib" \
    java -XstartOnFirstThread -cp target/java-guests dev.kaya.milestone2kt.Main
unset KAYA_SWIFTUI_LIB KAYA_SELFTEST_SCRIPT
drain
timing legs

rec_suite_stop
[ -z "${KAYA_RECORD:-}" ] || timing recording-stop+stills

# The one-line verdict: suites accumulate failures rather than abort,
# so a truncated log must still end with the answer.
if [ "$status" = 0 ]; then echo "validate-mac: ALL PASS"; else echo "validate-mac: FAILURES ABOVE"; fi
exit "$status"
