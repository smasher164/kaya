#!/usr/bin/env python3
"""The second act through the APP LINK door (docs/app-links-plan.md §4).

    tools/linux/link-leg.py <guest> [args...]
    tools/linux/link-leg.py --self-test

Runs INSIDE the linux container, from tools/linux/run-suites.sh, so it
carries no dev-shell guard: the container is not the nix shell
(persist-leg.py's, act2.py's and install-desktop.py's rule).

persist-leg.py's shape with a different door and a URL. Act one runs to
its `relaunch link "<url>"` line, prints `KAYA_RELAUNCH: door link
url=<url>` and exits; this reads the URL off that line and pushes
`gio open <url>` — the cold door measured 2026-09-09 at 44-49 ms through
D-Bus activation, which starts the app through the service file the
desktop entry's arm installs and delivers the URL over
`org.freedesktop.Application.Open`.

THREE THINGS THE MEASUREMENTS PUT HERE RATHER THAN IN A COMMENT
ELSEWHERE: the door is `gio open` and never `xdg-open` (absent from the
image, ignores DBusActivatable, and BLOCKS for the whole lifetime of the
app it starts — 12.160s against a 12s app); the door gets a FILE and
never a pipe, because on the spawn route the app inherits it and a 10 ms
call then measures 45.1s; and `gio open`'s rc is the method call's, not
the app's, so the verdict polled below is act two's own.
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
DOOR = "link"
# The environment act two may not inherit (persist-leg.py's list, same
# reasons): a scene name reaching the relaunched process runs act one
# again from the top and writes no verdict at all.
STRIPPED = ("KAYA_SELFTEST", "KAYA_SELFTEST_SCRIPT", "KAYA_ACT2_DIR",
            "KAYA_ACT2_VERDICT")

sys.path.insert(0, str(WORK / "tools/lib"))


def say(message):
    print(f"link-leg: {message}", file=sys.stderr, flush=True)


def door_env(base):
    """The environment the link door hands the relaunched process."""
    out = dict(base)
    for name in STRIPPED:
        out.pop(name, None)
    return out


def marker_findings(directory):
    """Why there is no second act to drive, when there is not."""
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


def door_findings(act_one_output, wanted):
    """The door act one ASKED FOR, and the URL it asked for it with.

    `relaunch link "<url>"` prints `KAYA_RELAUNCH: door link url=<url>`.
    A leg wired to another runner would push a door with no URL in it and
    wait out its ceiling naming nothing, and a line with the door but no
    URL would have this leg open the empty string.
    """
    asked = [w.strip() for w in act_one_output.splitlines()
             if w.strip().startswith("KAYA_RELAUNCH:")]
    prefix = f"KAYA_RELAUNCH: door {wanted} url="
    for line in asked:
        if line.startswith(prefix):
            url = line[len(prefix):].strip()
            if not url:
                return [f"FAILED — act one printed {line!r} with an empty "
                        f"URL, so this leg has nothing to open"], None
            return [], url
    return [f"FAILED — act one never printed a {prefix!r} line, so this "
            f"leg's link door is not the one the scene asked for. What it "
            f"printed: {asked or ['no KAYA_RELAUNCH line at all']}"], None


def home_findings(data_home, config_home, app_id):
    """The LANE'S OWN XDG home is never written by a leg.

    Every leg of every scene stages the same app id, and the entry, the
    service file and mimeapps.list are one path per app: a leg that let
    them land in `~/.local/share` would register a handler for the whole
    machine and two concurrent legs would overwrite each other's.
    """
    home = pathlib.Path.home().resolve()
    bad = []
    for label, path in (("data home", pathlib.Path(data_home)),
                        ("config home", pathlib.Path(config_home))):
        resolved = pathlib.Path(path).resolve()
        if resolved == home or home in resolved.parents:
            bad.append(f"FAILED — this leg's {label} is {resolved}, under "
                       f"the account's own {home}: the app's entry and its "
                       f"scheme registration are one path per app, so a leg "
                       f"writing there registers a handler for the whole "
                       f"machine and races every other leg")
    shared = home / ".local/share/applications" / f"{app_id}.desktop"
    if shared.exists():
        bad.append(f"FAILED — {shared} exists, so the account's own "
                   f"applications directory carries this app's entry and "
                   f"`gio open` may resolve the scheme to it rather than to "
                   f"the one this leg staged")
    return bad


def resolution_findings(resolved, app_id):
    """`gio mime`'s answer, read back before the door is pushed.

    EVERY KAYA GUEST CLAIMS THE SAME SCHEME — it defaults to the declared
    id — so a second entry claiming it turns `gio open` into an undefined
    pick with rc 0 and no delivery (measured 2026-09-09). The leg's own
    mimeapps.list `[Default Applications]` stanza is what decides; this is
    that decision read back out of GIO rather than assumed.
    """
    want = f"{app_id}.desktop"
    if resolved == want:
        return []
    return [f"FAILED — `gio mime` resolves this scheme to {resolved!r}, "
            f"not to {want!r}. The door would open whatever that is, exit "
            f"0, and deliver nothing to this leg's app"]


def activated_findings(seen, binary):
    """WHICH process the bus actually started, before act two is joined.

    `seen` is (pid, exe, cmdline) for every process carrying this leg's
    own XDG_STATE_HOME — which is every process this leg's session bus
    activated, since an activated process inherits the daemon's environ.
    A verdict written by another app's process is the shape a shared
    scheme produces, and it reads exactly like a green leg from outside.
    """
    want = os.path.realpath(binary)
    if any(exe == want for _, exe, _ in seen):
        return []
    if not seen:
        return [f"FAILED — no process carrying this leg's own "
                f"XDG_STATE_HOME was ever running while the door was open, "
                f"so nothing this leg's bus started can be shown to be "
                f"{want}"]
    listed = "; ".join(f"pid {pid} exe {exe} ({cmd})" for pid, exe, cmd in seen)
    return [f"FAILED — the link was delivered to a process that is not "
            f"{want}. What this leg's bus started: {listed}"]


def bus_started(state_home):
    """Every live process this leg's session bus started, read off /proc.

    The discriminator is the leg's own XDG_STATE_HOME in the process's
    environ: dbus-launch was given it, and an activated process inherits
    the daemon's environment.
    """
    needle = f"XDG_STATE_HOME={state_home}".encode()
    out = []
    proc = pathlib.Path("/proc")
    if not proc.is_dir():
        return out
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if needle not in (entry / "environ").read_bytes():
                continue
            exe = os.path.realpath(entry / "exe")
            cmdline = (entry / "cmdline").read_bytes().replace(
                b"\0", b" ").decode("utf-8", "replace").strip()
        except OSError:
            continue
        out.append((int(entry.name), exe, cmdline))
    return out


def scheme_findings(url, declared_scheme):
    """The URL act one named against the scheme this leg registered.

    `gio open` on a scheme nothing claims exits 0 having launched
    nothing at all on some builds and 2 on others, and either way the
    leg's cause is the registration rather than the app.
    """
    prefix = f"{declared_scheme}://"
    if url.startswith(prefix):
        return []
    return [f"FAILED — act one asked for {url!r}, which is not under "
            f"{prefix!r} — the scheme this leg registered a handler for. "
            f"`gio open` would resolve it to another app, or to none"]


def drive(argv):
    home = pathlib.Path(tempfile.mkdtemp(prefix="kaya-link-"))
    try:
        return run_leg(argv, home)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def run_leg(argv, home):
    env = dict(os.environ)
    # PER LEG (persist-leg.py's rule, and here the registration too):
    # the desktop entry, the service file and mimeapps.list are one path
    # per app, so two legs sharing an XDG home would write each other's
    # handler registration.
    env["XDG_DATA_HOME"] = str(home / "share")
    env["XDG_CONFIG_HOME"] = str(home / "config")
    env["XDG_CACHE_HOME"] = str(home / "cache")
    env["XDG_STATE_HOME"] = str(home / "state")
    env["KAYA_ACT2_LOG"] = str(home / "act2.log")
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
                "XDG_STATE_HOME"):
        pathlib.Path(env[key]).mkdir(parents=True, exist_ok=True)

    # A PRIVATE RUNTIME DIR, with the compositor socket linked back.
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

    # THE ACTIVATION FILES AND THE REGISTRATION ARE THE GENERATOR'S
    # (tools/lib/packaging/linux.py): the entry with `MimeType=` and
    # `%u`, the D-Bus service file, and the mimeapps.list stanza that is
    # the whole of what `gio open` consults. Behind act2-exec.sh, which
    # keeps the relaunched process's output.
    staged = subprocess.run(
        [sys.executable, str(INSTALL_DESKTOP),
         "--config-home", env["XDG_CONFIG_HOME"],
         env["XDG_DATA_HOME"], str(ACT2_EXEC), *argv],
        env=env, text=True, capture_output=True, check=False)
    sys.stderr.write(staged.stderr)
    app_id = staged.stdout.strip()
    if staged.returncode != 0 or not app_id:
        say("the app's desktop entry could not be installed, so this leg "
            "has no link door and no app to start")
        return 1

    from packaging.identity import load  # noqa: E402
    declared_scheme = load(WORK).scheme
    say(f"the scheme this leg registered: {declared_scheme}")
    bad = home_findings(env["XDG_DATA_HOME"], env["XDG_CONFIG_HOME"], app_id)
    for line in bad:
        say(line)
    if bad:
        return 1
    # WHAT GIO WILL ACTUALLY RESOLVE, read back rather than assumed.
    mime = subprocess.run(
        ["gio", "mime", f"x-scheme-handler/{declared_scheme}"],
        env=env, text=True, capture_output=True, check=False)
    resolved = ""
    for line in mime.stdout.splitlines():
        if line.startswith("Default application for"):
            resolved = line.rsplit(":", 1)[-1].strip()
            break
    say(f"`gio mime` resolves x-scheme-handler/{declared_scheme} to "
        f"{resolved!r}")
    bad = resolution_findings(resolved, app_id)
    for line in bad:
        say(line)
    if bad:
        return 1

    # THE SESSION BUS, started AFTER the service file is written: the
    # daemon reads its activation directories out of the environment it
    # starts with, and an activated process inherits the daemon's
    # environ, so KAYA_SELFTEST is stripped here (persist-leg.py's rule).
    launched = subprocess.run(
        ["dbus-launch", "--sh-syntax"], env=door_env(env), text=True,
        capture_output=True, check=False)
    if launched.returncode != 0:
        say(f"no session bus: {launched.stderr.strip()}")
        return 1
    bus = dict(bus_variables(launched.stdout))
    env.update(bus)
    try:
        return act_one_then_door(argv, env, app_id, declared_scheme, home,
                                 argv[0])
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
    """Act one, its output kept AND passed through as it comes."""
    process = subprocess.Popen(
        argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace", bufsize=1)
    lines = []
    for line in process.stdout:
        lines.append(line)
        sys.stdout.write(line)
        sys.stdout.flush()
    return process.wait(), "".join(lines)


def act_one_then_door(argv, env, app_id, declared_scheme, home, binary):
    act_one_rc, act_one_output = tee(argv, env)
    directory = pathlib.Path(env["XDG_STATE_HOME"]) / "kaya/act2" / app_id
    bad = marker_findings(directory)
    if bad:
        if act_one_rc == 0:
            for line in bad:
                say(line)
            return 1
        return act_one_rc
    if act_one_rc != 0:
        say(f"act one exited {act_one_rc}, so its second act is not "
            f"driven — a door pushed after a failed first act would "
            f"measure nothing.")
        return act_one_rc
    bad, url = door_findings(act_one_output, DOOR)
    for line in bad:
        say(line)
    if bad:
        return 1
    bad = scheme_findings(url, declared_scheme)
    for line in bad:
        say(line)
    if bad:
        return 1

    verdict = directory / VERDICT
    if verdict.exists():
        verdict.unlink()
    started = time.monotonic()
    # THE LINK DOOR: the platform's own open of a URL nobody is running
    # to receive. Output to a FILE — a pipe here is a pipe on the app.
    say(f"the link door: gio open {url}")
    door_log = home / "gio-open.log"
    with door_log.open("w", encoding="utf-8") as sink:
        pushed = subprocess.run(
            ["gio", "open", url], env=door_env(env), text=True,
            stdout=sink, stderr=subprocess.STDOUT, check=False)
    said = door_log.read_text(encoding="utf-8", errors="replace").strip()
    if pushed.returncode != 0:
        say(f"`gio open` refused the URL ({pushed.returncode}): {said}")
        return 1
    if said:
        say(f"`gio open` said: {said}")

    status, seen = poll_verdict(verdict, started, 90.0, app_id, url,
                                env["XDG_STATE_HOME"])
    if status == 0:
        # BEFORE ACT TWO IS JOINED: a verdict written by a process that is
        # not this leg's binary is what a shared scheme produces, and from
        # outside it reads exactly like a green leg.
        bad = activated_findings(seen, binary)
        for line in bad:
            say(line)
        if bad:
            status = 1
    log = pathlib.Path(env["KAYA_ACT2_LOG"])
    print("--- act two ---", file=sys.stderr)
    if log.is_file():
        sys.stderr.write(log.read_text(encoding="utf-8", errors="replace"))
    else:
        say("no act-two log at all, so nothing was started")
    return status


def poll_verdict(verdict, started, ceiling, app_id, url, state_home):
    """The verdict, and every process this leg's bus had running while it
    was waited for — sampled as it polls, because the process that took
    the link may be gone by the time the verdict lands."""
    seen = {}
    while time.monotonic() - started < ceiling:
        for pid, exe, cmdline in bus_started(state_home):
            seen[pid] = (pid, exe, cmdline)
        if verdict.is_file():
            line = verdict.read_text(encoding="utf-8").strip()
            say(f"act two answered after {time.monotonic() - started:.1f}s: "
                f"{line}")
            if line.startswith("KAYA_SELFTEST: OK"):
                return 0, sorted(seen.values())
            say("FAILED — act two ran and did not pass; its own output is "
                "in the act-two log below.")
            return 1, sorted(seen.values())
        time.sleep(0.1)
    listed = "; ".join(f"pid {pid} exe {exe}"
                       for pid, exe, _ in sorted(seen.values())) or "nothing"
    say(f"FAILED — no {verdict} within {ceiling:.0f}s. `gio open {url}` "
        f"returned 0, which on the D-Bus route means the method call was "
        f"SENT and nothing more; either the bus started no process under "
        f"{app_id}'s service file, or the process it started never reached "
        f"its verdict. What this leg's bus had running meanwhile: {listed}. "
        f"The act-two log below is that process's own output, and it is "
        f"EMPTY when nothing started.")
    return 1, sorted(seen.values())


def self_test():
    """The refusals, watched firing. Counts printed; a green run here is
    what says the sentences above are reachable."""
    from packaging import linux as packaging_linux  # noqa: E402
    from packaging.identity import load  # noqa: E402
    failures = 0
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="kaya-link-selftest-"))
    try:
        # N1 — a directory with no marker at all.
        got = marker_findings(scratch / "absent")
        print(f"link-leg: self-test N1 — no act-two directory: {len(got)} "
              f"finding(s)")
        if not any("directory itself is absent" in f for f in got):
            say(f"SELF-TEST FAILED — N1 wanted the absent-directory "
                f"sentence, got {got!r}")
            failures += 1

        # N2 — the door line and its URL, three ways.
        real = ('step 12 relaunch\n'
                'KAYA_RELAUNCH: door link url=dev.kaya.aurora.notes://task/t1\n')
        got, url = door_findings(real, DOOR)
        print(f"link-leg: self-test N2 — the real door line: {len(got)} "
              f"finding(s), url {url!r}")
        if got or url != "dev.kaya.aurora.notes://task/t1":
            say(f"SELF-TEST FAILED — N2 refused the real door line: "
                f"{got!r} {url!r}")
            failures += 1
        for label, output in (
                ("another door", "KAYA_RELAUNCH: door launch\n"),
                ("no door line at all", "step 12 relaunch\n")):
            got, url = door_findings(output, DOOR)
            print(f"link-leg: self-test N2 — {label}: {len(got)} finding(s)")
            if url is not None or not any(
                    "is not the one the scene asked for" in f for f in got):
                say(f"SELF-TEST FAILED — N2 accepted {label}: {got!r}")
                failures += 1
        got, url = door_findings("KAYA_RELAUNCH: door link url=\n", DOOR)
        print(f"link-leg: self-test N2 — the door with an empty URL: "
              f"{len(got)} finding(s)")
        if url is not None or not any("empty URL" in f for f in got):
            say(f"SELF-TEST FAILED — N2 accepted an empty URL: {got!r}")
            failures += 1

        # N3 — the scheme clause. A scene naming another app's scheme
        # would have `gio open` resolve it elsewhere, or nowhere.
        got = scheme_findings("dev.kaya.aurora.notes://today", "dev.kaya.aurora.notes")
        print(f"link-leg: self-test N3 — the registered scheme: {len(got)} "
              f"finding(s)")
        if got:
            say(f"SELF-TEST FAILED — N3 refused the registered scheme: "
                f"{got!r}")
            failures += 1
        got = scheme_findings("https://example.com/tasks/t1",
                              "dev.kaya.aurora.notes")
        print(f"link-leg: self-test N3 — a URL under another scheme: "
              f"{len(got)} finding(s)")
        if not any("not under" in f for f in got):
            say(f"SELF-TEST FAILED — N3 accepted a foreign scheme: {got!r}")
            failures += 1

        # N4 — the door's environment (persist-leg.py's N4, same class):
        # KAYA_SELFTEST reaching act two makes it run act one again from
        # the top and write no verdict, so the leg dies at its ceiling.
        leaky = {"KAYA_SELFTEST": "links", "KAYA_ACT2_DIR": "/x",
                 "KAYA_LIB": "/work/libkaya.so", "PATH": "/usr/bin"}
        handed = door_env(leaky)
        print(f"link-leg: self-test N4 — {len(leaky) - len(handed)} of "
              f"{len(STRIPPED)} act-one variable(s) stripped, "
              f"{len(handed)} kept")
        if any(name in handed for name in STRIPPED):
            say(f"SELF-TEST FAILED — N4 handed act two {handed!r}")
            failures += 1
        if handed.get("KAYA_LIB") != "/work/libkaya.so":
            say("SELF-TEST FAILED — N4 stripped the leg's own "
                "environment; act two would find neither the binding nor "
                "the assets")
            failures += 1

        # N5/N6/N7/N8 — THE STAGING'S OWN REFUSALS
        # (tools/lib/packaging/linux.py). Each shape below passes every
        # WARM assertion on this lane and fails cold, silently, or with
        # no core built at all — so a leg cannot watch them and this is
        # where they are watched. The trees are doctored copies of what
        # the generator writes.
        # THE GENERATOR'S OWN BYTES, never a hand-written entry beside
        # them (tools/check-app-identity.py's one-arm rule): the shapes
        # below are its output doctored, so a clause that stopped
        # matching what it actually writes is a red here.
        declared = load(WORK)
        app_id = declared.id
        data = scratch / "share"
        apps = data / "applications"
        services = data / "dbus-1/services"
        apps.mkdir(parents=True, exist_ok=True)
        services.mkdir(parents=True, exist_ok=True)
        entry = apps / f"{app_id}.desktop"
        service = services / f"{app_id}.service"
        good_entry = packaging_linux.desktop_entry(declared, "/usr/bin/true")
        good_service = packaging_linux.service_file(declared, "/usr/bin/true")
        entry.write_text(good_entry, encoding="utf-8")
        service.write_text(good_service, encoding="utf-8")
        got = packaging_linux.activation_findings(data, app_id)
        print(f"link-leg: self-test N5 — the generator's own pair: "
              f"{len(got)} finding(s)")
        if got:
            say(f"SELF-TEST FAILED — N5 refused a correct tree: {got!r}")
            failures += 1

        service.unlink()
        got = packaging_linux.activation_findings(data, app_id)
        print(f"link-leg: self-test N6 — activatable with no service "
              f"file: {len(got)} finding(s)")
        if not any("not provided by any .service files" in f for f in got):
            say(f"SELF-TEST FAILED — N6 accepted the cold-only shape: "
                f"{got!r}")
            failures += 1

        service.write_text(good_service, encoding="utf-8")
        entry.write_text(good_entry.replace("Exec=/usr/bin/true %u",
                                            "Exec=/usr/bin/true"),
                         encoding="utf-8")
        got = packaging_linux.activation_findings(data, app_id)
        print(f"link-leg: self-test N7 — a scheme claimed with no %u: "
              f"{len(got)} finding(s)")
        if not any("carries no %u" in f for f in got):
            say(f"SELF-TEST FAILED — N7 accepted an Exec with no field "
                f"code: {got!r}")
            failures += 1

        entry.write_text(good_entry, encoding="utf-8")
        service.write_text(
            good_service.replace("Exec=/usr/bin/true",
                                 "Exec=/usr/bin/true --gapplication-service"),
            encoding="utf-8")
        got = packaging_linux.activation_findings(data, app_id)
        print(f"link-leg: self-test N8 — --gapplication-service on the "
              f"service file: {len(got)} finding(s)")
        if not any("suppresses `activate`" in f for f in got):
            say(f"SELF-TEST FAILED — N8 accepted the switch that leaves "
                f"gtk.rs building no core: {got!r}")
            failures += 1
        # N9 — THE SHARED-SCHEME CLAUSES (measured on Android and
        # relayed 2026-09-09): every kaya guest claims the SAME scheme,
        # so a second entry claiming it makes `gio open` an undefined
        # pick that exits 0 and delivers nothing. Neither clause can be
        # watched by a leg: the per-leg XDG home makes the collision
        # impossible on the lane, which is the point.
        got = resolution_findings(f"{app_id}.desktop", app_id)
        print(f"link-leg: self-test N9 — gio resolving to this leg's own "
              f"entry: {len(got)} finding(s)")
        if got:
            say(f"SELF-TEST FAILED — N9 refused our own entry: {got!r}")
            failures += 1
        for label, answer in (("another app's entry", "org.other.App.desktop"),
                              ("nothing at all", "")):
            got = resolution_findings(answer, app_id)
            print(f"link-leg: self-test N9 — gio resolving to {label}: "
                  f"{len(got)} finding(s)")
            if not any("deliver nothing to this leg's app" in f
                       for f in got):
                say(f"SELF-TEST FAILED — N9 accepted {label}: {got!r}")
                failures += 1

        # N10 — the process that actually took the link.
        binary = scratch / "tasks"
        binary.write_text("#!/bin/sh\n", encoding="utf-8")
        mine = os.path.realpath(binary)
        got = activated_findings([(7, mine, f"{mine} --x")], binary)
        print(f"link-leg: self-test N10 — the leg's own binary among the "
              f"started processes: {len(got)} finding(s)")
        if got:
            say(f"SELF-TEST FAILED — N10 refused our own process: {got!r}")
            failures += 1
        got = activated_findings(
            [(9, "/usr/bin/other-app", "/usr/bin/other-app kaya://x")], binary)
        print(f"link-leg: self-test N10 — another app's process holding the "
              f"scheme: {len(got)} finding(s)")
        if not any("/usr/bin/other-app" in f and "is not" in f for f in got):
            say(f"SELF-TEST FAILED — N10 accepted a foreign process: {got!r}")
            failures += 1
        got = activated_findings([], binary)
        print(f"link-leg: self-test N10 — nothing started at all: "
              f"{len(got)} finding(s)")
        if not any("was ever running" in f for f in got):
            say(f"SELF-TEST FAILED — N10 accepted an empty sample: {got!r}")
            failures += 1

        # N11 — the account's own XDG home, never written by a leg.
        got = home_findings(scratch / "share", scratch / "config", app_id)
        print(f"link-leg: self-test N11 — a private XDG home: {len(got)} "
              f"finding(s)")
        if got:
            say(f"SELF-TEST FAILED — N11 refused a private home: {got!r}")
            failures += 1
        home = pathlib.Path.home()
        got = home_findings(home / ".local/share", scratch / "config", app_id)
        print(f"link-leg: self-test N11 — a data home under the account's "
              f"own: {len(got)} finding(s)")
        if not any("registers a handler for the whole machine" in f
                   for f in got):
            say(f"SELF-TEST FAILED — N11 accepted the shared home: {got!r}")
            failures += 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if failures:
        say(f"SELF-TEST FAILED — {failures} clause(s)")
        return 1
    print("link-leg: self-test — 11 clause(s), every refusal watched firing")
    return 0


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if not argv:
        say("usage: link-leg.py <guest> [args...]")
        return 2
    if not WORK.is_dir():
        say("this runs INSIDE the linux container, where the repo is "
            "mounted at /work")
        return 2
    return drive(argv)


sys.exit(main(sys.argv[1:]))
