#!/usr/bin/env python3
"""Photograph a mac leg's menus drawn open, from the real menu bar.

    tools/mac/menu-shot.py <scene> <lang> <steps> <outdir> <menu>...

<steps> is a file of harness steps ending in a `settle` long enough to
shoot in (under run-leg's 120 s); each <menu> is a top-level title
("Format"), a title and one submenu item ("Format>Paragraph Style"), or a
menu bar position ("#5", for a bar that carries two menus of one title).

The guests run `.accessory`, which has NO MENU BAR, so no menu of theirs
can be drawn open; the leg runs with KAYA_WINDOW_FRONT=regular, which
raises the interpreter to `.regular` and activates it. The picture is
composed from the guest's OWN windows, each shot by id (`screencapture
-l`), on a neutral background: the app window and its open menus. The
menu bar strip is the Window Server's, so it is not in the picture. Before
any image is written, every window id is checked against an unfiltered
window list, and one owned by another pid refuses the shot. HOST UI: it
refuses while the host has seen input in the last 20 s that was not its
own.
"""
import contextlib
import fcntl
import os
import pathlib
import re
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

import flightrec_lane

if len(sys.argv) < 6:
    print(__doc__, file=sys.stderr)
    sys.exit(2)
scene, lang, steps, outdir, *menus = sys.argv[1:]
outdir = pathlib.Path(outdir)
outdir.mkdir(parents=True, exist_ok=True)
WIDTH, HEIGHT, BAR = 900, 560, 33
IDLE_FLOOR = 20.0
SHOT_TURN = "/tmp/kaya-screencapture.lock"
winlist = flightrec_lane.winlist_bin(ROOT)
compose = flightrec_lane.mac_tool_bin(ROOT, "menu-compose")
if winlist is None or compose is None:
    print("menu-shot: tools/mac/flightrec-winlist.swift or menu-compose.swift would not build",
          file=sys.stderr)
    sys.exit(1)

last_event = [0.0]


def own_windows(pid):
    """The pid's on-screen windows, back to front: (id, layer, x, y, w, h)."""
    listed = subprocess.run([winlist, str(pid)], capture_output=True, text=True,
                            check=False).stdout
    got = []
    for m in re.finditer(r"^win=(\d+) pid=(\d+) layer=(-?\d+) bounds=(-?\d+),(-?\d+),(\d+),(\d+) ",
                         listed, re.M):
        win, owner, layer, x, y, w, h = map(int, m.groups())
        if owner == pid and w > 1 and h > 1:
            got.append((win, layer, x, y, w, h))
    return got[::-1]


def shoot(pid, out):
    wins = own_windows(pid)
    if not wins:
        print(f"menu-shot: {out.name}: pid {pid} has no window on screen; nothing shot",
              file=sys.stderr)
        return False
    everyone = subprocess.run([winlist], capture_output=True, text=True, check=False).stdout
    foreign = flightrec_lane.foreign_windows([w[0] for w in wins], everyone, pid)
    if foreign:
        print(f"menu-shot: {out.name} REFUSED, a window to compose is not pid {pid}'s: "
              + "; ".join(foreign), file=sys.stderr)
        return False
    with tempfile.TemporaryDirectory(prefix="menu-shot-") as tmp:
        argv = [compose, str(out)]
        with open(SHOT_TURN, "a", encoding="utf-8") as turn:
            fcntl.flock(turn, fcntl.LOCK_EX)
            for win, _layer, x, y, w, h in wins:
                part = pathlib.Path(tmp) / f"{win}.png"
                subprocess.run(["screencapture", "-x", "-o", f"-l{win}", str(part)], check=False)
                if not part.is_file() or not part.stat().st_size:
                    print(f"menu-shot: {out.name}: screencapture -l{win} took no picture",
                          file=sys.stderr)
                    return False
                argv += [str(part), str(x), str(y), str(w), str(h)]
        made = subprocess.run(argv, capture_output=True, text=True, check=False)
    if made.returncode != 0:
        print(f"menu-shot: {made.stdout.strip()}", file=sys.stderr)
        out.unlink(missing_ok=True)
        return False
    menus = sum(1 for w in wins if w[1] == 101)
    print(f"menu-shot: {out}: windows {', '.join(str(w[0]) for w in wins)} of pid {pid} "
          f"({menus} menu window(s)), no other window", flush=True)
    return True


