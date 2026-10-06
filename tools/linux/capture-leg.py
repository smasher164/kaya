#!/usr/bin/env python3
"""A capture leg's own devices, then the guest (docs/capture-plan.md §7):

    tools/linux/capture-leg.py portal|direct <guest> [args...]
    tools/linux/capture-leg.py --self-test

Runs INSIDE the linux container, from tools/linux/run-suites.sh, so it
carries no dev-shell guard (persist-leg.py's rule). For this leg alone it
starts a session bus, the x11 idle inhibitor's session manager
(tools/linux/sessionmgr.py, media-leg.sh's reason), PipeWire and
WirePlumber in a private runtime directory, and the lane's four synthetic
devices (tools/linux/pwsynth); it runs the guest; then it stops every one
of them and PROVES they are gone, or the leg fails.

The regime is the route the camera takes (§9 ruling 5). `portal` puts the
camera portal on this leg's bus (its service files live off the default
bus: tools/linux/Dockerfile) and pre-grants the unsandboxed app's empty id
in the permission store (OPEN C: the platform's grant is the lane's to
arrange); `direct` leaves no portal at all. Both are ASSERTED: the bus must
answer (or not answer) org.freedesktop.portal.Camera, and every route the
guest prints (`KAYA_DIAG capture route: ...`) must be the regime's.

Everything a red capture leg needs rides the leg log after the guest's
output: PipeWire's nodes and links as the leg ended, and the daemons' and
devices' own logs.
"""

import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque

WORK = pathlib.Path("/work")
PWSYNTH = os.environ.get("KAYA_PWSYNTH", "/tmp/pwsynth/pwsynth")
PORTAL_DIRS = "/opt/kaya-portal"
DEVICES = (
    ("camera", "kaya-synthetic-camera-1", "kaya Synthetic Camera 1", "C83C1E"),
    ("camera", "kaya-synthetic-camera-2", "kaya Synthetic Camera 2", "1E5AC8"),
    ("microphone", "kaya-synthetic-microphone-1", "kaya Synthetic Microphone 1", "440"),
    ("microphone", "kaya-synthetic-microphone-2", "kaya Synthetic Microphone 2", "660"),
)
ROUTE = "KAYA_DIAG capture route: "
GRAPH_KEEP = 30
# The processes this leg may leave nothing of, by the name /proc gives.
STACK = ("pipewire", "wireplumber", "pwsynth", "xdg-desktop-portal", "xdg-desktop-por",
         "xdg-permission-store", "xdg-permission-", "dbus-daemon", "python3")


def say(message):
    print(f"capture-leg: {message}", file=sys.stderr, flush=True)


def route_findings(regime, lines):
    """Every route the guest printed must be the regime's."""
    want = "portal" if regime == "portal" else "direct"
    out = []
    for line in lines:
        at = line.find(ROUTE)
        if at < 0:
            continue
        said = line[at + len(ROUTE):].strip()
        taken = said.split(" ", 1)[0]
        if taken != want:
            out.append(f"FAILED — the {regime} regime's camera took the route `{said}`, "
                       f"so the route under test is not the one measured")
    return out


def parse_launch(text):
    """dbus-launch --sh-syntax's address and pid."""
    env = {}
    for line in text.splitlines():
        line = line.strip().rstrip(";")
        if "=" not in line or line.startswith("export "):
            continue
        key, value = line.split("=", 1)
        env[key] = value.strip("'\"")
    return env.get("DBUS_SESSION_BUS_ADDRESS"), env.get("DBUS_SESSION_BUS_PID")


def ours(pid, marker):
    """Whether /proc/<pid> is one of this leg's: its environment names the
    leg's private directory."""
    try:
        environ = pathlib.Path(f"/proc/{pid}/environ").read_bytes()
    except OSError:
        return False
    return marker.encode() in environ


def leftovers(marker):
    out = []
    for proc in pathlib.Path("/proc").iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            comm = (proc / "comm").read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if comm in STACK and ours(proc.name, marker):
            out.append((int(proc.name), comm))
    return out


def wait_for(what, check, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return True
        time.sleep(0.05)
    say(f"{what} did not happen within {seconds}s")
    return False


def quiet(argv, env, timeout=10):
    try:
        done = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)
    return done.returncode, (done.stdout + done.stderr).strip()


