#!/usr/bin/env python3
"""The second act through the PLAIN door (docs/tasks-s4-plan.md P5, §4).

    tools/linux/persist-leg.py <guest> [args...]
    tools/linux/persist-leg.py --self-test

Runs INSIDE the linux container, from tools/linux/run-suites.sh, so it
carries no dev-shell guard: the container is not the nix shell
(act2.py's, notifyd.py's and install-desktop.py's rule).

S9's door is a notification tap. S4's scenes relaunch with nothing
pending, so the door here is the one a user pushes from a launcher: the
app's own desktop entry, started through `gio launch`, which is
`g_app_info_launch` on a `GDesktopAppInfo` — the same reader the portal
resolves an app id with. Everything else is the notify leg's shape: a
private XDG home so the preferences keyfile, the app data directory and
the act-two marker belong to this leg alone; the generator's activation
files, so the lane launches what an installed app has; and a session bus
with KAYA_SELFTEST stripped, because an activated process inherits the
bus daemon's environ and act two must adopt the marker rather than run
act one again from the top (crates/kaya/src/act2.rs).
"""

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

WORK = pathlib.Path("/work")
INSTALL_DESKTOP = WORK / "tools/linux/install-desktop.py"
ACT2_EXEC = WORK / "tools/linux/act2-exec.sh"
MARKER = "marker"
VERDICT = "act2.verdict"
# The door this leg pushes, and the name act one prints for it. ONE
# SPELLING: tools/linux/run-suites.sh carries `RELAUNCH_DOOR_<SCENE>=`
# with the same word, and check-steps.py reads that line.
DOOR = "launch"
# The environment act two may not inherit: the scene name is the marker's
# to name, and a stale act-two directory would be adopted from the wrong
# run.
STRIPPED = ("KAYA_SELFTEST", "KAYA_SELFTEST_SCRIPT", "KAYA_ACT2_DIR",
            "KAYA_ACT2_VERDICT")


def say(message):
    print(f"persist-leg: {message}", file=sys.stderr, flush=True)


def door_env(base):
    """The environment the plain door hands the relaunched process."""
    out = dict(base)
    for name in STRIPPED:
        out.pop(name, None)
    return out


def marker_findings(directory):
    """Why there is no second act to drive, when there is not.

    The sentence names what the directory actually holds: a leg whose act
    one died before its `relaunch` line and a leg whose act one never had
    one read identically from the outside.
    """
    marker = directory / MARKER
    if marker.is_file():
        return []
    if directory.is_dir():
        beside = sorted(p.name for p in directory.glob("*")) or ["nothing"]
    else:
        beside = ["the directory itself is absent"]
    return [f"FAILED — act one left no {marker}, so it never reached its "
            f"`relaunch` line and there is no second act to drive. What "
            f"{directory} holds: {', '.join(beside)}"]


def entry_findings(app_id, data_home):
    """The entry the door will push, through GLib's own reader.

    install-desktop.py already refuses a relative Exec; this is the other
    half, and it is what turns "the door did nothing" into a sentence:
    `gio launch` on an entry GLib will not load exits 1 with no cause.
    """
    path = pathlib.Path(data_home) / "applications" / f"{app_id}.desktop"
    if not path.is_file():
        return [f"FAILED — {path} was not written, so the plain door has no "
                f"entry to launch"], None
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio
    info = Gio.DesktopAppInfo.new_from_filename(str(path))
    if info is None:
        return [f"FAILED — GLib will not load {path}, so `gio launch` on it "
                f"starts nothing:\n{path.read_text(encoding='utf-8')}"], None
    return [], path


