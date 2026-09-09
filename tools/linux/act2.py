#!/usr/bin/env python3
"""The second act, driven through the platform's own door (S9 R6).

    tools/linux/act2.py <app-id> <state-home> [ceiling-seconds]

Runs INSIDE the linux container, from tools/linux/notify-leg.sh and on
that leg's session bus, so it carries no dev-shell guard: the container
is not the nix shell (notifyd.py's and install-desktop.py's rule).

Act one has exited, leaving `<state-home>/kaya/act2/<app-id>/marker`.
This pushes the door from outside — `Invoke` on the lane's recording
daemon, which is what a tap on a mako box does — and the desktop takes
it from there: the daemon's `ActionInvoked` reaches
xdg-desktop-portal-gtk, which reads the notification's `app.`-prefixed
default action and calls `org.freedesktop.Application.ActivateAction` on
the app's bus name, which D-Bus activation starts through the service
file the desktop entry's arm installed. Then it polls the act-two
verdict the relaunched process writes beside the marker and joins it.

THE DOOR IS THE PLATFORM'S, NOT OURS: nothing here starts a process.
"""

import pathlib
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: I001,E402

REC_NAME = "dev.kaya.NotificationRecorder"
REC_PATH = "/dev/kaya/NotificationRecorder"
MARKER = "marker"
VERDICT = "act2.verdict"


def say(message):
    print(f"act2: {message}", flush=True)


def recorder(connection, method, args):
    return connection.call_sync(
        REC_NAME, REC_PATH, REC_NAME, method, args, None,
        Gio.DBusCallFlags.NONE, 10000, None)


def held(connection):
    """The daemon's list: route, the desktop's id, the app, the summary."""
    reply = recorder(connection, "List", None)
    return [(row[0], row[1], row[2], row[3])
            for row in reply.unpack()[0]]


def main(argv):
    if len(argv) < 2:
        raise SystemExit("usage: act2.py <app-id> <state-home> [ceiling]")
    app_id, state_home = argv[0], argv[1]
    ceiling = float(argv[2]) if len(argv) > 2 else 60.0
    directory = pathlib.Path(state_home) / "kaya/act2" / app_id
    marker = directory / MARKER
    verdict = directory / VERDICT

    if not marker.is_file():
        beside = (sorted(p.name for p in directory.glob("*"))
                  if directory.is_dir() else "the directory itself is absent")
        say(f"FAILED — act one left no {marker}, so it never reached its "
            f"`relaunch` line and there is no second act to drive. What "
            f"{directory} holds: {beside}")
        return 1
    # A verdict from an earlier run would answer this one's poll before the
    # relaunched process had written a byte.
    if verdict.exists():
        verdict.unlink()

    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    rows = held(connection)
    if len(rows) != 1:
        say(f"FAILED — the desktop holds {len(rows)} notifications and the "
            f"click has to name one: {rows}. Act one is meant to leave "
            f"exactly the reminder its second act opens.")
        return 1
    route, ident, app, summary = rows[0]
    # THE JOIN KEY IS THE DAEMON'S, and it differs by route for the reason
    # the harness's own read differs (crates/kaya/src/gtk.rs's
    # notification_title): the freedesktop hop under the portal drops the
    # client's id and keeps the text.
    key = ident if route == "gtk" else summary
    say(f"the desktop holds {route}:{ident} {summary!r} for {app!r}; "
        f"clicking it by {key!r}")
    started = time.monotonic()
    answer = recorder(
        connection, "Invoke",
        GLib.Variant("(ss)", (key, ""))).unpack()[0]
    say(f"the daemon answered: {answer}")

    while time.monotonic() - started < ceiling:
        if verdict.is_file():
            line = verdict.read_text(encoding="utf-8").strip()
            say(f"act two answered after "
                f"{time.monotonic() - started:.1f}s: {line}")
            if line.startswith("KAYA_SELFTEST: OK"):
                return 0
            say("FAILED — act two ran and did not pass; its own output is "
                "in the act-two log below.")
            return 1
        time.sleep(0.1)

    say(f"FAILED — no {verdict} within {ceiling:.0f}s. The click was "
        f"delivered ({answer}); either the platform started no process "
        f"through {app_id}'s D-Bus service file, or the process it started "
        f"never reached its verdict. The act-two log below is that "
        f"process's own output, and it is EMPTY when nothing started.")
    return 1


sys.exit(main(sys.argv[1:]))
