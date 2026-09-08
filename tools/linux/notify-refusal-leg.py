#!/usr/bin/env python3
"""The ruled floor's other half, as a leg (docs/tasks-s3-plan.md §0).

Runs INSIDE the linux container. The maintainer's ruling of 2026-09-07 is
that kaya posts ONLY where the desktop remembers the notification and
relaunches the app on a click — the portal, or GNOME's own interface — and
that anywhere else the capability reads false, the post comes back
`refused`, and kaya says nothing of its own. A plain freedesktop daemon
alone (mako, dunst, swaync, Plasma with no portal) is exactly that
"anywhere else".

NO SHARED SCENE CAN ASSERT IT: tools/scenes/notify.steps expects a host
that CAN post, and a scene reads the same script on five platforms, where
four of them always can. So this witness builds the one session the ruling
is about — a bus with a freedesktop daemon on it, no portal, no
org.gtk.Notifications — and holds the three things that follow:

    the guest reads the capability FALSE                ("cannot post")
    the post is answered `refused`, with the id         ("refused 12")
    the daemon is asked to draw NOTHING, and kaya logs nothing

It is a witness leg like tools/linux/dragwitness-leg.py: its script is its
own, because the state it drives exists on no other platform.
"""

import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

GUEST = sys.argv[1] if len(sys.argv) > 1 else \
    "/work/target-linux/debug/examples/notify"
NOTIFYD = "/work/tools/linux/notifyd.py"
# The guest's own scene, one screen wide: the capability's word, a click,
# and the answer the post gets. `expect` retries to its deadline, so the
# refusal need not beat the label's own write.
SCRIPT = '\n'.join([
    'expect label#0 "cannot post"',
    'click button#0',
    'expect label#0 "refused 12"',
])


def say(line):
    print(f"notify-refusal: {line}", flush=True)


def bus_env(home):
    """A session bus of this leg's own, with no portal on it: the image
    keeps the portal's D-Bus service files outside the default search path
    (tools/linux/Dockerfile) and only a portal leg puts them back, so a
    plain `dbus-launch` here is the plain-daemon regime by construction —
    asserted below rather than assumed."""
    env = dict(os.environ)
    env["XDG_DATA_HOME"] = str(home / "share")
    env["XDG_CONFIG_HOME"] = str(home / "config")
    env["XDG_CACHE_HOME"] = str(home / "cache")
    env["XDG_RUNTIME_DIR"] = str(home / "run")
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
                "XDG_RUNTIME_DIR"):
        pathlib.Path(env[key]).mkdir(parents=True, exist_ok=True)
    os.chmod(env["XDG_RUNTIME_DIR"], 0o700)
    # A wayland leg finds its compositor through XDG_RUNTIME_DIR, so the
    # socket is linked into the private one (a11y-leg.sh's rule).
    display = os.environ.get("WAYLAND_DISPLAY", "")
    outer = os.environ.get("XDG_RUNTIME_DIR", "")
    if display and outer:
        for name in (display, display + ".lock"):
            source = pathlib.Path(outer) / name
            if source.exists():
                target = pathlib.Path(env["XDG_RUNTIME_DIR"]) / name
                if not target.exists():
                    target.symlink_to(source)
    launch = subprocess.run(
        ["dbus-launch", "--sh-syntax"], capture_output=True, text=True,
        encoding="utf-8", check=False,
        env=env)
    if launch.returncode != 0:
        raise SystemExit(f"notify-refusal: dbus-launch failed: "
                         f"{launch.stderr.strip()}")
    for line in launch.stdout.splitlines():
        if "=" not in line or not line.endswith(";"):
            continue
        key, _, value = line.rstrip(";").partition("=")
        env[key.replace("export ", "").strip()] = value.strip().strip("'\"")
    if "DBUS_SESSION_BUS_ADDRESS" not in env:
        raise SystemExit("notify-refusal: dbus-launch named no bus address")
    return env


def name_has_owner(env, name):
    done = subprocess.run(
        ["gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
         "--object-path", "/org/freedesktop/DBus", "--method",
         "org.freedesktop.DBus.NameHasOwner", name],
        capture_output=True, text=True, encoding="utf-8", check=False, env=env)
    return "true" in done.stdout


def portal_answers(env):
    done = subprocess.run(
        ["timeout", "30", "gdbus", "call", "--session", "--dest",
         "org.freedesktop.portal.Desktop", "--object-path",
         "/org/freedesktop/portal/desktop", "--method",
         "org.freedesktop.DBus.Properties.Get",
         "org.freedesktop.portal.Notification", "version"],
        capture_output=True, text=True, encoding="utf-8", check=False, env=env)
    return done.returncode == 0, (done.stdout + done.stderr).strip()