def self_test():
    checks = 0
    failed = []

    def expect(label, got, want):
        nonlocal checks
        checks += 1
        if bool(got) != want:
            failed.append(f"{label}: wanted {'a finding' if want else 'none'}, got {got!r}")

    expect("portal regime, portal route", route_findings("portal", [ROUTE + "portal (granted)"]), False)
    expect("portal regime, direct route", route_findings("portal", [ROUTE + "direct (no camera portal answers)"]), True)
    expect("direct regime, portal route", route_findings("direct", [ROUTE + "portal (granted)"]), True)
    expect("portal regime, a denied portal", route_findings("portal", [ROUTE + "portal-denied (response 1)"]), True)
    expect("no route printed", route_findings("portal", ["KAYA_SELFTEST: OK"]), False)
    addr, pid = parse_launch("DBUS_SESSION_BUS_ADDRESS='unix:abstract=/tmp/x,guid=1';\n"
                             "export DBUS_SESSION_BUS_ADDRESS;\nDBUS_SESSION_BUS_PID=42;\n")
    checks += 1
    if (addr, pid) != ("unix:abstract=/tmp/x,guid=1", "42"):
        failed.append(f"parse_launch read {(addr, pid)!r}")
    for f in failed:
        say(f"SELF-TEST {f}")
    say(f"self-test: {checks} checks, {len(failed)} failed")
    return 1 if failed or checks < 6 else 0


