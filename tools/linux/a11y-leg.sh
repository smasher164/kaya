#!/usr/bin/env bash
# The accessibility leg's OWN session, then the guest.
#
# GTK publishes an accessibility tree only when GTK_A11Y=atspi, which
# needs a session bus for the a11y bus launcher to sit on. Both are
# PER-LEG: exported lane-wide they timed out eleven legs at 180s that
# never asked for accessibility (measured 2026-07-25 —
# python/go/csharp/ocaml died, rust and c survived; docs/HACKING.md).
#
# Runs on the runner's claimed pool display (xvfb-run under
# KAYA_RECORD), like any other leg command.
set -uo pipefail

# A PRIVATE RUNTIME DIR, because the accessibility bus's socket path is
# derived from it: at-spi-bus-launcher puts its socket at
# $XDG_RUNTIME_DIR/at-spi/bus, so concurrent legs sharing one runtime
# dir fight over one socket and an app can end up registered on a bus
# its reader is not watching. Measured 2026-07-25: every X11 leg passed
# and every WAYLAND leg failed with an empty tree — X11 hid the clash
# because xvfb-run gives each leg its own display, and under X the bus
# address is discovered per display.
#
# The compositor socket is symlinked back in, since a Wayland client
# finds it through this same variable.
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
