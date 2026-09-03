#!/usr/bin/env bash
# The accessibility leg's OWN session, then the guest.
#
# GTK publishes an accessibility tree only under GTK_A11Y=atspi, which
# needs a session bus. Both are PER-LEG: exported lane-wide they timed
# out eleven legs at 180s that never asked for accessibility (measured
# 2026-07-25 — python/go/csharp/ocaml died, rust and c survived;
# docs/HACKING.md).
set -uo pipefail

# A PRIVATE RUNTIME DIR, because at-spi-bus-launcher derives its socket
# from it ($XDG_RUNTIME_DIR/at-spi/bus): concurrent legs sharing one dir
# fight over one socket and an app registers on a bus its reader is not
# watching. Measured 2026-07-25: every X11 leg passed and every WAYLAND
# leg failed with an empty tree, because under X the bus address is
# discovered per display. The compositor socket is symlinked back in,
# since a Wayland client finds it through this same variable.
kaya_run_dir="$(mktemp -d)"
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    ln -sf "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$kaya_run_dir/$WAYLAND_DISPLAY"
    ln -sf "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY.lock" \
        "$kaya_run_dir/$WAYLAND_DISPLAY.lock" 2>/dev/null || true
fi
export XDG_RUNTIME_DIR="$kaya_run_dir"

eval "$(dbus-launch --sh-syntax)"
export GTK_A11Y=atspi
/usr/libexec/at-spi-bus-launcher --launch-immediately &
launcher=$!
# The launcher must own org.a11y.Bus on the session bus before the
# guest's first read races its name acquisition — POLLED for that
# exact fact, not slept: the fixed second this replaced was 134 legs
# of pure wait per lane (2026-08-20), and the name lands in ~0.1s.
# The cap keeps the old second's spirit; a leg that proceeds anyway
# fails on its own reads, loudly.
tries=0
until dbus-send --print-reply --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
    string:org.a11y.Bus 2>/dev/null | grep -q 'boolean true'; do
    tries=$((tries + 1))
    if [ "$tries" -gt 40 ]; then
        break
    fi
    sleep 0.05
done

"$@"
status=$?

kill "$launcher" 2>/dev/null
[ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
rm -rf "$kaya_run_dir"
exit "$status"
