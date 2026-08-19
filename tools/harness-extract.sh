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
# Recording mode's frame extraction: per-step stills from a leg's video,
# timed by the harness transcript's relative offsets.
#
# Usage: harness-extract.sh <video> <transcript> <anchor_ms> <outdir> [crop]
#        harness-extract.sh --selftest
#
# anchor_ms is the wall-clock time (epoch ms) of the video's t=0; the
# transcript's "KAYA_HARNESS: epoch <ms>" line supplies the harness's
# start, so the lead is computed rather than guessed from launch times.
# [crop] is an ffmpeg crop filter for suite-long films where each leg is
# a region of a shared canvas; no cropped video is ever rendered.
#
# Action steps are sampled 300ms late (they are followed by settle
# windows); EXPECT steps take no bias, or the still shows the next
# action's effect. These videos are sparse VFR, so a step resolves to
# its COVERING frame — the last pts <= t, not -ss's first frame after t
# (docs/traps.md, recording mode).
#
# Exit is nonzero when anything silently degrades: steps but no frames,
# an anchor outside the video, or fewer stills than steps. A scriptless
# transcript extracts nothing and exits zero.
set -uo pipefail

# --selftest: a synthesized three-color sparse video whose steps must
# resolve to red (covering frame BEHIND the request), green, and blue (a
# step past the last frame). Naive `-ss` picks the wrong color.
if [ "${1:-}" = --selftest ]; then
    T=$(mktemp -d)
    trap 'rm -rf "$T"' EXIT
    ffmpeg -nostdin -loglevel error \
        -f lavfi -i "color=red:s=64x64:r=1:d=2" \
        -f lavfi -i "color=lime:s=64x64:r=1:d=2" \
        -f lavfi -i "color=blue:s=64x64:r=1:d=2" \
        -filter_complex "[0][1][2]concat=n=3" -y "$T/v.mp4" \
        || { echo "harness-extract selftest: could not synthesize video"; exit 1; }
    # The expect step at +1800ms covers red unbiased; with the +300
    # action bias it would cross into green.
    printf 'KAYA_HARNESS: epoch 1000\nKAYA_HARNESS: +0ms a\nKAYA_HARNESS: +1800ms expect q\nKAYA_HARNESS: +2900ms b\nKAYA_HARNESS: +20000ms c\n' \
        >"$T/leg.log"
    "$0" "$T/v.mp4" "$T/leg.log" 1000 "$T/steps" >/dev/null \
        || { echo "harness-extract selftest: extraction failed"; exit 1; }
    dominant() { # r|g|b of a png's average pixel
        ffmpeg -nostdin -loglevel error -i "$1" -vf scale=1:1 -f rawvideo -pix_fmt rgb24 - 2>/dev/null \
            | od -An -tu1 | python3 -c '
import sys
r, g, b = (int(v) for v in sys.stdin.read().split()[:3])
print("r" if r >= g and r >= b else "g" if g >= b else "b")'
    }
    got="$(dominant "$T/steps/step-01-a.png")$(dominant "$T/steps/step-02-expect_q.png")$(dominant "$T/steps/step-03-b.png")$(dominant "$T/steps/step-04-c.png")"
    [ "$got" = rrgb ] || { echo "harness-extract selftest: covering frames wrong (got $got, want rrgb)"; exit 1; }
    # A transcript with steps but a video with no frames must fail.
    : >"$T/empty.mp4"
    if "$0" "$T/empty.mp4" "$T/leg.log" 1000 "$T/steps2" >/dev/null 2>&1; then
        echo "harness-extract selftest: frameless video did not fail"
        exit 1
    fi
    echo "harness-extract selftest: OK"
    exit 0
fi

VIDEO="$1"
TRANSCRIPT="$2"
ANCHOR_MS="$3"
OUT="$4"
CROP="${5:-}"

WANT=$(grep -c 'KAYA_HARNESS: +[0-9]*ms ' "$TRANSCRIPT" || true)
if [ "$WANT" = 0 ]; then
    echo "harness-extract: no harness steps in $TRANSCRIPT — nothing to extract"
    exit 0
fi
EPOCH=$(grep -m1 -o 'KAYA_HARNESS: epoch [0-9]*' "$TRANSCRIPT" | grep -o '[0-9]*$')
if [ -z "$EPOCH" ]; then
    echo "harness-extract: steps but no epoch line in $TRANSCRIPT"
    exit 1
fi
LEAD_MS=$((EPOCH - ANCHOR_MS))

mkdir -p "$OUT"
# A previous run of a scene whose script changed shape leaves orphans
# the overwrite never touches, and the count guard below then reads
# 13/10 stills as breakage. Start from a clean slate.
rm -f "$OUT"/step-*.png

