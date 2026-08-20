#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The whole matrix, one invocation. The five lanes are independent, so
# they run CONCURRENTLY by default; --serial for benchmarking a single
# lane's honest numbers, debugging under contention, or recording mode
# (one screen, one recorder).
#
# Usage: validate-all.sh [--serial] [windows-host]
#   windows-host defaults to akhil@192.168.64.2 (the UTM VM;
#   deploy-win auto-starts it).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

MODE=parallel
HOST="akhil@192.168.64.2"
for arg in "$@"; do
    case "$arg" in
        --serial) MODE=serial ;;
        *) HOST="$arg" ;;
    esac
done

LANES_DIR="$(mktemp -d)"
# A FAILING LANE'S LOG OUTLIVES THE RUN: a transient nobody can look at
# is indistinguishable from a bug nobody found. Passing lanes leave
# nothing behind.
KEEP_DIR="$ROOT/target/validate-failures"
trap 'rm -rf "$LANES_DIR"' EXIT

lane_names=()
lane_pids=()
run_lane() {
    local name="$1"
    shift
    if [ "$MODE" = serial ]; then
        echo "== $name =="
        local t0=$SECONDS
        if "$@" >"$LANES_DIR/$name.log" 2>&1; then
            echo "$name: PASS ($((SECONDS - t0))s)"
        else
            cat "$LANES_DIR/$name.log"
            echo "$name: FAIL ($((SECONDS - t0))s)"
            status=1
        fi
        return
    fi
    (
        t0=$SECONDS
        if "$@" >"$LANES_DIR/$name.log" 2>&1; then
            echo "PASS $((SECONDS - t0))" >"$LANES_DIR/$name.verdict"
        else
            echo "FAIL $((SECONDS - t0))" >"$LANES_DIR/$name.verdict"
        fi
    ) &
    lane_pids+=($!)
    lane_names+=("$name")
}

status=0
T0=$SECONDS
if [ "$MODE" = parallel ]; then
    # THE GATE SWEEP RUNS AS ITS OWN CONCURRENT UNIT, ONCE (ratified
    # 2026-08-20): inside the mac lane it sat serially in front of the
    # matrix's slowest path, under five-lane contention — measured, a
    # 250s sweep ahead of 280s of legs, and moving it BEFORE the lanes
    # just relocated the same serialization. The sweep does not need to
    # PRECEDE anything: the matrix's verdict includes its rc exactly as
    # it includes each lane's, and a failed sweep fails the matrix. The
    # token is a fingerprint of every keyed gate's input set computed at
    # t0 — it attests SAME-TREE, not swept-and-passed — and the mac
    # lane skips its own sweep only while the fingerprint still matches
    # (a within-run handshake, not a cache — nothing survives this
    # invocation; a hand-run of validate-mac sees no token and sweeps).
    # The sweep's two probe windows never take key focus and the other
    # lanes' windows live in a container, emulators, a simulator and a
    # VM, so nothing here fights the mac legs for the desktop.
    KAYA_MATRIX_GATES_TOKEN="$(tools/gates.sh --fingerprint)" || exit 1
    export KAYA_MATRIX_GATES_TOKEN
    run_lane gates tools/gates.sh
    run_lane mac tools/validate-mac.sh
    run_lane linux tools/validate-linux.sh
    run_lane windows tools/deploy-win.sh "$HOST" all
    run_lane ios tools/ios/run-sim.sh
    run_lane android tools/android/run-emulator.sh
else
    run_lane mac tools/validate-mac.sh
    run_lane linux tools/validate-linux.sh
    run_lane windows tools/deploy-win.sh "$HOST" all
    run_lane ios tools/ios/run-sim.sh
    run_lane android tools/android/run-emulator.sh
fi