def drive(argv):
    home = pathlib.Path(tempfile.mkdtemp(prefix="kaya-persist-"))
    try:
        return run_leg(argv, home)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def run_leg(argv, home):
    env = dict(os.environ)
    # PER LEG, a11y-leg.sh's and notify-leg.sh's rule: the preferences
    # keyfile ($XDG_CONFIG_HOME), the app's data directory and the act-two
    # marker (both under $XDG_STATE_HOME) are one path per app, so two
    # legs of one scene under two protocols would write the same files.
    env["XDG_DATA_HOME"] = str(home / "share")
    env["XDG_CONFIG_HOME"] = str(home / "config")
    env["XDG_CACHE_HOME"] = str(home / "cache")
    env["XDG_STATE_HOME"] = str(home / "state")
    env["KAYA_ACT2_LOG"] = str(home / "act2.log")
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
                "XDG_STATE_HOME"):
        pathlib.Path(env[key]).mkdir(parents=True, exist_ok=True)

    # A PRIVATE RUNTIME DIR, with the compositor socket linked back: a
    # Wayland client finds its display through this same variable.
    run_dir = home / "run"
    run_dir.mkdir()
    run_dir.chmod(0o700)
    display = os.environ.get("WAYLAND_DISPLAY", "")
    old_run = os.environ.get("XDG_RUNTIME_DIR", "")
    if old_run and display:
        for name in (display, f"{display}.lock"):
            source = pathlib.Path(old_run) / name
            if source.exists():
                (run_dir / name).symlink_to(source)
    env["XDG_RUNTIME_DIR"] = str(run_dir)

    # THE ACTIVATION FILES ARE THE GENERATOR'S (docs/packaging-plan.md P5),
    # behind act2-exec.sh, which keeps the relaunched process's output.
    staged = subprocess.run(
        [sys.executable, str(INSTALL_DESKTOP), env["XDG_DATA_HOME"],
         str(ACT2_EXEC), *argv],
        env=env, text=True, capture_output=True, check=False)
    sys.stderr.write(staged.stderr)
    app_id = staged.stdout.strip()
    if staged.returncode != 0 or not app_id:
        say("the app's desktop entry could not be installed, so this leg "
            "has no plain door and no app to launch")
        return 1
    bad, entry = entry_findings(app_id, env["XDG_DATA_HOME"])
    for line in bad:
        say(line)
    if bad:
        return 1

    # THE SESSION BUS, with KAYA_SELFTEST stripped from what an activated
    # process inherits (S9 R6): DBusActivatable=true is on the generator's
    # entry, so `gio launch` takes D-Bus activation and the started
    # process's environ is the daemon's.
    launched = subprocess.run(
        ["dbus-launch", "--sh-syntax"], env=door_env(env), text=True,
        capture_output=True, check=False)
    if launched.returncode != 0:
        say(f"no session bus: {launched.stderr.strip()}")
        return 1
    bus = dict(bus_variables(launched.stdout))
    env.update(bus)
    try:
        return act_one_then_door(argv, env, app_id, entry, home)
    finally:
        pid = bus.get("DBUS_SESSION_BUS_PID")
        if pid:
            subprocess.run(["kill", pid], check=False,
                           stderr=subprocess.DEVNULL)


def bus_variables(sh_syntax):
    """dbus-launch --sh-syntax, read as assignments rather than eval'd."""
    for line in sh_syntax.splitlines():
        line = line.strip().removeprefix("export ").rstrip(";")
        if "=" not in line:
            continue
        name, _, value = line.partition("=")
        if name.startswith("DBUS_"):
            yield name, value.strip().strip("'\"").rstrip(";")


