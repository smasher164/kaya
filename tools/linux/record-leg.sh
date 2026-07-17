#!/usr/bin/env bash
# One recorded Linux leg, run INSIDE xvfb-run (DISPLAY is this leg's
# private Xvfb): film the whole display with x11grab while the guest
# runs, then derive per-step stills. One window per private display
# means the film IS the leg — no crops, no tiling, no fiducials.
#
#   record-leg.sh <proto> <dir> <cmd...>
#
# For wayland, a nested Weston (X11 backend) runs inside this same
# Xvfb: the compositor's output is an X11 window, so one x11grab films
# wayland rendering too — and each recorded wayland leg gets its own
# compositor instead of sharing one.
#
# Anchor: the container clock stamps both the harness epoch (in the
# transcript) and the recorder stop; ffmpeg finalizes on SIGINT, so
# video-end == stop time and anchor = stop − duration (the same scheme
# the Android runner uses).
set -uo pipefail

proto="$1"
dir="$2"
shift 2
mkdir -p "$dir"

if [ "$proto" = wayland ]; then
    export XDG_RUNTIME_DIR="/tmp/xdg-leg-$$"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    weston --backend=x11 --socket="kaya-w-$$" &>"$dir/weston.log" &
    weston_pid=$!
    ok=0
    for _ in $(seq 1 100); do
        if [ -e "$XDG_RUNTIME_DIR/kaya-w-$$" ]; then
            ok=1
            break
        fi
        sleep 0.1
    done
    if [ "$ok" != 1 ]; then
        echo "record-leg: nested weston never came up"
        cat "$dir/weston.log"
        exit 1
    fi
    export WAYLAND_DISPLAY="kaya-w-$$"
fi

ffmpeg -loglevel error -f x11grab -framerate 15 -video_size 1024x768 \
    -i "$DISPLAY" -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    "$dir/video.mkv" &>"$dir/rec.log" &
rec_pid=$!

"$@" >"$dir/leg.log" 2>&1
rc=$?
t_kill=$(date +%s%3N)
kill -INT "$rec_pid" 2>/dev/null
wait "$rec_pid" 2>/dev/null

if [ "$proto" = wayland ]; then
    kill "$weston_pid" 2>/dev/null
fi

# The pooled caller shows this log on failure; the transcript and
# verdict must flow through.
cat "$dir/leg.log"

dur_ms=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 \
    "$dir/video.mkv" 2>/dev/null | awk '{printf "%d", $1 * 1000}')
if [ -z "$dur_ms" ]; then
    echo "record-leg: recording produced no readable video ($(cat "$dir/rec.log"))"
    exit 1
fi
/work/tools/harness-extract.sh "$dir/video.mkv" "$dir/leg.log" \
    "$((t_kill - dur_ms))" "$dir/steps" || exit 1

exit "$rc"
