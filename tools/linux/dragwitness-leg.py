#!/usr/bin/env python3
"""ONE CROSS-APP DRAG, DRIVEN BY A REAL POINTER (docs/dnd-plan.md D9,
§5 step 7).

    dragwitness-leg.py (wayland|x11) (out|in) <kaya guest command...>

`out` presses on kaya's declared source and releases over the foreign
witness's drop target; `in` presses on the witness's source and releases
over kaya's files target. BOTH ENDS ARE READ, because a drag that reaches
neither app reads exactly like a drag the other side refused: the witness
speaks on its own stdout, and kaya answers with its own harness verdict.

WHERE KAYA'S PIXELS ARE — THE HARNESS SAYS SO ITSELF. The scene this leg
writes opens with `drag label#0 to label#3`, an in-app drag the guest
refuses (label#3 takes files, label#0 offers text), and the verb prints the
screen points it pressed and released:

    KAYA_DIAG dragdrive: x11 content at (5, 5) (surface transform (5, 5));
    pressed (55, 77), released (73, 161)

which are exactly the two widgets this leg needs — kaya's source and kaya's
files target — measured by the instrument that already knows the window's
origin and its CSD shadow. Nothing here re-derives either. (AT-SPI was
tried first and cannot serve: its SCREEN extents are 0,0 for every widget
on both protocols, and its WINDOW extents sit 26px off the widget's real
place in kaya's window — measured 2026-09-03, docs/traps.md.)

THE SCENE IS GENERATED, into a KAYA_SCENES_DIR of this leg's own, and it is
NOT a tools/scenes script: a foreign drop lands whenever the pointer gets
there, and every step of the shared dnd scene asserts the same two labels,
so a drop arriving mid-scene would redden it. A shared scene is not
available either — check-steps requires every tools/scenes/*.steps to have
a leg on all five lanes, and no other lane has this witness. The harness
parses what is written here and refuses an unknown verb, so a typo is a red
leg rather than a quiet pass.

Runs INSIDE the container under a leg's environment; no dev-shell prelude,
like the other in-container python here.
"""
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from dragdrive import DragDriveError, default_injector, injector_argv

# kaya's own declared payload, out of guests/rust/dnd.rs, and what this leg
# hands the witness.
KAYA_PAYLOAD_TEXT = "hello"
WITNESS_TEXT = "witness says hello"
WITNESS_FILE = "witness.txt"
WITNESS_BYTES = "witness bytes"
READY_DEADLINE_S = 40.0
LANDING_DEADLINE_S = 40.0
# The gap left between the two windows when the witness is placed, and the
# output both pools run at (tools/linux/run-suites.sh pins both servers).
GAP = 40
SCREEN = (1600, 1000)
DIAG = re.compile(r"pressed \((-?\d+), (-?\d+)\), released \((-?\d+), (-?\d+)\)")


def out(line):
    print(f"dragwitness-leg: {line}", flush=True)


class Pump:
    """A child's output, read as it arrives so a wait can watch for a line."""

    def __init__(self, stream):
        self.lines = []
        self._stream = stream
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self._stream:
            self.lines.append(line.rstrip("\n"))

    def wait_for(self, needle, deadline_s, what):
        end = time.monotonic() + deadline_s
        while time.monotonic() < end:
            for line in list(self.lines):
                if needle in line:
                    return line
            time.sleep(0.05)
        raise DragDriveError(
            f"{what}: nothing carrying {needle!r} within {deadline_s:.0f}s. "
            f"What it did say: {self.lines!r}")


# --- the two windows -------------------------------------------------