def host_idle():
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True,
                         check=False).stdout
    m = re.search(r'"HIDIdleTime" = (\d+)', out)
    return int(m.group(1)) / 1e9 if m else 0.0


def host_free():
    """Idle for the floor, or since our own last synthetic event."""
    ours = time.time() - last_event[0]
    return host_idle() >= min(IDLE_FLOOR, ours - 1.5)


def osa(script, wait=True):
    last_event[0] = time.time()
    argv = ["osascript", "-e", f'tell application "System Events" to {script}']
    if not wait:
        subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 0, ""
    got = subprocess.run(argv, capture_output=True, text=True, timeout=20, check=False)
    return got.returncode, (got.stdout + got.stderr).strip()


if host_idle() < IDLE_FLOOR:
    print(f"menu-shot: the host saw input {host_idle():.1f}s ago; refusing to drive its UI",
          file=sys.stderr)
    sys.exit(3)

env = dict(os.environ, KAYA_WINDOW_FRONT="regular",
           KAYA_SELFTEST_SCRIPT=pathlib.Path(steps).read_text(encoding="utf-8"))
log = outdir / "leg.log"
with open(log, "w", encoding="utf-8") as lf:
    proc = subprocess.Popen([str(ROOT / "tools/run-leg.py"), scene, lang], cwd=ROOT, env=env,
                            stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
pid = None
shots = 0
try:
    deadline = time.time() + 900
    while time.time() < deadline:
        text = log.read_text(encoding="utf-8", errors="replace")
        found = re.search(r"windowfront wid=\S+ pid=(\d+)", text)
        if found:
            pid = int(found.group(1))
        if pid and re.search(r"KAYA_HARNESS: \+\d+ms settle", text):
            break
        if proc.poll() is not None:
            print("menu-shot: the leg exited before its settle:\n" + text[-3000:], file=sys.stderr)
            sys.exit(1)
        time.sleep(0.5)
    else:
        print("menu-shot: no settle within 900 s", file=sys.stderr)
        sys.exit(1)
    app = f"(first process whose unix id is {pid})"
    osa(f"set frontmost of {app} to true")
    osa(f"tell {app} to set position of window 1 to {{0, {BAR}}}")
    osa(f"tell {app} to set size of window 1 to {{{WIDTH}, {HEIGHT}}}")
    time.sleep(1.0)
    for spec in menus:
        if not host_free():
            print(f"menu-shot: the host saw someone else's input ({host_idle():.1f}s); stopping",
                  file=sys.stderr)
            break
        parts = spec.split(">")
        bar = (f"menu bar item {parts[0][1:]} of menu bar 1" if parts[0].startswith("#")
               else f'menu bar item "{parts[0]}" of menu bar 1')
        osa(f"set frontmost of {app} to true")
        time.sleep(0.4)
        osa(f"tell {app} to click {bar}", wait=False)
        time.sleep(1.2)
        if len(parts) > 1:
            rc, said = osa(f'tell {app} to click menu item "{parts[1]}" of menu 1 of {bar}')
            if rc != 0:
                print(f"menu-shot: {spec}: {said}", file=sys.stderr)
            time.sleep(1.0)
        name = re.sub(r"[^a-z0-9]+", "-", spec.lower()).strip("-")
        out = outdir / f"menu-{name}.png"
        if shoot(pid, out):
            shots += 1
        osa("key code 53")
        time.sleep(0.3)
        osa("key code 53")
        time.sleep(0.6)
finally:
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
    if pid:
        with contextlib.suppress(ProcessLookupError):
            os.kill(pid, signal.SIGTERM)
print(f"menu-shot: {shots} of {len(menus)} shot; view each before publishing it")
sys.exit(0 if shots == len(menus) else 1)
