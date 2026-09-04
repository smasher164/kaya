#!/usr/bin/env python3
"""The mac cross-app drag FEASIBILITY leg (docs/dnd-plan.md §5 step 7):

    tools/mac/dragwitness-leg.py in     drive a foreign drag onto kaya's
                                        live targets, safely, unattended
    tools/mac/dragwitness-leg.py out    HAND ONLY — see below

`in` DRIVES A REAL CROSS-PROCESS DRAG ONTO KAYA'S LIVE DROP TARGETS and is
safe to run on the maintainer's own desktop: it proves a foreign
NSDraggingSession composes and walks a real pointer from a foreign window
(tools/mac/dragwitness/witness.swift, a process with nothing of kaya in
it) onto the coordinates kaya's own geometry instrument reports for its
text and files targets. That the drag CAN be driven here refutes the
probe's first verdict of "undrivable" (measured before the
empty-pasteboard-item fix; docs/probes/dnd-witness-mac-2026-09-03.md);
`run.py --pair` proves the same gesture carries a full payload
witness-to-witness.

WHAT THIS LEG DOES NOT ASSERT — kaya's RECEIPT of the payload. Under
synthetic input a SwiftUI destination reads the foreign drag pasteboard
back EMPTY (`board.string(.string)` returns "" in kaya where the same call
in a plain-AppKit catch returns the full text, and where a real human drag
into kaya reads it whole), so kaya cannot be made to confirm the bytes by
a driven gesture. That confirmation is `run.py --hand`'s: a person drags,
and kaya's own harness reads the text and file back through its picked
table (both measured 2026-09-03, docs/traps.md). So this leg drives and
proves the gesture reaches kaya's targets; the hand run proves kaya reads
what lands.

`out` (kaya's own source dragged into a foreign window) is HAND ONLY: a
synthetic mouseDown does not reach kaya's drag-source view — it is a
SwiftUI `.background` the drag manager finds as a DESTINATION but a press
does not route to — so the source cannot be driven here. `run.py --hand`
step 3 drives it with a real mouse instead.

THE POINTER IS DESKTOP-GLOBAL, so the driver is walled: kaya runs with
KAYA_WINDOW_FRONT=1 (an accessory app's window opens BEHIND the terminal
that launched it, and the first run pressed on the terminal instead — the
coordinates were right and the window under them was not), which floats
kaya's window and prints its pid and frame; the witness is placed in the
free strip beside it; and the driver refuses to press or release on a
window any other process owns, releasing back at the press point. NOT IN
THE MATRIX: a real pointer on every run is a ruling, not a wiring.
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
FRONT = re.compile(r"windowfront wid=0 pid=(\d+) frame=(-?\d+),(-?\d+),(\d+),(\d+) screen=(\d+),(\d+)")


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

    def wait_for(self, needle, deadline_s, what, skip=0):
        """The first line carrying `needle`, or the one after `skip` earlier
        matches — a line INDEX cannot do this, since the diag lines before
        the first match are not counted by anyone."""
        end = time.monotonic() + deadline_s
        while time.monotonic() < end:
            hits = [line for line in list(self.lines) if needle in line]
            if len(hits) > skip:
                return hits[skip]
            time.sleep(0.05)
        raise LegError(f"{what}: nothing carrying {needle!r} within {deadline_s:.0f}s. "
                       f"What it did say: {self.lines!r}")


def build_witness():
    got = subprocess.run([sys.executable, str(WITNESS_DIR / "run.py"), "--build"],
                         cwd=ROOT, check=False)
    if got.returncode != 0 or not BINARY.is_file():
        raise LegError("the witness did not build (tools/mac/dragwitness/run.py --build)")


SETTLE_MS = 15000  # the window each foreign throw is driven inside; the leg
                   # launches, aims and releases well within it.


def scene_for():
    # kaya holds its window up and prints the geometry instrument for the two
    # targets (label#1 text, label#3 files) so the leg can aim a real pointer
    # at them. There are no foreign expects: kaya's RECEIPT of a driven drop
    # is not asserted here (it reads empty under synthetic input — see the
    # module docstring and docs/traps.md), so the scene is a clean hold.
    return "\n".join([
        'expect label#4 "no drop yet"',
        "drag label#0 to label#1",
        "drag label#0 to label#3",
        f"settle {SETTLE_MS}",
        f"settle {SETTLE_MS}",
        "",
    ])


def centre(rect):
    x, y, w, h = rect
    return (x + w // 2, y + h // 2)


def witness_rect(window, screen):
    """A witness window beside kaya's, never over it, at its vertical
    middle: to the left where the screen has room, else to the right, else
    below."""
    wx, wy, ww, wh = window
    sw, sh = screen
    w, h = WITNESS_SIZE
    if wx >= w + GAP:
        x, y = wx - GAP - w, wy + wh // 2 - h // 2
    elif sw - (wx + ww) >= w + GAP:
        x, y = wx + ww + GAP, wy + wh // 2 - h // 2
    else:
        x, y = max(0, min(wx, sw - w)), wy + wh + GAP
    return (x, max(0, y), w, h)


def drive(press, to, press_owner, to_owner):
    got = subprocess.run(
        [str(BINARY), "drive", "--press", f"{press[0]},{press[1]}",
         "--to", f"{to[0]},{to[1]}", "--press-owner", str(press_owner),
         "--to-owner", str(to_owner), "--settle", "150"],
        check=False, capture_output=True, text=True, encoding="utf-8")
    out(f"drove {press} (pid {press_owner}) -> {to} (pid {to_owner}) (exit {got.returncode})")
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


def run():
    build_witness()
    if not GUEST.is_file():
        raise LegError(f"{GUEST} is not staged — tools/run-leg.py dnd rust --build stages it")
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="kaya-dragwitness-"))
    scenes = scratch / "scenes"
    scenes.mkdir()
    (scenes / "dnd.steps").write_text(scene_for(), encoding="utf-8")
    out(f"the scene this leg runs:\n{scene_for()}")
    offered = scratch / WITNESS_FILE
    offered.write_text(WITNESS_BYTES, encoding="utf-8")
    report = scratch / "witness-report.txt"

    env = dict(os.environ)
    env.update(lane.leg_env(ROOT, "dnd", "rust", ""))
    # The mac lane hands a leg its script as TEXT (mac.py's leg_env), so
    # the scratch scene rides the same variable rather than a directory.
    env["KAYA_SELFTEST"] = "dnd"
    env["KAYA_SELFTEST_SCRIPT"] = scene_for()
    env["KAYA_WINDOW_FRONT"] = "1"
    kaya = subprocess.Popen(lane.leg_argv("dnd", "rust", lambda _n: ""), cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8")
    kaya_said = Pump(kaya.stdout)
    witnesses = []
    observed = []
    try:
        # The FIRST instrument line names label#0 (the source) and, for
        # the in leg, label#1; the second names label#3 and kaya's window.
        front = kaya_said.wait_for("windowfront wid=0 ", READY_S, "kaya's windowfront line")
        mf = FRONT.search(front)
        if not mf:
            raise LegError(f"the windowfront line did not parse: {front!r}")
        f = [int(v) for v in mf.groups()]
        kaya_pid, window, screen = f[0], tuple(f[1:5]), tuple(f[5:7])
        first = kaya_said.wait_for("dragdrive: source", READY_S, "kaya's geometry instrument")
        m1 = DIAG.search(first)
        if not m1:
            raise LegError(f"the instrument line did not parse: {first!r}")
        g = [int(v) for v in m1.groups()]
        source, dest1 = tuple(g[0:4]), tuple(g[4:8])
        out(f"kaya's window {window} (pid {kaya_pid}) on a {screen} screen; label#0 {source}")
        rect = witness_rect(window, screen)
        at = ",".join(str(v) for v in rect)
        second = kaya_said.wait_for("dragdrive: source", READY_S,
                                    "kaya's second instrument line", skip=1)
        m2 = DIAG.search(second)
        if not m2:
            raise LegError(f"the second instrument line did not parse: {second!r}")
        dest3 = tuple(int(v) for v in m2.groups()[4:8])
        out(f"label#1 {dest1}, label#3 {dest3} (witness at {rect})")
        # kaya settles once before each foreign expect. The leg waits for the
        # Nth settle announcement (that also confirms the previous expect
        # passed — kaya would have died on it otherwise), launches a fresh
        # foreign source, drives it onto the target INSIDE that window, and
        # lets kaya check the drop when the settle expires. The verdict is
        # kaya's alone; a per-throw wait on kaya's own line would match its
        # ECHO of the pending step, not its pass, and fire the next throw
        # early (measured 2026-09-03).
        throws = [(dest1, "onto kaya's text target"), (dest3, "onto kaya's files target")]
        for i, (target, what) in enumerate(throws):
            # Drive each throw inside one of kaya's settle windows; the leg is
            # well within the settle, so the timing is not tight.
            kaya_said.wait_for(f"settle {SETTLE_MS}", LANDING_S,
                               f"kaya's settle window {i + 1}", skip=i)
            report.unlink(missing_ok=True)
            throw = subprocess.Popen(
                [str(BINARY), "throw", "--at", at, "--file", str(offered),
                 "--report", str(report)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                encoding="utf-8", start_new_session=True)
            witnesses.append(throw)
            said = Pump(throw.stdout)
            said.wait_for("visible true", READY_S, "the witness throw window")
            drive(centre(rect), centre(target), throw.pid, kaya_pid)
            throw.wait(timeout=LANDING_S)
            got = report.read_text(encoding="utf-8") if report.is_file() else ""
            # The proof: a REAL cross-process NSDraggingSession composed in the
            # foreign process and concluded, its pointer walked by the driver
            # from the witness window onto the coordinate kaya reported for
            # this target. kaya's RECEIPT of the bytes is not assertable under
            # synthetic input and is the hand run's job (module docstring).
            for marker in ("session began", "drag ended"):
                if marker not in got:
                    raise LegError(f"the foreign drag {what} did not compose a real "
                                   f"session — its report lacked {marker!r}: {got!r}")
            ended = next((line for line in got.splitlines()
                          if line.startswith("drag ended")), "drag ended <silent>")
            out(f"drove a real foreign drag {what}: the session composed and {ended}")
            observed.append(what)
        # kaya's own verdict is informational: it held its window and printed
        # the geometry the drives used. It cannot confirm the payload here.
        verdict = kaya_said.wait_for("KAYA_SELFTEST:", LANDING_S, "kaya's verdict")
        out(f"kaya (informational, receipt not asserted): {verdict}")
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
    # Feasibility is proven by the two composed cross-process drags onto
    # kaya's live targets, not by kaya's verdict (which cannot see the
    # payload under synthetic input; run.py --hand asserts receipt).
    print("KAYA_SELFTEST: OK (drove real foreign drags " + "; ".join(observed)
          + "; receipt is run.py --hand's — docs/traps.md)", flush=True)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("out", "in"):
        print("usage: tools/mac/dragwitness-leg.py in|out", file=sys.stderr)
        sys.exit(2)
    if sys.argv[1] == "out":
        # kaya's drag-source is a SwiftUI .background; a synthetic mouseDown
        # does not route to it, so kaya cannot be driven as a source here
        # (docs/traps.md). The hand run drives it with a real mouse instead.
        print("dragwitness-leg out: HAND ONLY — kaya's source view takes no "
              "synthetic press; run `tools/mac/dragwitness/run.py --hand` step 3 "
              "to drag OUT of kaya with a real mouse.", flush=True)
        sys.exit(2)
    try:
        run()
    except LegError as e:
        print(f"KAYA_SELFTEST: FAILED ({e})", flush=True)
        sys.exit(1)


main()