def x11_window_of(pid):
    """(id, (x, y, w, h)) of a pid's largest X window, or None."""
    ids = subprocess.run(["xdotool", "search", "--pid", str(pid)],
                         capture_output=True, text=True, encoding="utf-8",
                         check=False).stdout.split()
    best = None
    for wid in ids:
        geo = subprocess.run(["xdotool", "getwindowgeometry", "--shell", wid],
                             capture_output=True, text=True, encoding="utf-8",
                             check=False).stdout
        f = dict(line.split("=", 1) for line in geo.split() if "=" in line)
        try:
            box = (int(f["X"]), int(f["Y"]), int(f["WIDTH"]), int(f["HEIGHT"]))
        except (KeyError, ValueError):
            continue
        if best is None or box[2] * box[3] > best[1][2] * best[1][3]:
            best = (wid, box)
    return best


def wayland_box(pid):
    """(x, y, w, h) of a pid's toplevel CONTENT, sway's own answer."""
    r = subprocess.run(["swaymsg", "-t", "get_tree"], capture_output=True,
                       text=True, encoding="utf-8", check=False)
    if r.returncode != 0:
        raise DragDriveError(f"swaymsg -t get_tree failed: {r.stderr.strip()}")

    def walk(node):
        if node.get("pid") == pid and node.get("app_id"):
            rect, win = node["rect"], node["window_rect"]
            return (rect["x"] + win["x"], rect["y"] + win["y"],
                    win["width"], win["height"])
        for child in node.get("nodes", []) + node.get("floating_nodes", []):
            hit = walk(child)
            if hit:
                return hit
        return None

    return walk(json.loads(r.stdout))


def window_box(proto, pid):
    if proto == "wayland":
        return wayland_box(pid)
    found = x11_window_of(pid)
    return None if found is None else found[1]


def wait_for_window(proto, pid, what):
    end = time.monotonic() + READY_DEADLINE_S
    while time.monotonic() < end:
        box = window_box(proto, pid)
        if box is not None:
            return box
        time.sleep(0.1)
    raise DragDriveError(
        f"{what}: the {proto} server showed no window for pid {pid} within "
        f"{READY_DEADLINE_S:.0f}s")


def clear_of(kaya_box, witness_box):
    """Where to put the witness so the two windows do not overlap — right of
    kaya's if the output has room, else below it. With no window manager on
    x11 both toplevels map at the origin, and sway floats both of them
    centred, so on either protocol they start on top of each other and the
    press would go through the wrong window."""
    kx, ky, kw, kh = kaya_box
    _, _, ww, wh = witness_box
    if kx + kw + GAP + ww <= SCREEN[0]:
        return (kx + kw + GAP, ky)
    if ky + kh + GAP + wh <= SCREEN[1]:
        return (kx, ky + kh + GAP)
    raise DragDriveError(
        f"a {SCREEN[0]}x{SCREEN[1]} output has no room beside kaya's "
        f"{kaya_box} for the witness's {witness_box}")


def place(proto, pid, at):
    if proto == "wayland":
        r = subprocess.run(
            ["swaymsg", f"[pid={pid}]", "move", "position",
             str(at[0]), str(at[1])],
            capture_output=True, text=True, encoding="utf-8", check=False)
        if r.returncode != 0:
            raise DragDriveError(
                f"swaymsg move position failed: {r.stderr.strip()}")
        return
    found = x11_window_of(pid)
    if found is None:
        raise DragDriveError(f"the x11 server shows no window for pid {pid}")
    subprocess.run(["xdotool", "windowmove", found[0], str(at[0]), str(at[1])],
                   check=False)


def witness_origin(proto, pid, transform):
    """The witness's CONTENT origin on screen. sway reports the xdg window
    geometry, which IS the content; the x11 toplevel is the SURFACE, and the
    witness prints its own surface transform for exactly this sum —
    tools/linux/dragdrive.py's own division of the two servers."""
    box = window_box(proto, pid)
    if box is None:
        raise DragDriveError(f"the {proto} server lost the witness's window")
    if proto == "wayland":
        return (box[0], box[1])
    return (box[0] + transform[0], box[1] + transform[1])


# --- the leg ----------------------------------------------------------

