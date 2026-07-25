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
# The whole matrix, one invocation. The five lanes are independent
# (each proves its own platform against its own devices), so they run
# CONCURRENTLY by default — the matrix is bounded by its slowest lane
# (~1 minute warm, ratified 2026-07-22) instead of the ~4 minute sum.
# --serial keeps the old one-at-a-time behavior for the special
# cases: benchmarking a single lane's honest numbers, debugging under
# contention, or recording mode (one screen, one recorder).
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
run_lane mac tools/validate-mac.sh
run_lane linux tools/validate-linux.sh
run_lane windows tools/deploy-win.sh "$HOST" all
run_lane ios tools/ios/run-sim.sh
run_lane android tools/android/run-emulator.sh

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
            status=1
        fi
        legs=$(grep -c ": PASS" "$LANES_DIR/$name.log" 2>/dev/null)
        legs=${legs:-0}
        echo "$name: $verdict (${secs}s, $legs legs)"
        # DURATION IS A CORRECTNESS SIGNAL, not just a stat. CLAUDE.md
        # states that a duration anomaly is a bug signal; until now
        # nothing enforced it, so a lane could quietly get six times
        # slower and still report ALL PASS.
        #
        # Measured 2026-07-25: exporting GTK_A11Y=atspi lane-wide took
        # linux from 65s to 393s — a change in blast radius, not in any
        # assertion. The failures it caused were legible, but a
        # SLOWDOWN with no failures is exactly the shape that ships.
        #
        # Ceilings are per lane and deliberately loose (roughly 3x the
        # warm time): this catches a regression in KIND, not jitter. A
        # legitimately slower lane raises its number in the same commit
        # that makes it slower, which is the conversation worth forcing.
        case "$name" in
            mac) budget=400 ;;
            linux) budget=300 ;;
            windows) budget=400 ;;
            ios) budget=300 ;;
            android) budget=250 ;;
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
