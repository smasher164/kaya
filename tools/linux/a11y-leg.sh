#!/usr/bin/env bash
# The accessibility leg's OWN session, then the guest.
#
# GTK publishes an accessibility tree only when GTK_A11Y=atspi, which
# needs a session bus for the a11y bus launcher to sit on. Both are
# per-leg on purpose: exported lane-wide they changed the GTK backend
# for EVERY leg and timed out eleven of them at 180s (measured
# 2026-07-25 — python/go/csharp/ocaml died, rust and c survived). One
# scene's requirement must not alter the environment of three hundred
# legs that never asked for it.
#
# Runs INSIDE the runner's xvfb-run wrapper, like any other leg command.
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
# The registry must be up before the guest asks for it; the guest's own
# first read would otherwise race the launcher's name acquisition.
sleep 1

"$@"
status=$?

kill "$launcher" 2>/dev/null
[ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
rm -rf "$kaya_run_dir"
exit "$status"
