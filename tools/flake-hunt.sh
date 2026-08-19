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
# Run one lane N times and report WHICH LEGS EVER FAIL, and how often.
# A measuring instrument, not a gate. What it is good and bad for is in
# docs/traps.md (whole-lane repetition is too coarse for a low per-leg
# rate; a single-leg hammer removes the contention that triggers it).
#
# Usage: tools/flake-hunt.sh <lane> [runs] [--serial|--parallel]
#        lane: mac | linux | windows
#        runs: default 5
#
# Narrow the sample with KAYA_ONLY (linux) or KAYA_WIN_SUITE (windows).
# The serial pass is the expensive one and only answers "does this leg
# ever fail ALONE"; --parallel skips it when that is already known.
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

# Every lane prints verdicts the same way — `name: PASS (Ns)` — so the
# parsing below is uniform even though the runners are not.
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
# failing leg name to a tally file.
hunt() { # jobs, label
    local jobs="$1" label="$2" i
    : >"$OUT/$LANE-$label.fails"
    for i in $(seq 1 "$RUNS"); do
        echo "== $LANE $label run $i/$RUNS (jobs=$jobs) =="
        lane_cmd "$jobs" >"$OUT/$LANE-$label-$i.log" 2>&1
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