# Legs sharing one suite film each rescan the same packets; a caller
# that pre-builds the index once (sorted pts_time, one per line) can
# share it via KAYA_PTS_INDEX.
PTS="$OUT/.pts"
if [ -n "${KAYA_PTS_INDEX:-}" ] && [ -s "${KAYA_PTS_INDEX:-}" ]; then
    PTS="$KAYA_PTS_INDEX"
else
    ffprobe -v quiet -select_streams v -show_entries packet=pts_time -of csv=p=0 \
        "$VIDEO" 2>/dev/null | sort -n >"$PTS"
fi
if [ ! -s "$PTS" ]; then
    echo "harness-extract: no frames in $VIDEO"
    [ "$PTS" = "${KAYA_PTS_INDEX:-}" ] || rm -f "$PTS"
    exit 1
fi
FIRST_MS=$(python3 -c '
import sys
v = open(sys.argv[1]).read().split()
print(int(float(v[0]) * 1000) if v else 0)' "$PTS")
LAST_MS=$(python3 -c '
import sys
v = open(sys.argv[1]).read().split()
print(int(float(v[-1]) * 1000) if v else 0)' "$PTS")
LAST_OFF=$(grep -o 'KAYA_HARNESS: +[0-9]*ms' "$TRANSCRIPT" | grep -o '[0-9]*' | sort -n | tail -1)
# A suite-long film outlives each leg, so no step may sample past the
# leg's own last transcript moment (minus a hair for the close race).
END_MS=$((LEAD_MS + LAST_OFF - 50))
# Anchor plausibility: a leg cannot start after the video's last frame
# or end before its first. Either means the ANCHOR is wrong, and every
# still would be a lie.
if [ "$LEAD_MS" -gt $((LAST_MS + 5000)) ] \
    || [ $((LEAD_MS + LAST_OFF)) -lt $((FIRST_MS - 5000)) ]; then
    echo "harness-extract: anchor implausible (leg spans $LEAD_MS..$((LEAD_MS + LAST_OFF))ms, video $FIRST_MS..${LAST_MS}ms)"
    [ "$PTS" = "${KAYA_PTS_INDEX:-}" ] || rm -f "$PTS"
    exit 1
fi

# The transcript arrives on fd 3, NOT stdin: -nostdin fixes ffmpeg
# specifically, the fd makes the loop immune to the next stdin-reading
# command someone adds (docs/traps.md, "ffmpeg in a `while read` loop").
n=0
while IFS= read -r line <&3; do
    n=$((n + 1))
    read -r offset step <<<"$(KAYA_LINE="$line" python3 -c '
import os, re
# "KAYA_HARNESS: +<ms> <step text>" -> the offset and a filename-safe
# step name, on one line for a single read.
line = os.environ["KAYA_LINE"]
m = re.search(r"KAYA_HARNESS: \+([0-9]+)ms ?(.*)", line)
off, rest = (m.group(1), m.group(2)) if m else ("0", "")
print(off, re.sub(r"[^A-Za-z0-9._#-]", "_", rest)[:48])')"
    case "$step" in
        [Ee]xpect*) bias=0 ;;
        *) bias=300 ;;
    esac
    at_ms=$((LEAD_MS + offset + bias))
    if [ "$at_ms" -gt "$END_MS" ]; then at_ms=$END_MS; fi
    if [ "$at_ms" -lt 0 ]; then at_ms=0; fi
    covering=$(KAYA_AT_MS="$at_ms" python3 -c '
import os, sys
# The covering frame: the last pts at or before the target; before the
# first frame, the first (the earliest state the video knows).
t = int(os.environ["KAYA_AT_MS"]) / 1000
pts = [float(v) for v in open(sys.argv[1]).read().split()]
earlier = [p for p in pts if p <= t]
print("%.3f" % (earlier[-1] if earlier else (pts[0] if pts else 0.0)))' "$PTS")
    # Seek a hair early: -ss outputs the first frame at/after the
    # target, and float printing must not round past the frame.
    ffmpeg -nostdin -loglevel error \
        -ss "$(python3 -c '
import sys
print("%.3f" % max(0.0, float(sys.argv[1]) - 0.005))' "$covering")" \
        -i "$VIDEO" -frames:v 1 ${CROP:+-vf "$CROP"} -y \
        "$OUT/$(printf 'step-%02d' "$n")-$step.png" 2>/dev/null || true
done 3< <(grep -o 'KAYA_HARNESS: +[0-9]*ms .*' "$TRANSCRIPT")
[ "$PTS" = "${KAYA_PTS_INDEX:-}" ] || rm -f "$PTS"

count=$(find "$OUT" -name 'step-*.png' | wc -l | tr -d ' ')
echo "harness-extract: $count/$WANT stills in $OUT"
[ "$count" = "$WANT" ] || exit 1
