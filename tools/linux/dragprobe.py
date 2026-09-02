#!/usr/bin/env python3
"""A REAL POINTER DRAG LANDS ON A GTK DROP TARGET, proven before the first leg.

The linux lane's pointer routes are injected input — a virtual pointer
device on wayland (tools/linux/wlpointer), XTEST through xdotool on
x11 — and nothing a scene asserts today drives either: the harness
clicks by driving the toolkit. So the route is proven HERE, on every
lane run, by the one thing that cannot be faked: a GtkDragSource and a
GtkDropTarget in one window, a press on the source, a walk to the
target and a release, and the target's own `drop` signal carrying the
source's string. This is the drag-and-drop plan's probe 4
(docs/dnd-plan.md §2), kept as the lane's wall rather than a one-off.

It drives itself: the window's content origin is read from the SERVER
(sway's IPC tree on wayland, xdotool's geometry on x11) and the widget
boxes from GTK, and the injector runs as a child while the main loop
keeps delivering events. A drop that never arrives prints every signal
the probe DID see, the injector's exit and its stderr, and fails.

Watched failing 2026-09-02 against sway's own `seat - cursor press`,
which succeeds on a deviceless seat and delivers nothing: the geometry
line alone, then the timeout (docs/traps.md).

    dragprobe.py wayland /tmp/wlpointer/wlpointer
    dragprobe.py x11 xdotool

Runs INSIDE the container under the leg environment (GDK_BACKEND and
the session variables of one pool slot); no prelude, like the other
in-container python here.
"""
import json
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, GObject, Gtk  # noqa: E402

PAYLOAD = "alpha"
STEPS = 12
DROP_DEADLINE_MS = 10000


def fail(*words):
    print("dragprobe: " + " ".join(words), file=sys.stderr, flush=True)
    sys.exit(1)


def content_origin_wayland(pid):
    """This process's toplevel content origin, from sway's tree."""
    out = subprocess.run(["swaymsg", "-t", "get_tree"], capture_output=True,
                         text=True, encoding="utf-8", check=False)
    if out.returncode != 0:
        fail("swaymsg -t get_tree failed:", out.stderr.strip())

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


def content_origin_x11(pid):
    """This process's largest X window, which under bare Xvfb is the
    toplevel with its content at the window's own origin (no manager,
    no frame)."""
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


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("wayland", "x11"):
        fail("usage: dragprobe.py (wayland|x11) INJECTOR")
    proto, injector = sys.argv[1], sys.argv[2]
    seen = []
    state = {"child": None, "origin_tries": 0}
    app = Gtk.Application(application_id="dev.kaya.dragprobe")

    def note(line):
        seen.append(line)
        print("dragprobe: saw " + line, flush=True)

    def activate(app):
        win = Gtk.ApplicationWindow(application=app, title="dragprobe")
        win.set_default_size(600, 200)
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=40)
        for side in ("top", "bottom", "start", "end"):
            getattr(box, f"set_margin_{side}")(40)
        source = Gtk.Label(label="SOURCE")
        source.set_size_request(200, 100)
        target = Gtk.Label(label="TARGET")
        target.set_size_request(200, 100)
        box.append(source)
        box.append(target)
        win.set_child(box)

        drag = Gtk.DragSource()
        drag.set_actions(Gdk.DragAction.COPY)

        def prepare(_source, x, y):
            note("prepare at %.0f,%.0f" % (x, y))
            return Gdk.ContentProvider.new_for_value(GObject.Value(str, PAYLOAD))

        drag.connect("prepare", prepare)
        drag.connect("drag-begin", lambda _s, _d: note("drag-begin"))
        drag.connect("drag-end", lambda _s, _d, delete: note("drag-end delete=%s" % delete))
        source.add_controller(drag)

        drop = Gtk.DropTarget.new(str, Gdk.DragAction.COPY)

        def enter(_target, _x, _y):
            note("enter")
            return Gdk.DragAction.COPY

        def dropped(_target, value, x, y):
            note("drop %r at %.0f,%.0f" % (value, x, y))
            if value == PAYLOAD:
                print(f"dragprobe: {proto} drop landed through {injector}: "
                      f"{value!r} arrived at the target", flush=True)
                GLib.timeout_add(200, lambda: (app.quit(), False)[1])
            return True

        drop.connect("enter", enter)
        drop.connect("drop", dropped)
        target.add_controller(drop)

        def drive():
            origin = (content_origin_wayland if proto == "wayland"
                      else content_origin_x11)(os.getpid())
            if origin is None:
                state["origin_tries"] += 1
                if state["origin_tries"] > 20:
                    fail(f"the {proto} server never showed this window (pid {os.getpid()})")
                return True
            src = source.compute_bounds(win)[1]
            dst = target.compute_bounds(win)[1]
            start = (int(origin[0] + src.origin.x + src.size.width / 2),
                     int(origin[1] + src.origin.y + src.size.height / 2))
            end = (int(origin[0] + dst.origin.x + dst.size.width / 2),
                   int(origin[1] + dst.origin.y + dst.size.height / 2))
            print(f"dragprobe: {proto} window content at {origin}; "
                  f"drag {start} -> {end}", flush=True)
            state["child"] = subprocess.Popen(injector_argv(proto, injector, start, end),
                                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                              text=True, encoding="utf-8")
            GLib.timeout_add(DROP_DEADLINE_MS, deadline)
            return False

        def deadline():
            child = state["child"]
            rc = child.poll()
            err = ""
            if rc is not None:
                err = child.communicate()[1].strip()
            else:
                child.kill()
                rc = "still running"
            fail(f"NO DROP on {proto} within {DROP_DEADLINE_MS // 1000}s; "
                 f"saw {seen or 'nothing'}; injector {injector} exit {rc}"
                 + (f"; stderr: {err}" if err else ""))

        GLib.timeout_add(300, drive)
        win.present()

    app.connect("activate", activate)
    rc = app.run([])
    if not any(line.startswith(f"drop {PAYLOAD!r}") for line in seen):
        fail(f"the loop ended without a drop (rc {rc}); saw {seen or 'nothing'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
