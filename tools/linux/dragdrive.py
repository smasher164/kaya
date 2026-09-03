#!/usr/bin/env python3
"""ONE REAL POINTER DRAG, ONE COPY OF IT.

Two callers need the identical gesture on this lane: tools/linux/dragprobe.py,
which proves the route before the first leg, and the harness `drag` verb in
crates/kaya/src/gtk.rs, which drives a scene's drag (docs/dnd-plan.md D10). A
second spelling of "where is this window and how do I press, walk and release"
is a second contract, so both read this file — dragprobe imports it, the verb
runs it.

    dragdrive.py (wayland|x11) PID TX TY X0 Y0 X1 Y1 [INJECTOR]

X0..Y1 are in the toplevel WIDGET's own coordinates and TX TY is that
widget's origin inside its GdkSurface (GTK's `gtk_native_get_surface_transform`,
which is the CSD shadow). The caller must pass it, because THE TWO SERVERS
ANSWER DIFFERENT QUESTIONS about where a window is: sway reports the xdg
window geometry, which is the CONTENT, while `xdotool getwindowgeometry`
reports the X window, which IS the surface and carries the shadow inside it.
docs/traps.md: The x11 lane's toplevel X window is BIGGER than its content
Measured 2026-09-03 on this lane: the transform is (5, 5) on x11 and (61, 55)
on wayland.

The injector runs to completion and its exit is this process's; the screen
coordinates it was given are printed, because a gesture that landed on the
wrong pixel and a gesture that never ran read the same from the outside.

Runs INSIDE the container under the leg environment (GDK_BACKEND and the
session variables of one pool slot); no prelude, like the other in-container
python here.
"""
import json
import subprocess
import sys
import time

# The walk between press and release: enough moves to pass GTK's drag
# threshold and to let the destination's motion handler answer before the
# release (measured on both protocols by dragprobe.py).
STEPS = 12
# The wayland injector is built into the image's scratch by run-suites.sh;
# xdotool is on the PATH.
DEFAULT_INJECTOR = {"wayland": "/tmp/wlpointer/wlpointer", "x11": "xdotool"}
ORIGIN_DEADLINE_S = 5.0


class DragDriveError(Exception):
    """What stopped the gesture, in the words of whatever measured it."""


def default_injector(proto):
    return DEFAULT_INJECTOR[proto]


def content_origin_wayland(pid):
    """This process's toplevel CONTENT origin: sway reports the xdg window
    geometry, which GTK sets to the content box and which therefore already
    excludes the shadow."""
    out = subprocess.run(["swaymsg", "-t", "get_tree"], capture_output=True,
                         text=True, encoding="utf-8", check=False)
    if out.returncode != 0:
        raise DragDriveError("swaymsg -t get_tree failed: " + out.stderr.strip())

    def walk(node):
        if node.get("pid") == pid and node.get("app_id"):
            rect, win = node["rect"], node["window_rect"]
            return (rect["x"] + win["x"], rect["y"] + win["y"])
        for child in node.get("nodes", []) + node.get("floating_nodes", []):
            hit = walk(child)
            if hit:
                return hit
        return None

    return walk(json.loads(out.stdout))


def surface_origin_x11(pid):
    """This process's largest X window, which under bare Xvfb is the toplevel
    with no manager and no frame — so it IS the GdkSurface, shadow included,
    and the content starts one surface transform inside it."""
    ids = subprocess.run(["xdotool", "search", "--pid", str(pid)], capture_output=True,
                         text=True, encoding="utf-8", check=False).stdout.split()
    best = None
    for wid in ids:
        geo = subprocess.run(["xdotool", "getwindowgeometry", "--shell", wid],
                             capture_output=True, text=True, encoding="utf-8",
                             check=False).stdout
        fields = dict(line.split("=", 1) for line in geo.split() if "=" in line)
        try:
            area = int(fields["WIDTH"]) * int(fields["HEIGHT"])
            at = (int(fields["X"]), int(fields["Y"]))
        except (KeyError, ValueError):
            continue
        if best is None or area > best[0]:
            best = (area, at)
    return best[1] if best else None


def content_origin(proto, pid, transform):
    """Where this process's toplevel CONTENT sits on screen, in each server's
    own terms — the transform is added only where the origin read answers for
    the surface."""
    if proto == "wayland":
        return content_origin_wayland(pid)
    origin = surface_origin_x11(pid)
    if origin is None:
        return None
    return (origin[0] + transform[0], origin[1] + transform[1])


def injector_argv(proto, injector, start, end):
    """One process that presses at `start`, walks to `end` and releases."""
    (x0, y0), (x1, y1) = start, end
    path = [(x0 + (x1 - x0) * i // STEPS, y0 + (y1 - y0) * i // STEPS)
            for i in range(1, STEPS + 1)]
    if proto == "wayland":
        argv = [injector, "set", str(x0), str(y0), "sleep", "200", "press", "left",
                "sleep", "200"]
        for x, y in path:
            argv += ["set", str(x), str(y), "sleep", "40"]
        return argv + ["sleep", "300", "release", "left", "sleep", "300"]
    argv = [injector, "mousemove", str(x0), str(y0), "sleep", "0.2", "mousedown", "1",
            "sleep", "0.2"]
    for x, y in path:
        argv += ["mousemove", str(x), str(y), "sleep", "0.04"]
    return argv + ["sleep", "0.3", "mouseup", "1"]


def drive(proto, pid, transform, start_in_window, end_in_window, injector=None):
    """Press at one widget point, walk to another, release. The screen
    coordinates actually used come back; a failure raises with what it
    measured."""
    injector = injector or default_injector(proto)
    deadline = time.monotonic() + ORIGIN_DEADLINE_S
    origin = content_origin(proto, pid, transform)
    while origin is None and time.monotonic() < deadline:
        time.sleep(0.05)
        origin = content_origin(proto, pid, transform)
    if origin is None:
        raise DragDriveError(
            f"the {proto} server showed no window for pid {pid} within "
            f"{ORIGIN_DEADLINE_S:.0f}s, so there is no screen point to press")
    start = (int(origin[0] + start_in_window[0]), int(origin[1] + start_in_window[1]))
    end = (int(origin[0] + end_in_window[0]), int(origin[1] + end_in_window[1]))
    out = subprocess.run(injector_argv(proto, injector, start, end),
                         capture_output=True, text=True, encoding="utf-8",
                         check=False)
    if out.returncode != 0:
        raise DragDriveError(
            f"{injector} exited {out.returncode} driving {start} -> {end}: "
            + (out.stderr.strip() or "no stderr"))
    return origin, start, end


def main():
    if len(sys.argv) not in (9, 10) or sys.argv[1] not in ("wayland", "x11"):
        print("usage: dragdrive.py (wayland|x11) PID TX TY X0 Y0 X1 Y1 [INJECTOR]",
              file=sys.stderr)
        return 2
    proto = sys.argv[1]
    pid = int(sys.argv[2])
    tx, ty, x0, y0, x1, y1 = (int(v) for v in sys.argv[3:9])
    injector = sys.argv[9] if len(sys.argv) == 10 else None
    try:
        origin, start, end = drive(proto, pid, (tx, ty), (x0, y0), (x1, y1), injector)
    except DragDriveError as e:
        print(f"dragdrive: {e}", file=sys.stderr)
        return 1
    print(f"dragdrive: {proto} content at {origin} (surface transform "
          f"{(tx, ty)}); pressed {start}, released {end}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
