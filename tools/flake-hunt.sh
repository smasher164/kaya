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
# Run one lane N times and report WHICH LEGS EVER FAIL, and how often.
#
# Usage: tools/flake-hunt.sh <lane> [runs] [--serial|--parallel]
#        lane: mac | linux | windows
#        runs: default 5
#
# ONE LEG AT A TIME IS USUALLY WHAT YOU WANT: set KAYA_ONLY (linux) or
# pass a suite name through KAYA_WIN_SUITE (windows) and the lane runs
# just that, which turns a three-minute sample into a three-second one.
# Rare flakes are unreachable otherwise — six full runs of each of two
# lanes reproduced nothing at all (2026-08-02), because a leg failing 1
# in 20 needs about sixty whole-lane runs to show up three times.
#
# HALF A HUNT IS OFTEN ENOUGH, which is what the two flags are for. The
# serial pass is the expensive one — a lane that runs eight wide takes
# several times as long one at a time — and it only has to answer "does
# this leg ever fail ALONE". If that is already known for the leg under
# suspicion, --parallel skips it and spends the time on samples of the
# column that is actually in question.
#
# WHY THIS EXISTS. A flake makes every real failure cost a re-run before
# anyone will believe it, and the cost compounds: three separate times
# in two days a red lane had to be re-run to decide whether it was the
# change under test. It also corrodes the diagnostics — the stall
# watchdog fired inside commands_csharp under load, which is a true
# report of a starved thread and a false report of a blocked handler,
# and telling those apart is exactly what a noisy matrix makes
# impossible.
#
# THE ONE MEASUREMENT THAT DECIDES THE FIX is parallel versus serial.
# A leg that fails under the pool and never alone is CONTENTION: the
# runtime was starved past a deadline, and the answers are fewer jobs, a
# longer deadline, or a leg that tolerates it. A leg that fails ALONE
# TOO is a real race in the harness or the backend, and no amount of
# scheduling will help. Those are different bugs with different fixes,
# so the hunt runs both ways and prints both columns rather than leaving
# anyone to guess which kind they have.
#
# Not a gate and not wired into any lane: it is a measuring instrument,
# run by a human deciding what to fix.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

LANE="${1:-}"
RUNS="${2:-5}"
SERIAL_ONLY=0
PARALLEL_ONLY=0
for arg in "$@"; do
    [ "$arg" = "--serial" ] && SERIAL_ONLY=1
    [ "$arg" = "--parallel" ] && PARALLEL_ONLY=1
done

case "$LANE" in
    mac | linux | windows) ;;
    *)
        echo "usage: $0 <mac|linux|windows> [runs] [--serial]" >&2
        exit 2
        ;;
esac

OUT="$ROOT/target/flake-hunt"
mkdir -p "$OUT"
rm -f "$OUT/$LANE"-*.log

# The lane's own parallelism knob, and the value that means "one at a
# time". Every lane prints verdicts the same way — `name: PASS (Ns)` —
# so the parsing below is uniform even though the runners are not.
lane_cmd() { # jobs
    case "$LANE" in
        mac) KAYA_JOBS="$1" "$ROOT/tools/validate-mac.sh" ;;
        linux) KAYA_JOBS="$1" "$ROOT/tools/validate-linux.sh" ;;
        windows)
            KAYA_WIN_JOBS="$1" "$ROOT/tools/deploy-win.sh" \
                "${KAYA_WIN_HOST:-akhil@192.168.64.2}" "${KAYA_WIN_SUITE:-all}"
            ;;
    esac
}

# One pass: run the lane `RUNS` times at the given width, appending each
# failing leg name to a tally file. A run that dies early counts its
# absent legs as nothing — the interest is legs that BOTH pass and fail,
# and a lane that never got there says nothing either way.
hunt() { # jobs, label
    local jobs="$1" label="$2" i
    : >"$OUT/$LANE-$label.fails"
    for i in $(seq 1 "$RUNS"); do
        echo "== $LANE $label run $i/$RUNS (jobs=$jobs) =="
        lane_cmd "$jobs" >"$OUT/$LANE-$label-$i.log" 2>&1
        # python3 and not sed: repo policy, and the same reason —
        # BSD and GNU disagree and the breakage is silent.
        python3 -c '
import re, sys
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"^([A-Za-z0-9_-]+): FAIL", line)
    if m:
        print(m.group(1))
' "$OUT/$LANE-$label-$i.log" >>"$OUT/$LANE-$label.fails"
        local n
        n=$(grep -cE '^[a-zA-Z0-9_-]+: FAIL' "$OUT/$LANE-$label-$i.log")
        echo "   $n failing legs"
    done
}

if [ "$SERIAL_ONLY" = 0 ]; then
    hunt "${KAYA_FLAKE_JOBS:-8}" parallel
fi
if [ "$PARALLEL_ONLY" = 0 ]; then
    hunt 1 serial
else
    : >"$OUT/$LANE-serial.fails"
fi

echo
echo "=== $LANE, $RUNS runs each ==="
printf '%-34s %-10s %s\n' "leg" "parallel" "serial"
{
    [ -f "$OUT/$LANE-parallel.fails" ] && cat "$OUT/$LANE-parallel.fails"
    cat "$OUT/$LANE-serial.fails"
} | sort -u | while read -r leg; do
    [ -n "$leg" ] || continue
    p=$(grep -cxF "$leg" "$OUT/$LANE-parallel.fails" 2>/dev/null || echo 0)
    s=$(grep -cxF "$leg" "$OUT/$LANE-serial.fails" 2>/dev/null || echo 0)
    printf '%-34s %-10s %s\n' "$leg" "$p/$RUNS" "$s/$RUNS"
done

echo
echo "READING THIS: a leg failing in the parallel column and never in"
echo "the serial one is CONTENTION — fewer jobs, a longer deadline, or a"
echo "leg that tolerates being starved. A leg failing in BOTH is a real"
echo "race, and scheduling will not fix it. A leg at $RUNS/$RUNS in both"
echo "is not a flake at all; it is simply broken."
echo "Logs: $OUT/"