if [ "$MODE" = parallel ]; then
    if [ ${#lane_pids[@]} -gt 0 ]; then
        wait "${lane_pids[@]}" 2>/dev/null || true
    fi
    for name in "${lane_names[@]}"; do
        read -r verdict secs <"$LANES_DIR/$name.verdict" 2>/dev/null \
            || { verdict=FAIL; secs='?'; }
        if [ "$verdict" != PASS ]; then
            echo "== $name (log) =="
            cat "$LANES_DIR/$name.log"
            mkdir -p "$KEEP_DIR"
            cp "$LANES_DIR/$name.log" "$KEEP_DIR/$name.log"
            echo "== $name log kept at target/validate-failures/$name.log =="
            status=1
        fi
        legs=$(grep -c ": PASS" "$LANES_DIR/$name.log" 2>/dev/null)
        legs=${legs:-0}
        echo "$name: $verdict (${secs}s, $legs legs)"
        # DURATION IS A CORRECTNESS SIGNAL (CLAUDE.md invariant 8): a
        # lane can get six times slower and still report ALL PASS.
        # Measured 2026-07-25: exporting GTK_A11Y=atspi lane-wide took
        # linux from 65s to 393s — a change in blast radius, not in any
        # assertion. A slower lane raises its number in the same commit
        # that makes it slower; each `case` arm carries that measurement.
        case "$name" in
            # 900 since 2026-08-10, raised in the commit that makes the
            # lane slower, as this block asks. The save scene brought
            # NINE legs that must run ALONE BETWEEN DRAINS: macOS keeps a
            # save panel's last directory as a user preference shared by
            # every process, so pooled guests trample each other (measured
            # — a leg asserting its own kaya-save-<pid> directory was
            # shown a sibling's). Serialising ~18s x 9 costs about 170s
            # that used to overlap: the lane measured 610s pooled and
            # 778s serialised, same 267 legs. 900 keeps the ~1.25x
            # headroom the other lanes have (the earlier 678s reading,
            # which this block previously declined to raise for, was an
            # environmental window and is NOT the reason for this one).
            #
            # LOWERED TO 560 on 2026-08-10, and lowering a ceiling is the
            # rarer half of this block's job. The lane stopped running
            # its guests out of `target/debug/examples`, a build
            # directory that had reached 776,613 entries — macOS
            # enumerates an unbundled executable's siblings on every
            # launch, so all 32 rust legs walked it, and the resulting
            # LaunchServices contention starved the ocaml, haskell and
            # swift legs running beside them. All eight languages now
            # measure 1.1-1.6s a leg where four of them were 8-31s
            # (docs/deferred.md).
            #
            # Measured on the fixed tree: 431s contended at 268 legs,
            # against 966s the run before. 560 is the same ~1.25x over
            # the contended time the other lanes keep — and holding 900
            # here would let this lane double again before saying a
            # word, which is exactly what let the old cost hide.
            mac) budget=560 ;;
            # 450 since 2026-08-20, raised in the commit that made the
            # lane bigger, as this block asks: the panes scene added 14
            # legs (seven languages, both protocols), 550 -> 564.
            # STANDALONE the lane is UNCHANGED in kind — 564 legs green
            # in the runs that landed the slice, panes legs 2-3s each —
            # and the first contended matrix after read 442s against the
            # old 420, which is the ~28s the legs themselves cost. 450
            # keeps the same ~1.25x-over-contended headroom this block
            # has always kept.
            #
            # The history it extends: 420 since 2026-08-07, when
            # text-ranges added 16 legs (444 -> 460; contended 337s
            # measured thrice against the old 300-at-~240s).
            linux) budget=450 ;;
            # 480 since 2026-08-03, and the ceiling moved in the commit
            # that made the lane slower, as this block asks. Two
            # measured reasons, neither a change in kind: filedialog_java
            # used to ABORT at 4s (the COM apartment defect) and now runs
            # its scene to the end, and the lane's four
            # contention-sensitive legs (stall_rust, panels_*) each take
            # 20-26s longer under five concurrent lanes. Everything else
            # is unchanged — the per-leg median delta against a
            # standalone run is MINUS one second, which is the check that
            # says no work was added to every leg.
            windows) budget=480 ;;
            # 540 since 2026-08-10, raised in the commit that makes the
            # lane slower, as this block asks. The save scene added a leg
            # measured at 21s STANDALONE (the panel is typed into, so it
            # is the slowest non-clipboard leg on this lane), taking the
            # lane to 74 legs. Contended runs since: 401, 407, 409, 414,
            # 416 and 446s against a 420 ceiling — one crossing and two
            # within five seconds, which is a guard that fires on
            # variance rather than on a change in kind. Standalone the
            # lane is 294s (boot 7 + three build-and-leg phases), so the
            # growth is contention amplifying real work, not work added
            # to every leg. 540 restores the ~1.25x headroom the other
            # lanes keep.
            #
            # MAC WAS DELIBERATELY NOT RAISED at the same time: it
            # measured 678s against 680 once, but that run overlapped a
            # ~20-minute window when every mac file-dialog leg failed for
            # an environmental reason (proven by running two unrelated
            # legs as controls); with the scene fully graduated it
            # measures 610s at 267 legs. Raising a ceiling to fit an
            # environmental anomaly is how a guard stops guarding.
            ios) budget=540 ;;
            # 310 since 2026-08-20: the pool-degradation trap's remedy
            # is a COLD BOOT (docs/traps.md), and the reboot run then
            # carries ~60-90s of emulator startup that the old 250 —
            # set against a warm pool — read as an anomaly. 310 clears
            # a measured cold-boot run (267s) with the usual headroom
            # while still catching a change in kind on a warm one.
            android) budget=310 ;;
            # The sweep as its own concurrent unit (2026-08-20):
            # measured 250s under five-lane contention the day it moved
            # out of the mac lane; ~1.25x headroom like the others.
            gates) budget=310 ;;
            *) budget=0 ;;
        esac
        if [ "$budget" -gt 0 ] && [ "$secs" != '?' ] && [ "$secs" -gt "$budget" ]; then
            echo "$name: DURATION ANOMALY — ${secs}s exceeds the ${budget}s ceiling." \
                "A lane that slows down by this much changed in kind, not in degree:" \
                "look for work added to EVERY leg (an env export, a per-leg wait, a" \
                "rebuild that stopped caching) before assuming it is load."
            status=1
        fi
    done
fi

echo "TIMING matrix $((SECONDS - T0))s ($MODE)"
if [ "$status" = 0 ]; then
    echo "validate-all: ALL PASS"
else
    echo "validate-all: FAILURES ABOVE"
fi
exit "$status"
