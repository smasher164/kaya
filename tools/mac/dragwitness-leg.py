#!/usr/bin/env python3
"""The mac cross-app drag witness legs (docs/dnd-plan.md §5 step 7):

    tools/mac/dragwitness-leg.py out    kaya's declared source dragged OUT
                                        into a foreign AppKit window
    tools/mac/dragwitness-leg.py in     a foreign source's text and file
                                        dragged INTO kaya's targets

Both are REAL cross-process drags driven by a real pointer: the witness
(tools/mac/dragwitness/witness.swift, a process with nothing of kaya in it)
posts CGEvents from its `drive` mode, and AppKit composes a real
NSDraggingSession from them — measured 2026-09-03 (docs/probes/
dnd-witness-mac-2026-09-03.md, the evening addendum: the first verdict
was measured before the empty-item fix). kaya runs guests/rust/dnd.rs
under a scene written here: an in-process `drag` prints the geometry
instrument (KAYA_DIAG dragdrive: … in CGEvent's top-left coordinates), a
settle leaves the pointer time to walk, and the expect that follows waits
for the foreign gesture's own outcome. THE POINTER IS DESKTOP-GLOBAL.
NOT WIRED INTO THE LANE YET (2026-09-03 evening): on the maintainer's
desktop the release landed on the terminal rather than the witness window
placed beside kaya's, with the maintainer watching — the mechanics compose
(kaya's own source ended a session; `run.py --pair` lands 9 of 10) and
the AIM on a shared desktop is what is left. The mac half of §5 step 7 is
`tools/mac/dragwitness/run.py --hand` until this aims on an unattended
desktop.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

import os
import re
import signal
import subprocess
import tempfile
import threading
import time

sys.path.insert(0, str(ROOT / "tools/lib/lanes"))
import mac as lane  # noqa: E402

WITNESS_DIR = ROOT / "tools/mac/dragwitness"
BINARY = ROOT / "target/mac-dragwitness/kaya-drag-witness"
GUEST = ROOT / lane.RUST_GUESTS / "dnd"
# What the witness offers (witness.swift's own constants) and what kaya's
# guest reads back through the picked table.
WITNESS_TEXT = "kaya-foreign-text"
WITNESS_FILE = "witness.txt"
WITNESS_BYTES = "witness bytes"
GAP = 40
WITNESS_SIZE = (300, 200)
READY_S = 30.0
LANDING_S = 30.0
DIAG = re.compile(
    r"dragdrive: source \((-?\d+), (-?\d+), (\d+), (\d+)\) destination "
    r"\((-?\d+), (-?\d+), (\d+), (\d+)\) window \((-?\d+), (-?\d+), (\d+), (\d+)\) "
    r"screen \((\d+), (\d+)\)")


class LegError(Exception):
    pass


def out(line):
    print(f"dragwitness-leg: {line}", flush=True)


class Pump:
    def __init__(self, stream):
        self.lines = []
        self._stream = stream
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self._stream:
            self.lines.append(line.rstrip("\n"))

    def wait_for(self, needle, deadline_s, what, after=0):
        end = time.monotonic() + deadline_s
        while time.monotonic() < end:
            for line in list(self.lines)[after:]:
                if needle in line:
                    return line
            time.sleep(0.05)
        raise LegError(f"{what}: nothing carrying {needle!r} within {deadline_s:.0f}s. "
                       f"What it did say: {self.lines!r}")


def build_witness():
    got = subprocess.run([sys.executable, str(WITNESS_DIR / "run.py"), "--build"],
                         cwd=ROOT, check=False)
    if got.returncode != 0 or not BINARY.is_file():
        raise LegError("the witness did not build (tools/mac/dragwitness/run.py --build)")


def scene_for(direction):
    if direction == "out":
        return "\n".join([
            "# The mac OUT witness leg (tools/mac/dragwitness-leg.py): the in-process",
            "# drag below is the GEOMETRY INSTRUMENT (a refusal: label#3 takes files),",
            "# the settle leaves the real pointer time to walk, and the last expect",
            "# waits for the foreign window's own outcome.",
            'expect label#4 "no drop yet"',
            'expect label#5 "no drag yet"',
            "drag label#0 to label#3",
            'expect label#5 "drag ended none"',
            "settle 2500",
            'expect label#5 "drag ended copy"',
            "",
        ])
    return "\n".join([
        "# The mac IN witness leg (tools/mac/dragwitness-leg.py): two instrument",
        "# drags name label#1 and label#3 on the screen, then each expect waits",
        "# for a foreign source's real drop — its text, then its file.",
        'expect label#4 "no drop yet"',
        "drag label#0 to label#1",
        'expect label#4 "text target got text hello (copy)"',
        "drag label#0 to label#3",
        'expect label#5 "drag ended none"',
        "settle 2500",
        f'expect label#4 "text target got text {WITNESS_TEXT} (copy)"',
        "settle 2500",
        f'expect label#4 "files target got {WITNESS_FILE} {WITNESS_BYTES} (copy)"',
        "",
    ])


def centre(rect):
    x, y, w, h = rect
    return (x + w // 2, y + h // 2)


def witness_rect(window, screen):
    """A witness window beside kaya's, never over it: to the right where
    the screen has room, else to the left."""
    wx, wy, ww, wh = window
    sw, sh = screen
    w, h = WITNESS_SIZE
    x = wx + ww + GAP
    if x + w > sw:
        x = max(0, wx - GAP - w)
    y = min(max(0, wy), max(0, sh - h))
    return (x, y, w, h)


def drive(press, to):
    got = subprocess.run(
        [str(BINARY), "drive", "--press", f"{press[0]},{press[1]}",
         "--to", f"{to[0]},{to[1]}", "--settle", "150"],
        check=False, capture_output=True, text=True, encoding="utf-8")
    out(f"drove {press} -> {to} (exit {got.returncode})")
    if got.returncode != 0:
        raise LegError(f"the witness driver failed: {got.stdout} {got.stderr}")


def stop(child, what):
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
    out(f"{what} (pid {child.pid}) exited {child.returncode}")


def prove_gone(report):
    r = subprocess.run(["ps", "-Ao", "pid,ppid,etime,args"], capture_output=True,
                       text=True, encoding="utf-8", check=False)
    left = [line for line in r.stdout.splitlines()
            if "kaya-drag-witness" in line and str(report.parent) in line]
    out(f"witness processes still running: {len(left)}"
        + ("".join(f"\n  {line}" for line in left) if left else " (none)"))
    if left:
        raise LegError(f"{len(left)} witness process(es) outlived the leg: {left!r}")


def run(direction):
    build_witness()
    if not GUEST.is_file():
        raise LegError(f"{GUEST} is not staged — tools/run-leg.py dnd rust --build stages it")
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="kaya-dragwitness-"))
    scenes = scratch / "scenes"
    scenes.mkdir()
    (scenes / "dnd.steps").write_text(scene_for(direction), encoding="utf-8")
    out(f"the scene this leg runs:\n{scene_for(direction)}")
    offered = scratch / WITNESS_FILE
    offered.write_text(WITNESS_BYTES, encoding="utf-8")
    report = scratch / "witness-report.txt"

    env = dict(os.environ)
    env.update(lane.leg_env(ROOT, "dnd", "rust", ""))
    # The mac lane hands a leg its script as TEXT (mac.py's leg_env), so
    # the scratch scene rides the same variable rather than a directory.
    env["KAYA_SELFTEST"] = "dnd"
    env["KAYA_SELFTEST_SCRIPT"] = scene_for(direction)
    kaya = subprocess.Popen(lane.leg_argv("dnd", "rust", lambda _n: ""), cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8")
    kaya_said = Pump(kaya.stdout)
    witnesses = []
    observed = []
    try:
        # The FIRST instrument line names label#0 (the source) and, for
        # the in leg, label#1; the second names label#3 and kaya's window.
        first = kaya_said.wait_for("dragdrive: source", READY_S, "kaya's geometry instrument")
        m1 = DIAG.search(first)
        if not m1:
            raise LegError(f"the instrument line did not parse: {first!r}")
        g = [int(v) for v in m1.groups()]
        source, dest1, window, screen = tuple(g[0:4]), tuple(g[4:8]), tuple(g[8:12]), tuple(g[12:14])
        out(f"kaya's window {window} on a {screen} screen; label#0 {source}")
        rect = witness_rect(window, screen)
        at = ",".join(str(v) for v in rect)
        if direction == "out":
            catch = subprocess.Popen(
                [str(BINARY), "catch", "--at", at, "--report", str(report)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                encoding="utf-8", start_new_session=True)
            witnesses.append(catch)
            said = Pump(catch.stdout)
            said.wait_for("visible true", READY_S, "the witness catch window")
            drive(centre(source), centre(rect))
            kaya_said.wait_for('"drag ended copy"', LANDING_S, "kaya's drag_ended")
            catch.wait(timeout=LANDING_S)
            got = report.read_text(encoding="utf-8") if report.is_file() else ""
            out(f"witness said:\n{got}")
            for need in ("entered local false", "text hello", "custom dev.kaya/note 5 bytes"):
                if need not in got:
                    raise LegError(f"the witness did not report {need!r}; it said {got!r}")
                observed.append(need)
        else:
            second = kaya_said.wait_for("dragdrive: source", READY_S,
                                        "kaya's second instrument line", after=1)
            m2 = DIAG.search(second)
            if not m2:
                raise LegError(f"the second instrument line did not parse: {second!r}")
            dest3 = tuple(int(v) for v in m2.groups()[4:8])
            out(f"label#1 {dest1}, label#3 {dest3}")
            for target, need in ((dest1, f"text {WITNESS_TEXT}"),
                                 (dest3, f"files target got {WITNESS_FILE}")):
                throw = subprocess.Popen(
                    [str(BINARY), "throw", "--at", at, "--file", str(offered),
                     "--report", str(report)],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                    encoding="utf-8", start_new_session=True)
                witnesses.append(throw)
                said = Pump(throw.stdout)
                said.wait_for("visible true", READY_S, "the witness throw window")
                drive(centre(rect), centre(target))
                kaya_said.wait_for(need, LANDING_S, "kaya's drop")
                throw.wait(timeout=LANDING_S)
                got = report.read_text(encoding="utf-8") if report.is_file() else ""
                out(f"witness said:\n{got}")
                if "drag ended copy" not in got:
                    raise LegError(f"the witness's drag did not end in copy; it said {got!r}")
                observed.append(need)
        verdict = kaya_said.wait_for("KAYA_SELFTEST:", LANDING_S, "kaya's verdict")
        kaya.wait(timeout=30)
    finally:
        for w in witnesses:
            stop(w, "a witness")
        if kaya.poll() is None:
            kaya.terminate()
            kaya.wait(timeout=10)
        for line in kaya_said.lines:
            out(f"kaya said: {line}")
        prove_gone(report)
    if "KAYA_SELFTEST: OK" not in verdict or kaya.returncode != 0:
        raise LegError(f"kaya's own verdict: {verdict} (exit {kaya.returncode})")
    print(f"KAYA_SELFTEST: OK (foreign {direction}: " + ", ".join(observed) + ")", flush=True)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("out", "in"):
        print("usage: tools/mac/dragwitness-leg.py out|in", file=sys.stderr)
        sys.exit(2)
    try:
        run(sys.argv[1])
    except LegError as e:
        print(f"KAYA_SELFTEST: FAILED ({e})", flush=True)
        sys.exit(1)


main()
