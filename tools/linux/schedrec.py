#!/usr/bin/env python3
"""The recording session scheduler (docs/tasks-s3-plan.md N2, §7).

Runs INSIDE the linux container, on the notify leg's PATH as BOTH
`systemd-run` and `systemctl` — the two commands the GTK arm reaches for
when a notification carries a time. The container runs no systemd user
manager, so the real `systemd-run --user` fails and the arm would fall
through to `at` and then to an in-process timer, measuring neither of the
routes a desktop takes. This one RECORDS what the arm asked for, in the
log the leg reads, and then honours it in the simplest way that keeps the
measurement true: a child that waits until the time and runs the command,
which is what a transient timer does.

    systemd-run --user --collect --unit=U --on-calendar="Y-m-d H:M:S" CMD...
    systemctl --user stop U

argv[0] decides which; both append one line to $KAYA_NOTIFY_SCHED_LOG.
"""

import datetime
import os
import subprocess
import sys
import time

LOG = os.environ.get("KAYA_NOTIFY_SCHED_LOG", "/tmp/kaya-notify-sched.log")
UNITS = os.environ.get("KAYA_NOTIFY_SCHED_UNITS", "/tmp/kaya-notify-units")


def record(line):
    with open(LOG, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")
    print(f"schedrec: {line}", file=sys.stderr, flush=True)


def unit_file(unit):
    os.makedirs(UNITS, exist_ok=True)
    return os.path.join(UNITS, unit.replace("/", "_"))


def systemd_run(argv):
    unit, when, command = "", "", []
    rest = list(argv)
    while rest:
        arg = rest.pop(0)
        if arg in ("--user", "--collect", "--scope"):
            continue
        if arg.startswith("--unit="):
            unit = arg.split("=", 1)[1]
            continue
        if arg.startswith("--on-calendar="):
            when = arg.split("=", 1)[1]
            continue
        if arg.startswith("--"):
            continue
        command = [arg] + rest
        break
    record(f"systemd-run --user --unit={unit} --on-calendar={when!r} "
           f"-- {' '.join(command)}")
    if not command:
        return 1
    if when:
        try:
            fires = datetime.datetime.strptime(when, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            record(f"systemd-run: {when!r} is not an OnCalendar timestamp "
                   f"this recorder parses")
            return 1
        delay = max(0.0, fires.timestamp() - time.time())
    else:
        delay = 0.0
    # The transient timer, played by a child that outlives this command
    # exactly as the manager's own unit does.
    child = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "--fire", str(delay)]
        + command,
        start_new_session=True)
    if unit:
        with open(unit_file(unit), "w", encoding="utf-8") as handle:
            handle.write(str(child.pid))
    record(f"systemd-run: unit {unit} armed for {delay:.1f}s as pid "
           f"{child.pid}")
    return 0


def systemctl(argv):
    record(f"systemctl {' '.join(argv)}")
    unit = argv[-1] if argv else ""
    path = unit_file(unit)
    if "stop" in argv and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            pid = int(handle.read().strip() or 0)
        try:
            os.kill(pid, 15)
            record(f"systemctl: unit {unit} (pid {pid}) stopped")
        except ProcessLookupError:
            record(f"systemctl: unit {unit} (pid {pid}) had already fired")
        os.unlink(path)
        return 0
    record(f"systemctl: no unit {unit!r} on record")
    return 1


def fire(argv):
    """The armed child: wait, then run the command the timer carried."""
    delay = float(argv[0])
    time.sleep(delay)
    record(f"fired after {delay:.1f}s: {' '.join(argv[1:])}")
    done = subprocess.run(argv[1:], check=False, capture_output=True,
                          text=True, encoding="utf-8")
    record(f"fired command exited {done.returncode} "
           f"{done.stdout.strip()!r} {done.stderr.strip()!r}")
    return done.returncode


name = os.path.basename(sys.argv[0])
if sys.argv[1:2] == ["--fire"]:
    sys.exit(fire(sys.argv[2:]))
if name == "systemctl":
    sys.exit(systemctl(sys.argv[1:]))
sys.exit(systemd_run(sys.argv[1:]))
