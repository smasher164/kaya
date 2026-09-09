#!/usr/bin/env bash
# The notification leg's OWN desktop, then the guest (docs/tasks-s3-plan.md
# §0, §5, §7).
#
#     tools/linux/notify-leg.sh portal|gnome <guest> [args...]
#
# A Linux notification is one D-Bus call to whoever owns
# org.freedesktop.Notifications, and the container has no desktop at all —
# no daemon to draw it, no portal to remember it, no session manager to fire
# a timer. This assembles the one the regime under test needs:
#
#   portal  the ruled floor's first route: xdg-desktop-portal (+ its gtk
#           backend) keeps the record and calls the app back, and
#           tools/linux/notifyd.py plays the freedesktop DAEMON under it —
#           mako, dunst and Plasma all speak that one protocol.
#   gnome   the floor's second route: notifyd plays GNOME Shell's own
#           org.gtk.Notifications, on a bus where the portal is not even
#           activatable, so kaya's decision takes its other arm.
#
# Beside both: the two ACTIVATION FILES a click after an exit needs (a
# desktop entry marked DBusActivatable and a D-Bus service naming the id),
# and tools/linux/schedrec.py on PATH as systemd-run and systemctl, so a
# scheduled post records the transient timer the arm asked for.
#
# Everything is PER LEG, for a11y-leg.sh's measured reason: a session bus
# shared between concurrent legs is one app registering where another leg's
# reader is watching.
set -uo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 portal|gnome <guest> [args...]" >&2
    exit 2
fi
kaya_regime="$1"
shift

case "$kaya_regime" in
    portal) kaya_names=fdo ;;
    gnome) kaya_names=gtk ;;
    *)
        echo "notify-leg: $kaya_regime is not a regime; use portal or gnome" >&2
        exit 2
        ;;
esac

kaya_home="$(mktemp -d)"
export XDG_DATA_HOME="$kaya_home/share"
export XDG_CONFIG_HOME="$kaya_home/config"
export XDG_CACHE_HOME="$kaya_home/cache"
# AND THE STATE HOME, for the same per-leg reason: the second act's marker
# and verdict live at `<state>/kaya/act2/<app id>` (crates/kaya/src/act2.rs),
# one path per APP — so the x11 and wayland tasks legs, which pool
# concurrently, would write and poll the same two files.
export XDG_STATE_HOME="$kaya_home/state"
# Where the relaunched process's own output goes; see act2-exec.sh.
export KAYA_ACT2_LOG="$kaya_home/act2.log"
mkdir -p "$XDG_DATA_HOME/dbus-1/services" "$XDG_DATA_HOME/applications" \
    "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$kaya_home/bin"

# A PRIVATE RUNTIME DIR, a11y-leg.sh's rule and its reason: the session's
# sockets are derived from it, and concurrent legs sharing one dir fight
# over one socket. The compositor socket is symlinked back, since a Wayland
# client finds it through this same variable.
kaya_run_dir="$kaya_home/run"
mkdir -p "$kaya_run_dir" && chmod 700 "$kaya_run_dir"
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    ln -sf "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$kaya_run_dir/$WAYLAND_DISPLAY"
    ln -sf "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY.lock" \
        "$kaya_run_dir/$WAYLAND_DISPLAY.lock" 2>/dev/null || true
fi
export XDG_RUNTIME_DIR="$kaya_run_dir"

# THE ACTIVATION FILES ARE THE GENERATOR'S (docs/packaging-plan.md P5),
# so this leg runs what an installed app has: tools/linux/install-desktop.py
# stages `<id>.desktop`, the D-Bus service file naming the same id, and the
# mark in the hicolor theme into this leg's own XDG_DATA_HOME, and prints
# the declared app id — read, never spelled (docs/tasks-s3-plan.md N4), so
# the activation files cannot name a different app from the one that posts.
#
# AND THE Exec LINE IS THE LEG'S OWN LAUNCHER (docs/tasks-s9-plan.md R6),
# behind tools/linux/act2-exec.sh, which keeps the relaunched process's
# output: the environment a D-Bus-activated act two runs with is this
# leg's, so KAYA_LIB and the asset root are where act one found them.
kaya_app_id="$(python3 /work/tools/linux/install-desktop.py \
    "$XDG_DATA_HOME" /work/tools/linux/act2-exec.sh "$@")"