SCENE_HEAD = """\
# GENERATED by tools/linux/dragwitness-leg.py — the cross-app witness leg's
# own scene, never a shared one (that file's docstring says why).
expect label#4 "no drop yet"
expect label#5 "no drag yet"
# The geometry instrument, and a refusal worth having on its own: label#3
# takes files and label#0 offers text, so this drag leaves both status
# labels alone while its KAYA_DIAG line says where the two widgets are.
drag label#0 to label#3
expect label#5 "drag ended none"
"""
# The foreign gesture lands during this last expect's own retry window
# (crates/kaya/src/harness.rs POLL_DEADLINE).
SCENE_TAIL = {
    "in": 'expect label#4 "files target got {file} {bytes} (copy)"\n',
    "out": 'expect label#5 "drag ended copy"\n',
}


def scene_for(direction, scenes_dir):
    text = SCENE_HEAD + SCENE_TAIL[direction].format(
        file=WITNESS_FILE, bytes=WITNESS_BYTES)
    (scenes_dir / "dnd.steps").write_text(text, encoding="utf-8")
    return text


def run(proto, direction, kaya_cmd):
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="kaya-dragwitness-"))
    offered = scratch / WITNESS_FILE
    offered.write_text(WITNESS_BYTES, encoding="utf-8")
    scenes = scratch / "scenes"
    scenes.mkdir()
    out(f"the scene this leg runs:\n{scene_for(direction, scenes)}")

    here = pathlib.Path(__file__).resolve().parent
    # ITS OWN SESSION, so the stop below reaches everything the witness
    # forks: under the matrix a same-argv child of it outlived a terminate
    # aimed at the parent alone (docs/traps.md: A witness census that counted every witness).
    witness = subprocess.Popen(
        [sys.executable, str(here / "dragwitness.py"),
         "--text", WITNESS_TEXT, "--file", str(offered)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        encoding="utf-8", start_new_session=True)
    env = dict(os.environ)
    env["KAYA_SELFTEST"] = "dnd"
    env["KAYA_SCENES_DIR"] = str(scenes)
    kaya = subprocess.Popen(kaya_cmd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8")
    witness_said = Pump(witness.stdout)
    kaya_said = Pump(kaya.stdout)
    try:
        drive(proto, direction, witness, witness_said, kaya, kaya_said)
    finally:
        for line in witness_said.lines:
            out(f"witness said: {line}")
        for line in kaya_said.lines:
            out(f"kaya said: {line}")
        stop(witness, "the witness", group=True)
        stop(kaya, "kaya")
        prove_gone(offered)


def drive(proto, direction, witness, witness_said, kaya, kaya_said):
    geometry = witness_said.wait_for("geometry", READY_DEADLINE_S,
                                     "the witness")
    fields = dict(part.split("=", 1) for part in geometry.split()[2:])
    transform = (int(fields["tx"]), int(fields["ty"]))
    rects = {k: tuple(int(v) for v in fields[k].split(","))
             for k in ("source", "target")}
    witness_said.wait_for("ready", READY_DEADLINE_S, "the witness")

    box = wait_for_window(proto, witness.pid, "the witness")
    kaya_box = wait_for_window(proto, kaya.pid, "kaya")
    place(proto, witness.pid, clear_of(kaya_box, box))
    time.sleep(0.5)
    origin = witness_origin(proto, witness.pid, transform)
    out(f"{proto}: kaya's window {kaya_box}, the witness's content at "
        f"{origin} (its own shadow {transform})")

    # kaya's own instrument, waited for rather than raced.
    diag = kaya_said.wait_for("KAYA_DIAG dragdrive", READY_DEADLINE_S,
                              "kaya's drag verb")
    hit = DIAG.search(diag)
    if hit is None:
        raise DragDriveError(
            f"kaya's drag verb printed a line this leg cannot read: {diag!r}")
    kaya_source = (int(hit.group(1)), int(hit.group(2)))
    kaya_files = (int(hit.group(3)), int(hit.group(4)))

    def centre(rect):
        return (origin[0] + rect[0] + rect[2] // 2,
                origin[1] + rect[1] + rect[3] // 2)

    if direction == "out":
        start, end = kaya_source, centre(rects["target"])
    else:
        start, end = centre(rects["source"]), kaya_files
    out(f"pressing {start}, releasing {end}")
    gesture = subprocess.run(
        injector_argv(proto, default_injector(proto), start, end),
        capture_output=True, text=True, encoding="utf-8", check=False)
    if gesture.returncode != 0:
        raise DragDriveError(
            f"the pointer gesture exited {gesture.returncode}: "
            f"{gesture.stderr.strip() or 'no stderr'}")

    # BOTH ENDS. kaya's half is its own verdict, byte-compared by the
    # harness against the scene above; the witness's half is its stdout.
    kaya_said.wait_for("KAYA_SELFTEST: OK", LANDING_DEADLINE_S,
                       "kaya never published a green verdict")
    if direction == "out":
        witness_said.wait_for(f"got text {KAYA_PAYLOAD_TEXT}",
                              LANDING_DEADLINE_S,
                              "the witness never took kaya's payload")
    else:
        witness_said.wait_for("handed over copy", LANDING_DEADLINE_S,
                              "the witness was never told the outcome")


def stop(child, what, group=False):
    """Stop `child`; with `group`, its whole session (start_new_session),
    so a child it forked dies with it, and wait until the session is
    empty rather than until the leader is."""
    if child.poll() is None:
        if group:
            os.killpg(child.pid, signal.SIGTERM)
        else:
            child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            if group:
                os.killpg(child.pid, signal.SIGKILL)
            else:
                child.kill()
            child.wait(timeout=5)
    out(f"{what} (pid {child.pid}) exited {child.returncode}")
    if group:
        # The leader is reaped; its session may still hold a child for a
        # moment. Bounded: two seconds is ten times what a SIGTERM takes.
        for _ in range(20):
            r = subprocess.run(["ps", "-Ao", "pid,sess,args"], capture_output=True,
                               text=True, encoding="utf-8", check=False)
            alive = [line for line in r.stdout.splitlines()[1:]
                     if line.split()[1:2] == [str(child.pid)]]
            if not alive:
                break
            for line in alive:
                try:
                    os.kill(int(line.split()[0]), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            time.sleep(0.1)


def prove_gone(offered):
    """THE LEG STARTED A SECOND APP; it says so is not enough. The process
    table is listed and shown empty of THIS leg's witness — a leftover one
    holds a window on this pool slot, and the next leg to claim the slot
    would meet it. Keyed on the leg's own scratch path: the two witness
    legs of a pool run side by side, and a census of every witness in the
    container counted the sibling's, three seconds old, as a leak
    (docs/traps.md: A witness census that counted every witness)."""
    r = subprocess.run(["ps", "-Ao", "pid,ppid,sess,etime,args"], capture_output=True,
                       text=True, encoding="utf-8", check=False)
    left = [line for line in r.stdout.splitlines()
            if "dragwitness.py" in line and str(offered) in line and "ps -Ao" not in line]
    out(f"witness processes still running: {len(left)}"
        + ("".join(f"\n  {line}" for line in left) if left else " (none)"))
    if left:
        raise DragDriveError(
            f"{len(left)} witness process(es) outlived the leg: {left!r}")


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ("wayland", "x11") \
            or sys.argv[2] not in ("out", "in"):
        print("usage: dragwitness-leg.py (wayland|x11) (out|in) <kaya cmd...>",
              file=sys.stderr)
        return 2
    try:
        run(sys.argv[1], sys.argv[2], sys.argv[3:])
    except DragDriveError as e:
        print(f"dragwitness-leg: {e}", file=sys.stderr)
        return 1
    out(f"the {sys.argv[2]} witness drag landed on BOTH sides")
    return 0


if __name__ == "__main__":
    sys.exit(main())