def main(argv):
    if argv[1:2] == ["--self-test"]:
        return self_test()
    if len(argv) < 3 or argv[1] not in ("portal", "direct"):
        say("usage: capture-leg.py portal|direct <guest> [args...]")
        return 2
    regime, guest = argv[1], argv[2:]
    if not os.access(PWSYNTH, os.X_OK):
        say(f"no synthetic device program at {PWSYNTH} (run-suites.sh's build_pwsynth)")
        return 1
    home = pathlib.Path(tempfile.mkdtemp(prefix="kaya-capture-"))
    marker = str(home)
    runtime = home / "pipewire"
    runtime.mkdir(mode=0o700)
    env = dict(os.environ)
    env["PIPEWIRE_RUNTIME_DIR"] = str(runtime)
    env["DISABLE_RTKIT"] = "y"
    stack_env = dict(env)
    stack_env["XDG_STATE_HOME"] = str(home / "state")
    stack_env["XDG_DATA_HOME"] = str(home / "data")
    stack_env["XDG_CONFIG_HOME"] = str(home / "config")
    stack_env["KAYA_CAPTURE_LEG"] = marker
    dirs = env.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    if regime == "portal":
        dirs = f"{PORTAL_DIRS}:{dirs}"
    stack_env["XDG_DATA_DIRS"] = dirs
    env["KAYA_CAPTURE_LEG"] = marker
    logs = {}
    procs = []
    status = 1
    guest_lines = []
    findings = []
    bus_pid = None
    graph = deque(maxlen=GRAPH_KEEP)
    graph_stop = threading.Event()
    sampler = None

    def start(name, argv_, environ):
        log = open(home / f"{name}.log", "w", encoding="utf-8")
        logs[name] = home / f"{name}.log"
        p = subprocess.Popen(argv_, env=environ, stdout=log, stderr=subprocess.STDOUT)
        procs.append((name, p))
        return p

    try:
        code, said = quiet(["dbus-launch", "--sh-syntax"], stack_env)
        address, bus_pid = parse_launch(said)
        if code != 0 or not address:
            findings.append(f"FAILED — dbus-launch gave no bus: {said}")
            return 1
        for e in (env, stack_env):
            e["DBUS_SESSION_BUS_ADDRESS"] = address
        start("sessionmgr", [sys.executable, str(WORK / "tools/linux/sessionmgr.py")], stack_env)
        start("pipewire", ["pipewire"], stack_env)
        if not wait_for("PipeWire's socket", lambda: (runtime / "pipewire-0").exists(), 10):
            findings.append("FAILED — PipeWire never made its socket")
            return 1
        start("wireplumber", ["wireplumber"], stack_env)
        for kind, name, description, content in DEVICES:
            start(name, [PWSYNTH, kind, name, description, content], stack_env)

        def listed():
            code, said = quiet(["pw-cli", "ls", "Node"], stack_env)
            return code == 0 and all(f'node.name = "{d[1]}"' in said for d in DEVICES)

        def defaults():
            code, said = quiet(["pw-metadata", "-n", "default", "0"], stack_env)
            return code == 0 and "default.video.source" in said and "default.audio.source" in said

        if not (wait_for("the four synthetic nodes listed", listed, 15)
                and wait_for("WirePlumber's defaults", defaults, 15)):
            findings.append("FAILED — the lane's synthetic devices never stood up (the PipeWire section below)")
            return 1
        portal = quiet(["gdbus", "call", "--session", "--dest", "org.freedesktop.portal.Desktop",
                        "--object-path", "/org/freedesktop/portal/desktop", "--method",
                        "org.freedesktop.DBus.Properties.Get", "org.freedesktop.portal.Camera",
                        "IsCameraPresent"], stack_env, timeout=30)
        if regime == "portal":
            if portal[0] != 0 or "true" not in portal[1]:
                findings.append(f"FAILED — no camera portal answers IsCameraPresent true on this leg's bus: {portal[1]}")
                return 1
            grant = quiet(["gdbus", "call", "--session", "--dest", "org.freedesktop.impl.portal.PermissionStore",
                           "--object-path", "/org/freedesktop/impl/portal/PermissionStore", "--method",
                           "org.freedesktop.impl.portal.PermissionStore.SetPermission", "devices", "true",
                           "camera", "", "['yes']"], stack_env)
            if grant[0] != 0:
                findings.append(f"FAILED — the permission store refused the lane's camera grant: {grant[1]}")
                return 1
            say("regime portal: the camera portal answers IsCameraPresent true, the empty app id granted")
        else:
            if portal[0] == 0:
                findings.append(f"FAILED — a camera portal answered on the direct leg's bus: {portal[1]}")
                return 1
            say("regime direct: no camera portal on this leg's bus")
        # THE GRAPH WHILE THE GUEST RAN (docs/traps.md, the linux capture tone
        # read low): pw-top's per-node cycle, once a second, the last GRAPH_KEEP.
        def sample_graph():
            while not graph_stop.is_set():
                # The first of pw-top's iterations has measured nothing yet.
                code, said = quiet(["pw-top", "--batch-mode", "--iterations", "2"], stack_env)
                last = said[said.rfind("S   ID"):] if "S   ID" in said else said
                load = os.getloadavg()[0]
                graph.append(f"{time.strftime('%H:%M:%S')} load {load:.1f} (exit {code})\n{last}")
                graph_stop.wait(0.5)

        sampler = threading.Thread(target=sample_graph, daemon=True)
        sampler.start()
        guest_proc = subprocess.Popen(guest, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      text=True, errors="replace")
        for line in guest_proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            guest_lines.append(line)
        status = guest_proc.wait()
        routes = [line for line in guest_lines if ROUTE in line]
        findings.extend(route_findings(regime, guest_lines))
        say(f"{len(routes)} camera route(s) printed, every one checked against the {regime} regime")
        return status
    finally:
        graph_stop.set()
        if sampler is not None:
            sampler.join(15)
        if graph:
            print(f"--- pipewire graph while the guest ran (pw-top, last {len(graph)} of one a "
                  f"second) ---", file=sys.stderr)
            for snapshot in graph:
                print(snapshot, file=sys.stderr)
        print("--- pipewire (as the leg ended) ---", file=sys.stderr)
        for argv_ in (["pw-cli", "ls", "Node"], ["pw-cli", "ls", "Link"], ["pw-metadata", "-n", "default", "0"]):
            code, said = quiet(argv_, stack_env)
            print(f"$ {' '.join(argv_)} (exit {code})\n{said}", file=sys.stderr)
        for name, p in reversed(procs):
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
        for name, p in reversed(procs):
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
        if bus_pid:
            try:
                os.kill(int(bus_pid), signal.SIGTERM)
            except (OSError, ValueError):
                pass
        for name, path in logs.items():
            text = path.read_text(encoding="utf-8", errors="replace").strip()
            if text:
                print(f"--- {name} ---\n{text[-4000:]}", file=sys.stderr)
        left = []
        if not wait_for("this leg's processes gone", lambda: not leftovers(marker), 5):
            left = leftovers(marker)
            for pid, _ in left:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            wait_for("this leg's processes killed", lambda: not leftovers(marker), 5)
        remaining = leftovers(marker)
        if remaining:
            findings.append(f"FAILED — this leg's processes outlived it: {remaining}")
        else:
            say(f"stopped: {len(procs)} started, {len(left)} needed a kill, none of this leg's "
                f"processes remain ({', '.join(STACK[:3])}, the bus and the portal)")
        shutil.rmtree(home, ignore_errors=True)
        for f in findings:
            say(f)
        if findings and status == 0:
            status = 1
        sys.exit(status)


if __name__ == "__main__":
    main(sys.argv)