kaya_id_rc=$?
if [ "$kaya_id_rc" -ne 0 ] || [ -z "$kaya_app_id" ]; then
    echo "notify-leg: the app's desktop entry could not be installed, so" \
        "this leg has no activation route and no name to post under." >&2
    rm -rf "$kaya_home"
    exit 1
fi

# AND THE ENTRY IS ASSERTED THROUGH THE SAME READER THE PORTAL USES: an
# entry GLib will not load leaves the guest with no route at all, which
# reads as an app that "cannot post" and names no cause.
kaya_appinfo="$(KAYA_APP_ID="$kaya_app_id" python3 -c 'import os
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio
name = os.environ["KAYA_APP_ID"] + ".desktop"
info = Gio.DesktopAppInfo.new(name)
line = info.get_commandline() if info is not None else ""
# THE PORTAL RESOLVES THE PROGRAM, not just the file: an entry GLib loads
# happily can still be refused with "App info not found" when its Exec is
# relative (measured 2026-09-08).
# AND THE ARGUMENTS ARE RESOLVED BY WHOEVER STARTS THE APP, which for the
# second act is the bus daemon from `/` (docs/tasks-s9-plan.md R6).
loose = [w for w in line.split() if "/" in w and not w.startswith("/")]
if not line.startswith("/"):
    print("missing")
elif loose:
    print("relative " + " ".join(loose))
else:
    print("found")')"
if [ "$kaya_appinfo" != found ]; then
    echo "notify-leg: $kaya_app_id.desktop cannot be started from anywhere" \
        "but this leg's own directory ($kaya_appinfo), so the portal" \
        "refuses this app's Register, or a click after an exit starts a" \
        "process whose first act is a file-not-found. The Exec line's" \
        "program AND its arguments have to be absolute paths." >&2
    cat "$XDG_DATA_HOME/applications/$kaya_app_id.desktop" >&2
    rm -rf "$kaya_home"
    exit 1
fi

# THE RECORDING SCHEDULER, ahead of the real ones on PATH: the container
# runs no systemd user manager, so what a scheduled post asked for would
# otherwise be invisible (tools/linux/schedrec.py).
ln -sf /work/tools/linux/schedrec.py "$kaya_home/bin/systemd-run"
ln -sf /work/tools/linux/schedrec.py "$kaya_home/bin/systemctl"
export PATH="$kaya_home/bin:$PATH"
export KAYA_NOTIFY_SCHED_LOG="$kaya_home/sched.log"
export KAYA_NOTIFY_SCHED_UNITS="$kaya_home/units"
: >"$KAYA_NOTIFY_SCHED_LOG"

# THE SESSION BUS, AND WHO CAN BE ACTIVATED ON IT. The image keeps the
# portal's two D-Bus service files OUT of the default search path (see
# tools/linux/Dockerfile: a portal any leg could activate takes over GTK's
# file chooser and cost 24 legs the day it was measured), so the portal
# regime is the one that puts them back — for THIS bus only, through the
# XDG_DATA_DIRS the daemon reads at startup. The gnome regime does not, so
# its bus genuinely has no portal rather than a flag saying so; the
# assertions below hold both directions.
kaya_dirs="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
if [ "$kaya_regime" = portal ]; then
    kaya_dirs="/opt/kaya-portal:$kaya_dirs"
fi
# KAYA_SELFTEST IS STRIPPED FROM THE ACTIVATION ENVIRONMENT (S9 R6): an
# activated service inherits the bus daemon's environ, so act two would
# otherwise start with act one's scene name set and run the whole scene
# from the top instead of adopting the marker (crates/kaya/src/act2.rs
# takes its act-two branch only when KAYA_SELFTEST is unset).
kaya_launch="$(XDG_DATA_DIRS="$kaya_dirs" env -u KAYA_SELFTEST \
    dbus-launch --sh-syntax)"
eval "$kaya_launch"

