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
# Recording mode's frame extraction: derive per-step stills from a
# leg's video using the harness transcript — the timeline is relative
# offsets ("KAYA_HARNESS: +<ms> <step>"), so the only anchor needed is
# the lead between recorder start and leg start, measured by the runner
# on its own clock. Frames are taken 300ms after an action step fires:
# actions are followed by settle windows, so that lands on the at-rest
# frame the step produced. Expect steps take no bias — an expect's
# still must show the moment of verification, and the very next action
# can share its transcript offset (the +300 once made an expect_order
# still show the following click's effect instead). Screenshots are thus derived data; the video keeps
# every in-between frame for transition forensics.
#
# Usage: harness-extract.sh <video> <transcript> <anchor_ms> <outdir> [crop]
#        harness-extract.sh --selftest
#
# [crop] is an optional ffmpeg crop filter ("crop=w:h:x:y") applied to
# every still — for suite-long recordings where each leg is a region
# of a shared canvas. Seeks stay cheap: no intermediate cropped video
# is ever rendered.
#
# anchor_ms is the wall-clock time (epoch ms) of the video's t=0. The
# transcript's own "KAYA_HARNESS: epoch <ms>" line supplies the
# harness's start, so the lead into the video is computed exactly — no
# launch-latency guessing.
#
# These videos are sparse VFR: recorders emit frames only when content
# changes, so "the frame at time T" is the LAST frame with pts <= T —
# the one still on screen — not the first frame after T, which is the
# NEXT repaint (ffmpeg's -ss semantics) and can be a whole scene later.
# The packet index below resolves each step to its covering frame's own
# pts, then seeks to exactly that frame. This also covers steps past
# the final repaint: their covering frame is simply the last one.
#
# Exit is nonzero when anything silently degrades: a transcript with
# steps but a video with no frames, an anchor that puts the leg outside
# the video, or fewer stills than steps. A scriptless transcript (no
# harness lines) extracts nothing and exits zero.
set -uo pipefail

# --selftest: synthesize a video of three known colors (red at pts
# 0-1s, green at 2-3, blue at 4-5 — 1fps, sparse like real captures)
# and a transcript whose steps must resolve to red (covering frame
# BEHIND the request time), green (mid), and blue (a step far past the
# last frame). Naive `-ss` extraction returns the next frame instead
# of the covering one and picks the wrong color — this is the
# regression pinned.
if [ "${1:-}" = --selftest ]; then
    T=$(mktemp -d)
    trap 'rm -rf "$T"' EXIT
    ffmpeg -loglevel error \
        -f lavfi -i "color=red:s=64x64:r=1:d=2" \
        -f lavfi -i "color=lime:s=64x64:r=1:d=2" \
        -f lavfi -i "color=blue:s=64x64:r=1:d=2" \
        -filter_complex "[0][1][2]concat=n=3" -y "$T/v.mp4" \
        || { echo "harness-extract selftest: could not synthesize video"; exit 1; }
    # The expect step sits at +1800ms: unbiased it covers the red
    # frame at pts 1; with the action bias (+300) it would cross into
    # green — the regression where an expect's still showed the next
    # step's effect.
    printf 'KAYA_HARNESS: epoch 1000\nKAYA_HARNESS: +0ms a\nKAYA_HARNESS: +1800ms expect q\nKAYA_HARNESS: +2900ms b\nKAYA_HARNESS: +20000ms c\n' \
        >"$T/leg.log"
    "$0" "$T/v.mp4" "$T/leg.log" 1000 "$T/steps" >/dev/null \
        || { echo "harness-extract selftest: extraction failed"; exit 1; }
    dominant() { # r|g|b of a png's average pixel
        ffmpeg -loglevel error -i "$1" -vf scale=1:1 -f rawvideo -pix_fmt rgb24 - 2>/dev/null \
            | od -An -tu1 | awk '{if ($1>=$2 && $1>=$3) print "r"; else if ($2>=$3) print "g"; else print "b"}'
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
FIRST_MS=$(awk 'NR==1{printf "%d", $1 * 1000}' "$PTS")
LAST_MS=$(awk 'END{printf "%d", $1 * 1000}' "$PTS")
LAST_OFF=$(grep -o 'KAYA_HARNESS: +[0-9]*ms' "$TRANSCRIPT" | grep -o '[0-9]*' | sort -n | tail -1)
# A suite-long film outlives each leg: after the guest exits, its
# region shows whatever the canvas does without it. No step may sample
# past the leg's own last transcript moment (minus a hair for the
# close race) — the final step follows a settle and is already at
# rest, so it loses nothing but the corpse.
END_MS=$((LEAD_MS + LAST_OFF - 50))
# Anchor plausibility: a leg cannot start after the video's last frame
# or end before its first. Either means the anchor (not the video) is
# wrong, and every still would be a lie.
if [ "$LEAD_MS" -gt $((LAST_MS + 5000)) ] \
    || [ $((LEAD_MS + LAST_OFF)) -lt $((FIRST_MS - 5000)) ]; then
    echo "harness-extract: anchor implausible (leg spans $LEAD_MS..$((LEAD_MS + LAST_OFF))ms, video $FIRST_MS..${LAST_MS}ms)"
    [ "$PTS" = "${KAYA_PTS_INDEX:-}" ] || rm -f "$PTS"
    exit 1
fi

n=0
grep -o 'KAYA_HARNESS: +[0-9]*ms .*' "$TRANSCRIPT" | while IFS= read -r line; do
    n=$((n + 1))
    offset=$(sed -n 's/KAYA_HARNESS: +\([0-9]*\)ms.*/\1/p' <<<"$line")
    step=$(sed -e 's/KAYA_HARNESS: +[0-9]*ms //' -e 's/[^A-Za-z0-9._#-]/_/g' <<<"$line" | cut -c1-48)
    case "$step" in
        [Ee]xpect*) bias=0 ;;
        *) bias=300 ;;
    esac
    at_ms=$((LEAD_MS + offset + bias))
    if [ "$at_ms" -gt "$END_MS" ]; then at_ms=$END_MS; fi
    if [ "$at_ms" -lt 0 ]; then at_ms=0; fi
    # Covering frame: last pts <= at; before the first frame, the
    # first frame (the earliest state the video knows).
    covering=$(awk -v t="$(awk "BEGIN{printf \"%.3f\", $at_ms/1000}")" \
        'NR==1{first=$1} $1+0 <= t+0 {last=$1} END{print (last=="" ? first : last)}' "$PTS")
    # Seek a hair early: -ss outputs the first frame at/after the
    # target, and float printing must not round past the frame.
    ffmpeg -loglevel error \
        -ss "$(awk "BEGIN{v=$covering-0.005; if (v<0) v=0; printf \"%.3f\", v}")" \
        -i "$VIDEO" -frames:v 1 ${CROP:+-vf "$CROP"} -y \
        "$OUT/$(printf 'step-%02d' "$n")-$step.png" 2>/dev/null || true
done
[ "$PTS" = "${KAYA_PTS_INDEX:-}" ] || rm -f "$PTS"

count=$(find "$OUT" -name 'step-*.png' | wc -l | tr -d ' ')
echo "harness-extract: $count/$WANT stills in $OUT"
[ "$count" = "$WANT" ] || exit 1
