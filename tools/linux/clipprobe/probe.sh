#!/usr/bin/env bash
# ClipProbe — can the harness read the system clipboard from OUTSIDE
# the guest, on both display protocols the linux lane runs?
#
# THE QUESTION THAT DECIDES THE LINUX ARM. Every other backend's
# clipboard read is out of process (pbpaste, Get-Clipboard, simctl
# pbpaste), which is the standard the file-dialog work set: read the
# REAL system state, not kaya's record of it. On X11 that is xclip. On
# Wayland it is wl-paste, which normally relies on the wlr-data-control
# protocol — AND THIS LANE RUNS WESTON, which does not implement it.
# Whether an out-of-process read works here at all is unknown, and it
# decides whether the wayland leg can hold the same standard as the
# rest.
#
# Q1 Do the tools exist / install in the lane's image?
# Q2 X11: does xclip round-trip a selection owned by another process?
# Q3 Wayland under Weston: does wl-copy/wl-paste round-trip at all?
# Q4 Does either need the reader to hold focus? (Both readers run with
#    no surface of their own, which is the harness's situation.)
#
# Throwaway; nothing builds or runs this but a human. Answers land on
# stdout under "PROBE".
set -uo pipefail
say() { echo "PROBE $*"; }

say "==== begin"
if ! command -v xclip >/dev/null || ! command -v wl-copy >/dev/null; then
    say "Q1 installing xclip + wl-clipboard"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq xclip wl-clipboard >/dev/null 2>&1
fi
say "Q1 xclip=$(command -v xclip || echo MISSING) wl-copy=$(command -v wl-copy || echo MISSING)"

# --- X11 ---------------------------------------------------------
Xvfb :99 -screen 0 1280x800x24 &>/tmp/xvfb.log &
sleep 1
export DISPLAY=:99
# xclip -i FORKS and holds the selection, which is the X11 model: the
# owner serves every paste. That is also why this is a real test of
# out-of-process reading — the reader talks to a different process.
printf 'kaya-x11-payload' | xclip -selection clipboard -i
sleep 1
got_x11="$(xclip -selection clipboard -o 2>/tmp/xclip-err.txt)"
say "Q2 x11 read back: '${got_x11}' (wanted 'kaya-x11-payload')"
[ -s /tmp/xclip-err.txt ] && say "Q2 x11 stderr: $(head -2 /tmp/xclip-err.txt)"
say "Q2 x11 TARGETS: $(xclip -selection clipboard -t TARGETS -o 2>/dev/null | tr '\n' ' ')"

# --- Wayland, headless Weston ------------------------------------
# The lane sets this before starting Weston; without it the compositor
# has nowhere to put its socket and every client fails to connect.
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
weston --backend=headless --socket=kaya-clipprobe &>/tmp/weston-probe.log &
sleep 3
export WAYLAND_DISPLAY=kaya-clipprobe
unset DISPLAY
if wl-copy 'kaya-wayland-payload' 2>/tmp/wlcopy-err.txt; then
    say "Q3 wl-copy returned 0"
else
    say "Q3 wl-copy FAILED: $(head -3 /tmp/wlcopy-err.txt)"
fi
sleep 1
got_way="$(timeout 10 wl-paste --no-newline 2>/tmp/wlpaste-err.txt)"
say "Q3 wayland read back: '${got_way}' (wanted 'kaya-wayland-payload')"
[ -s /tmp/wlpaste-err.txt ] && say "Q3 wayland stderr: $(head -3 /tmp/wlpaste-err.txt)"
say "Q3 wayland types: $(timeout 10 wl-paste --list-types 2>&1 | tr '\n' ' ')"

# Q4: the reader holds no surface and therefore no keyboard focus in
# either case above. If the reads worked, focus was not required of the
# READER. Whether a WRITER needs it is the other half, and wl-copy is
# the writer here.
say "Q4 both readers ran with no surface of their own; see Q2/Q3"
say "==== end"