def tee(argv, env):
    """Act one, its output kept AND passed through as it comes.

    Not `capture_output`: the runner's `timeout 180` kills this process
    too, and a captured act one would die with its output unwritten —
    which the lane reads as a guest that never reached the harness.
    """
    process = subprocess.Popen(
        argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace", bufsize=1)
    lines = []
    for line in process.stdout:
        lines.append(line)
        sys.stdout.write(line)
        sys.stdout.flush()
    return process.wait(), "".join(lines)


def door_findings(act_one_output, wanted):
    """The door act one ASKED FOR against the door this leg pushes.

    `relaunch launch` prints `KAYA_RELAUNCH: door <name>` (the harness's
    own line). A leg wired to the wrong runner would push the
    notification door at a scene with nothing pending, wait out its
    ceiling and name no cause.
    """
    line = f"KAYA_RELAUNCH: door {wanted}"
    if line in act_one_output:
        return []
    asked = [w.strip() for w in act_one_output.splitlines()
             if w.strip().startswith("KAYA_RELAUNCH:")]
    return [f"FAILED — act one never printed {line!r}, so this leg's plain "
            f"door is not the one the scene asked for. What it printed: "
            f"{asked or ['no KAYA_RELAUNCH line at all']}"]


def act_one_then_door(argv, env, app_id, entry, home):
    act_one_rc, act_one_output = tee(argv, env)
    directory = pathlib.Path(env["XDG_STATE_HOME"]) / "kaya/act2" / app_id
    bad = marker_findings(directory)
    if bad:
        # Act one that never reached `relaunch` has already published its
        # own verdict; this leg's status is act one's.
        if act_one_rc == 0:
            for line in bad:
                say(line)
            return 1
        return act_one_rc
    if act_one_rc != 0:
        say(f"act one exited {act_one_rc}, so its second act is "
            f"not driven — a door pushed after a failed first act would "
            f"measure nothing.")
        return act_one_rc
    bad = door_findings(act_one_output, DOOR)
    for line in bad:
        say(line)
    if bad:
        return 1

    verdict = directory / VERDICT
    if verdict.exists():
        verdict.unlink()
    started = time.monotonic()
    # THE PLAIN DOOR: the app's own entry, started the way a launcher
    # starts it. Nothing here spells the guest's command a second time.
    say(f"the plain door: gio launch {entry}")
    pushed = subprocess.run(
        ["gio", "launch", str(entry)], env=door_env(env), text=True,
        capture_output=True, check=False)
    if pushed.returncode != 0:
        say(f"`gio launch` refused the entry ({pushed.returncode}): "
            f"{pushed.stdout.strip()} {pushed.stderr.strip()}")
        return 1

    status = poll_verdict(verdict, started, 90.0, app_id)
    log = pathlib.Path(env["KAYA_ACT2_LOG"])
    print("--- act two ---", file=sys.stderr)
    if log.is_file():
        sys.stderr.write(log.read_text(encoding="utf-8", errors="replace"))
    else:
        say("no act-two log at all, so nothing was started")
    _ = home
    return status


def poll_verdict(verdict, started, ceiling, app_id):
    while time.monotonic() - started < ceiling:
        if verdict.is_file():
            line = verdict.read_text(encoding="utf-8").strip()
            say(f"act two answered after {time.monotonic() - started:.1f}s: "
                f"{line}")
            if line.startswith("KAYA_SELFTEST: OK"):
                return 0
            say("FAILED — act two ran and did not pass; its own output is "
                "in the act-two log below.")
            return 1
        time.sleep(0.1)
    say(f"FAILED — no {verdict} within {ceiling:.0f}s. The door was pushed "
        f"and answered; either the launcher started no process through "
        f"{app_id}'s entry, or the process it started never reached its "
        f"verdict. The act-two log below is that process's own output, and "
        f"it is EMPTY when nothing started.")
    return 1


def self_test():
    """The refusals, watched firing. Counts printed; a green run here is
    what says the sentences above are reachable."""
    failures = 0
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="kaya-persist-selftest-"))
    try:
        # N1 — a directory with no marker at all.
        empty = scratch / "absent"
        got = marker_findings(empty)
        print(f"persist-leg: self-test N1 — no act-two directory: "
              f"{len(got)} finding(s)")
        if not any("directory itself is absent" in f for f in got):
            say(f"SELF-TEST FAILED — N1 wanted the absent-directory "
                f"sentence, got {got!r}")
            failures += 1

        # N2 — the directory exists and act one died before its marker.
        started = scratch / "started"
        started.mkdir()
        (started / "act2.verdict").write_text("x", encoding="utf-8")
        got = marker_findings(started)
        print(f"persist-leg: self-test N2 — act one left no marker: "
              f"{len(got)} finding(s)")
        if not any("act2.verdict" in f and "left no" in f for f in got):
            say(f"SELF-TEST FAILED — N2 wanted the missing-marker sentence "
                f"naming what is beside it, got {got!r}")
            failures += 1

        # N3 — the marker IS there: no finding, or every leg would refuse.
        (started / MARKER).write_text("taskspersist\nexpect_entries 1\n",
                                      encoding="utf-8")
        got = marker_findings(started)
        print(f"persist-leg: self-test N3 — a real marker: {len(got)} "
              f"finding(s)")
        if got:
            say(f"SELF-TEST FAILED — N3 refused a real marker: {got!r}")
            failures += 1

        # N4 — the door's environment. KAYA_SELFTEST reaching act two is
        # the whole act-one-again failure (S9 R6), and it is SILENT: the
        # relaunched process runs the scene from the top and writes no
        # verdict, so the leg dies at its ceiling naming nothing.
        leaky = {"KAYA_SELFTEST": "taskspersist", "KAYA_ACT2_DIR": "/x",
                 "KAYA_LIB": "/work/libkaya.so", "PATH": "/usr/bin"}
        handed = door_env(leaky)
        print(f"persist-leg: self-test N4 — {len(leaky) - len(handed)} of "
              f"{len(STRIPPED)} act-one variable(s) stripped, "
              f"{len(handed)} kept")
        if any(name in handed for name in STRIPPED):
            say(f"SELF-TEST FAILED — N4 handed act two {handed!r}")
            failures += 1
        if handed.get("KAYA_LIB") != "/work/libkaya.so":
            say("SELF-TEST FAILED — N4 stripped the leg's own environment; "
                "act two would find neither the binding nor the assets")
            failures += 1

        # N5 — the entry clause, on a data home with no entry written.
        bad, entry = entry_findings("dev.kaya.NoSuchApp", scratch)
        print(f"persist-leg: self-test N5 — an entry nobody staged: "
              f"{len(bad)} finding(s)")
        if entry is not None or not any("was not written" in f for f in bad):
            say(f"SELF-TEST FAILED — N5 accepted a missing entry: {bad!r}")
            failures += 1

        # N6 — the door clause. A scene asking for the NOTIFICATION door
        # on this leg would wait out its ceiling with nothing pending.
        real = f"step 41 relaunch\nKAYA_RELAUNCH: door {DOOR}\n"
        got = door_findings(real, DOOR)
        print(f"persist-leg: self-test N6 — the real door line: {len(got)} "
              f"finding(s)")
        if got:
            say(f"SELF-TEST FAILED — N6 refused the real door line: {got!r}")
            failures += 1
        for label, output in (
                ("another door", "KAYA_RELAUNCH: door portal-action\n"),
                ("no door line at all", "step 41 relaunch\n")):
            got = door_findings(output, DOOR)
            print(f"persist-leg: self-test N6 — {label}: {len(got)} "
                  f"finding(s)")
            if not any("is not the one the scene asked for" in f
                       for f in got):
                say(f"SELF-TEST FAILED — N6 accepted {label}: {got!r}")
                failures += 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if failures:
        say(f"SELF-TEST FAILED — {failures} clause(s)")
        return 1
    print("persist-leg: self-test — 6 clause(s), every refusal watched "
          "firing")
    return 0


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if not argv:
        say("usage: persist-leg.py <guest> [args...]")
        return 2
    if not WORK.is_dir():
        say("this runs INSIDE the linux container, where the repo is "
            "mounted at /work")
        return 2
    return drive(argv)


sys.exit(main(sys.argv[1:]))
