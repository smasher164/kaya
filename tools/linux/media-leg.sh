#!/usr/bin/env bash
# A media leg's OWN desktop, then the guest (docs/media-plan.md §2, §5):
#
#     tools/linux/media-leg.sh tools/linux/a11y-leg.sh <guest> [args...]
#
# A session bus of the leg's own (MPRIS lives there, and the harness's
# session_send and expect_now_playing read it from outside the process) with
# tools/linux/sessionmgr.py owning org.gnome.SessionManager BEFORE the guest
# starts, since GtkApplication looks for it once at startup and x11's idle
# inhibitor goes nowhere else. The command is the rest of the line, spelled
# `tools/linux/a11y-leg.sh <guest>` by every media leg: a11y-leg.sh keeps
# this bus (it launches its own only when none is exported).
set -uo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <guest> [args...]" >&2
    exit 2
fi

kaya_media_dir="$(mktemp -d)"
eval "$(dbus-launch --sh-syntax)"
kaya_bus_pid="${DBUS_SESSION_BUS_PID:-}"
python3 tools/linux/sessionmgr.py 2>"$kaya_media_dir/sessionmgr.log" &
kaya_sm=$!
tries=0
until dbus-send --session --print-reply --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
    string:org.gnome.SessionManager 2>/dev/null | grep -q 'boolean true'; do
    tries=$((tries + 1))
    if [ "$tries" -gt 60 ]; then
        echo "media-leg: sessionmgr.py never owned org.gnome.SessionManager:" >&2
        cat "$kaya_media_dir/sessionmgr.log" >&2
        break
    fi
    sleep 0.05
done

"$@"
status=$?

kill "$kaya_sm" 2>/dev/null
wait "$kaya_sm" 2>/dev/null
cat "$kaya_media_dir/sessionmgr.log" >&2
if [ -n "$kaya_bus_pid" ]; then
    kill "$kaya_bus_pid" 2>/dev/null
fi
rm -rf "$kaya_media_dir"
exit "$status"
