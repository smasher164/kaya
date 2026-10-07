#!/usr/bin/env bash
# A media leg's OWN desktop, then the guest (docs/media-plan.md §2, §5):
#
#     tools/linux/media-leg.sh tools/linux/a11y-leg.sh <guest> [args...]
#
# A session bus of the leg's own (MPRIS lives there, and the harness's
# session_send and expect_now_playing read it from outside the process) with
# tools/linux/sessionmgr.py owning org.gnome.SessionManager, and on x11 the
# portal's Inhibit, BEFORE the guest starts, since GtkApplication looks for
# them once at startup and x11's idle inhibitor goes nowhere else. The command is the rest of the line, spelled
# `tools/linux/a11y-leg.sh <guest>` by every media leg: a11y-leg.sh keeps
# this bus (it launches its own only when none is exported).
set -uo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <guest> [args...]" >&2
    exit 2
fi

kaya_media_dir="$(mktemp -d)"
kaya_bus_dirs="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
kaya_sm_args=()
kaya_sm_names=(org.gnome.SessionManager)
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    python3 tools/linux/sessionmgr.py --write-service "$kaya_media_dir/portal" || exit 1
    kaya_bus_dirs="$kaya_media_dir/portal:$kaya_bus_dirs"
    kaya_sm_args=(--portal-inhibit)
    kaya_sm_names+=(org.freedesktop.portal.Desktop)
fi
eval "$(XDG_DATA_DIRS="$kaya_bus_dirs" dbus-launch --sh-syntax)"
kaya_bus_pid="${DBUS_SESSION_BUS_PID:-}"
python3 tools/linux/sessionmgr.py "${kaya_sm_args[@]}" 2>"$kaya_media_dir/sessionmgr.log" &
kaya_sm=$!
for kaya_name in "${kaya_sm_names[@]}"; do
    tries=0
    until dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
        "string:$kaya_name" 2>/dev/null | grep -q 'boolean true'; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then
            echo "media-leg: sessionmgr.py never owned $kaya_name:" >&2
            cat "$kaya_media_dir/sessionmgr.log" >&2
            break
        fi
        sleep 0.05
    done
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