KAYA_NOTIFYD_NAMES="$kaya_names" python3 /work/tools/linux/notifyd.py \
    >"$kaya_home/notifyd.log" 2>&1 &
kaya_notifyd=$!
kaya_waited=0
until grep -q "notifyd: ready" "$kaya_home/notifyd.log" 2>/dev/null; do
    kaya_waited=$((kaya_waited + 1))
    if [ "$kaya_waited" -gt 100 ]; then
        echo "notify-leg: the recording daemon never owned its names; a guest" \
            "would post into nothing and the leg would read an empty list" \
            "with no cause on the record." >&2
        cat "$kaya_home/notifyd.log" >&2
        kill "$kaya_notifyd" 2>/dev/null
        [ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
        rm -rf "$kaya_home"
        exit 1
    fi
    sleep 0.05
done

# THE REGIME IS ASSERTED, NOT ASSUMED: a portal leg that quietly ran the
# GNOME route (or the other way about) would measure the wrong half of the
# floor and still be green.
kaya_portal_version="$(timeout 30 gdbus call --session \
    --dest org.freedesktop.portal.Desktop \
    --object-path /org/freedesktop/portal/desktop \
    --method org.freedesktop.DBus.Properties.Get \
    org.freedesktop.portal.Notification version 2>&1)"
kaya_portal_rc=$?
if [ "$kaya_regime" = portal ] && [ "$kaya_portal_rc" -ne 0 ]; then
    echo "notify-leg: no portal answers org.freedesktop.portal.Notification on" \
        "this leg's bus, so the route under test is not here:" \
        "$kaya_portal_version" >&2
    kill "$kaya_notifyd" 2>/dev/null
    [ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
    rm -rf "$kaya_home"
    exit 1
fi
if [ "$kaya_regime" = gnome ] && [ "$kaya_portal_rc" -eq 0 ]; then
    echo "notify-leg: a portal answered on the GNOME leg's bus, which would" \
        "take kaya's portal arm and leave org.gtk.Notifications unmeasured." >&2
    kill "$kaya_notifyd" 2>/dev/null
    [ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
    rm -rf "$kaya_home"
    exit 1
fi
echo "notify-leg: regime $kaya_regime, app id $kaya_app_id, portal version" \
    "${kaya_portal_version//$'\n'/ }"

"$@"
kaya_status=$?

# THE SECOND ACT (docs/tasks-s9-plan.md R6): act one exited at its
# `relaunch` line leaving a marker, and the click that follows goes through
# the platform's own door — the daemon's ActionInvoked, which the portal
# turns into ActivateAction on this app's bus name and D-Bus activation
# starts. One leg, both verdicts.
if [ -f "$XDG_STATE_HOME/kaya/act2/$kaya_app_id/marker" ]; then
    if [ "$kaya_status" -ne 0 ]; then
        echo "notify-leg: act one exited $kaya_status, so its second act is" \
            "not driven — a door pushed after a failed first act would" \
            "measure nothing." >&2
    else
        # 90s, inside run_one's `timeout 180` with act one's own run: a
        # green act two answers in under a second, and a red one publishes
        # its verdict at the harness's step ceilings — which is the answer
        # worth waiting for, since a poll that gives up first reports a
        # missing file where the scene had a sentence.
        python3 /work/tools/linux/act2.py "$kaya_app_id" "$XDG_STATE_HOME" 90
        kaya_status=$?
    fi
    echo "--- act two ---" >&2
    if [ -f "$KAYA_ACT2_LOG" ]; then
        cat "$KAYA_ACT2_LOG" >&2
    else
        echo "notify-leg: no act-two log at all, so nothing was started" >&2
    fi
fi

# THE DAEMON'S RECORD RIDES THE LEG LOG: every Notify, every click and every
# withdrawal it saw, which is where a red leg's transport is read.
echo "--- notifyd ---" >&2
cat "$kaya_home/notifyd.log" >&2
if [ -s "$KAYA_NOTIFY_SCHED_LOG" ]; then
    echo "--- session scheduler ---" >&2
    cat "$KAYA_NOTIFY_SCHED_LOG" >&2
fi

kill "$kaya_notifyd" 2>/dev/null
[ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
rm -rf "$kaya_home"
exit "$kaya_status"