home = pathlib.Path(tempfile.mkdtemp(prefix="kaya-notify-refusal-"))
daemon = None
env = None
findings = []
try:
    env = bus_env(home)
    log = home / "notifyd.log"
    with open(log, "w", encoding="utf-8") as handle:
        daemon = subprocess.Popen(
            ["python3", NOTIFYD], stdout=handle, stderr=subprocess.STDOUT,
            env={**env, "KAYA_NOTIFYD_NAMES": "fdo"})
    waited = 0
    while "notifyd: ready" not in log.read_text(encoding="utf-8"):
        waited += 1
        if waited > 100:
            raise SystemExit("notify-refusal: the plain daemon never owned "
                             "org.freedesktop.Notifications, so this leg "
                             "would measure an empty bus rather than the "
                             "regime the ruling is about")
        time.sleep(0.05)

    # THE REGIME IS ASSERTED, NOT ASSUMED: this leg means nothing on a bus
    # that turns out to have a registry after all.
    answers, said = portal_answers(env)
    if answers:
        findings.append(f"a portal answers on this leg's bus ({said}), so "
                        f"kaya would take its portal arm and post — the "
                        f"regime under test is not here")
    if name_has_owner(env, "org.gtk.Notifications"):
        findings.append("org.gtk.Notifications has an owner on this leg's "
                        "bus, so kaya would take its GNOME arm and post")
    if not name_has_owner(env, "org.freedesktop.Notifications"):
        findings.append("nothing owns org.freedesktop.Notifications, so this "
                        "is an EMPTY bus rather than the plain-daemon regime")
    say(f"the bus: freedesktop daemon yes, portal no ({said}), "
        f"org.gtk.Notifications no")

    guest = subprocess.run(
        ["timeout", "120", GUEST], capture_output=True, text=True,
        encoding="utf-8", check=False,
        env={**env, "KAYA_SELFTEST": "1", "KAYA_SELFTEST_SCRIPT": SCRIPT})
    said_by_guest = guest.stdout + guest.stderr
    print(said_by_guest, end="", flush=True)
    if "KAYA_SELFTEST: OK" not in said_by_guest:
        findings.append(
            "the guest did not read the capability false and answer the post "
            "`refused` — the floor says a host with no registry posts nothing "
            "and reports it through the result, exactly as a denied "
            "permission does on the other four platforms")
    drawn = [line for line in log.read_text(encoding="utf-8").splitlines()
             if "Notify " in line]
    if drawn:
        findings.append(
            f"the plain daemon WAS asked to draw {len(drawn)} notification(s) "
            f"({drawn[0]}) — the ruled floor is that kaya posts nothing where "
            f"the click would be inert")
    # No reason string and no log line of kaya's own about the REFUSAL (the
    # ruling of 2026-09-07): the outcome is the whole report, exactly as a
    # denied permission is on the other four platforms.
    ours = [line for line in said_by_guest.splitlines()
            if "KAYA_DIAG notification" in line
            and "notification route:" not in line]
    if ours:
        findings.append(f"kaya logged its own line about the refusal "
                        f"({ours[0]!r}); the outcome is the whole report")
    # THE STARTUP INSTRUMENT IS A DIFFERENT THING, and this leg wants it:
    # printed under the harness only, it is what tells the four causes of a
    # false capability apart (no bus, no app id, no portal, a registration
    # the portal refused). Requiring it also proves kaya saw the regime this
    # leg built rather than some other one.
    route = [line for line in said_by_guest.splitlines()
             if "KAYA_DIAG notification route: session bus" in line]
    if len(route) != 1:
        findings.append(f"the guest printed {len(route)} route lines, wanted "
                        f"exactly one — the instrument that names why the "
                        f"capability reads false is how a red leg here is "
                        f"read at all")
    elif not route[0].rstrip().endswith("-> None"):
        findings.append(f"kaya chose a route on a bus with no registry: "
                        f"{route[0]}")
    else:
        say(route[0].split("KAYA_DIAG ", 1)[1])
finally:
    if daemon is not None:
        daemon.send_signal(signal.SIGTERM)
        daemon.wait(timeout=10)
    if env and env.get("DBUS_SESSION_BUS_PID", "").isdigit():
        try:
            os.kill(int(env["DBUS_SESSION_BUS_PID"]), signal.SIGTERM)
        except ProcessLookupError:
            pass
    shutil.rmtree(home, ignore_errors=True)

for finding in findings:
    print(f"notify-refusal: {finding}", file=sys.stderr, flush=True)
if findings:
    sys.exit(1)
say("the floor holds: capability false, the post refused, nothing drawn, "
    "nothing logged")
