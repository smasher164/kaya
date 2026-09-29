#!/usr/bin/env python3
"""docs/range-plan.md §4.2 and §4.3 on GTK 4: two GtkScales stacked over one
trough drawn in Adwaita's own `scale > trough > highlight` nodes.

Runs in the kaya-linux image under Xvfb with an AT-SPI bus (the runner at the
bottom of this docstring). The app half drives itself from a thread with
xdotool (XTEST, a real pointer and keyboard) and reads its assistive half from
a second process over AT-SPI, as Orca would.

    python3 range-stack-gtk-2026-09-29.py app OUTDIR [rtl]
    python3 range-stack-gtk-2026-09-29.py atspi APPNAME (dump|set LABEL VALUE GROUP)

Runner, inside `docker run --rm -v <repo>:/src -v <out>:/out kaya-linux`:

    Xvfb :99 -screen 0 1600x1000x24 & export DISPLAY=:99 GDK_BACKEND=x11
    eval "$(dbus-launch --sh-syntax)"; export GTK_A11Y=atspi
    /usr/libexec/at-spi-bus-launcher --launch-immediately & sleep 1
    python3 /src/docs/probes/range-stack-gtk-2026-09-29.py app /out
    python3 /src/docs/probes/range-stack-gtk-2026-09-29.py app /out rtl

The three routings compared, on identical ranges:
  plain     two scales, nothing done: GTK picks the top scale everywhere.
  contains  each scale answers `contains` on its half of the midpoint split.
  split     `contains` as above AND the scale's own children untargetable, so
            the pick reaches the scale's `contains` before any child.
"""
import json
import os
import subprocess
import sys
import threading
import time


def clamp_thumb(lo, hi, step, gap, low, other, raw):
    """crates/kaya/src/range.rs clamp_thumb, verbatim in python."""
    v = lo + round((raw - lo) / step) * step if step > 0 else raw
    v = min(max(v, lo), hi)
    return min(v, other - gap) if low else max(v, other + gap)


def atspi_main(argv):
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
    Atspi.init()
    appname, cmd = argv[0], argv[1]
    desktop = Atspi.get_desktop(0)
    app = None
    for i in range(desktop.get_child_count()):
        a = desktop.get_child_at_index(i)
        if a is not None and a.get_name() == appname:
            app = a
    if app is None:
        print(json.dumps({"error": f"no app {appname!r} on the bus"}))
        return 1
    found = []

    def walk(node, depth, path):
        role = node.get_role_name()
        name = node.get_name()
        entry = {"depth": depth, "role": role, "name": name, "path": path}
        value = node.get_value_iface() if hasattr(node, "get_value_iface") else None
        if value is None:
            try:
                value = node.get_value()
            except Exception:  # noqa: BLE001 - not every node speaks Value
                value = None
        if value is not None:
            entry["value"] = [value.get_minimum_value(), value.get_current_value(),
                              value.get_maximum_value()]
        found.append((entry, node, value))
        for i in range(min(node.get_child_count(), 60)):
            child = node.get_child_at_index(i)
            if child is not None:
                walk(child, depth + 1, path + [i])

    walk(app, 0, [])
    if cmd == "dump":
        print(json.dumps([e for e, _, _ in found if e["role"] in
                          ("panel", "grouping", "slider", "filler", "frame")]))
        return 0
    label, value = argv[2], float(argv[3])
    group = [e["path"] for e, _, _ in found if e["role"] == "grouping" and e["name"] == argv[4]]
    for entry, node, iface in found:
        if (entry["role"] == "slider" and entry["name"] == label and iface is not None
                and group and entry["path"][:len(group[0])] == group[0]):
            ok = iface.set_current_value(value)
            time.sleep(0.3)
            print(json.dumps({"set": value, "answered": ok,
                              "reads": iface.get_current_value()}))
            return 0
    print(json.dumps({"error": f"no slider named {label!r}"}))
    return 1


def app_main(argv):
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gdk, GLib, Graphene, Gtk

    outdir = argv[0]
    rtl = len(argv) > 1 and argv[1] == "rtl"
    tag = "rtl" if rtl else "ltr"
    GLib.set_prgname(f"rangeprobe-{tag}")
    Adw.init()
    if rtl:
        Gtk.Widget.set_default_direction(Gtk.TextDirection.RTL)

    css = Gtk.CssProvider()
    css.load_from_string(
        "scale.kaya-range-thumb > trough { background: none; border-color: transparent;"
        " box-shadow: none; }\n"
        "scale.kaya-range-thumb > trough > highlight { background: none;"
        " border-color: transparent; box-shadow: none; }\n"
        "scale.kaya-range-thumb.kaya-range-high > marks { opacity: 0; }\n")
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    log = []

    def note(**kw):
        log.append(kw)
        print(json.dumps(kw), flush=True)

    def child_named(widget, name):
        c = widget.get_first_child()
        while c is not None:
            if c.get_css_name() == name:
                return c
            c = c.get_next_sibling()
        return None

    class Thumb(Gtk.Scale):
        __gtype_name__ = "ProbeRangeThumb"

        def do_contains(self, x, y):
            inside = Gtk.Scale.do_contains(self, x, y)
            if self.range.routing == "plain" or not inside:
                return inside
            return self.range.takes(self, x, y)

    class Range:
        def __init__(self, name, lo, hi, step, gap, low, high, routing, ticks):
            self.name, self.lo, self.hi, self.step, self.gap = name, lo, hi, step, gap
            self.routing = routing
            self.quiet = False
            self.box = Gtk.Overlay(accessible_role=Gtk.AccessibleRole.GROUP)
            self.box.update_property([Gtk.AccessibleProperty.LABEL], [name])
            quiet_role = Gtk.AccessibleRole.PRESENTATION
            self.track = Gtk.Fixed(css_name="scale", css_classes=["horizontal"],
                                   accessible_role=quiet_role)
            self.trough = Gtk.Fixed(css_name="trough", accessible_role=quiet_role)
            self.fill = Gtk.Box(css_name="highlight", accessible_role=quiet_role)
            self.track.put(self.trough, 0, 0)
            self.trough.put(self.fill, 0, 0)
            self.track.set_can_target(False)
            self.box.set_child(self.track)
            self.thumbs = []
            for is_low, value, label in ((True, low, "In"), (False, high, "Out")):
                s = Thumb(orientation=Gtk.Orientation.HORIZONTAL,
                          adjustment=Gtk.Adjustment(lower=lo, upper=hi, value=value,
                                                    step_increment=step,
                                                    page_increment=step * 10))
                s.range, s.is_low = self, is_low
                s.set_size_request(240, -1)
                s.add_css_class("kaya-range-thumb")
                s.add_css_class("kaya-range-low" if is_low else "kaya-range-high")
                s.update_property([Gtk.AccessibleProperty.LABEL], [label])
                if ticks:
                    k = lo
                    while k <= hi + 1e-9:
                        s.add_mark(k, Gtk.PositionType.BOTTOM, None)
                        k += ticks
                if routing == "split":
                    c = s.get_first_child()
                    while c is not None:
                        c.set_can_target(False)
                        c = c.get_next_sibling()
                s.connect("value-changed", self.moved)
                self.box.add_overlay(s)
                self.box.set_measure_overlay(s, True)
                self.thumbs.append(s)
            self.low, self.high = self.thumbs
            self.box.add_tick_callback(lambda *_: self.layout() or True)

        def knob_centre(self, s):
            trough = child_named(s, "trough")
            knob = child_named(trough, "slider")
            ok, b = knob.compute_bounds(self.box)
            return (b.get_x() + b.get_width() / 2, b.get_y() + b.get_height() / 2,
                    b.get_width())

        def takes(self, s, x, y):
            ok, p = s.compute_point(self.box, Graphene.Point().init(x, y))
            if not ok:
                return False
            lx = self.knob_centre(self.low)[0]
            hx = self.knob_centre(self.high)[0]
            mirrored = s.get_direction() == Gtk.TextDirection.RTL
            if abs(hx - lx) < 0.5:
                low_takes = (p.x > lx) if mirrored else (p.x < lx)
            else:
                mid = (lx + hx) / 2
                low_takes = (p.x > mid) if mirrored else (p.x < mid)
            return low_takes == s.is_low

        def layout(self):
            native = child_named(self.low, "trough")
            ok, tb = native.compute_bounds(self.box)
            if not ok:
                return
            x, y, w, h = tb.get_x(), tb.get_y(), tb.get_width(), tb.get_height()
            ok, kb = self.trough.compute_bounds(self.box)
            px, py = self.track.get_child_position(self.trough)
            if ok and (abs(kb.get_x() - x) > 0.25 or abs(kb.get_y() - y) > 0.25):
                self.track.move(self.trough, px + x - kb.get_x(), py + y - kb.get_y())
            self.trough.set_size_request(int(round(w)), int(round(h)))
            a = self.knob_centre(self.low)[0]
            b = self.knob_centre(self.high)[0]
            left, right = min(a, b), max(a, b)
            ok, fb = self.fill.compute_bounds(self.box)
            fx, fy = self.trough.get_child_position(self.fill)
            if ok and abs(fb.get_x() - left) > 0.25:
                self.trough.move(self.fill, fx + left - fb.get_x(), 0)
            self.fill.set_size_request(max(0, int(round(right - left))), int(round(h)))

        def moved(self, s):
            if self.quiet:
                return
            raw = s.get_value()
            other = (self.high if s.is_low else self.low).get_value()
            v = clamp_thumb(self.lo, self.hi, self.step, self.gap, s.is_low, other, raw)
            if v != raw:
                self.quiet = True
                s.set_value(v)
                self.quiet = False
            note(ev="moved", range=self.name, routing=self.routing,
                 thumb="low" if s.is_low else "high", raw=raw, rests=s.get_value())

        def put(self, low, high):
            self.quiet = True
            self.low.set_value(low)
            self.high.set_value(high)
            self.quiet = False

    win = Adw.Window(title=f"rangeprobe {tag}")
    win.set_default_size(900, 700)
    col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
    for m in ("margin_top", "margin_bottom", "margin_start", "margin_end"):
        col.set_property(m, 24)
    ranges = {}
    for routing in ("plain", "contains", "split"):
        r = Range(f"Trim-{routing}", 0.0, 10.0, 0.5, 1.0, 2.0, 8.0, routing, 1.0)
        ranges[routing] = r
        col.append(Gtk.Label(label=routing))
        col.append(r.box)
    tie = Range("Tie", 0.0, 10.0, 0.5, 0.0, 5.0, 5.0, "split", 0)
    ranges["tie"] = tie
    col.append(tie.box)
    fader = Gtk.Scale(orientation=Gtk.Orientation.VERTICAL,
                      adjustment=Gtk.Adjustment(lower=0, upper=1, value=0.25,
                                                step_increment=0.25, page_increment=0.5))
    fader.set_inverted(True)
    fader.set_size_request(-1, 200)
    fader.set_halign(Gtk.Align.START)
    fader.update_property([Gtk.AccessibleProperty.LABEL], ["Volume"])
    col.append(fader)
    win.set_content(col)
    win.present()

    def on_main(fn):
        box = {}
        done = threading.Event()

        def run():
            try:
                box["v"] = fn()
            except Exception as e:  # noqa: BLE001 - reported to the driver
                box["e"] = repr(e)
            done.set()
            return False
        GLib.idle_add(run)
        done.wait(10)
        if "e" in box:
            raise RuntimeError(box["e"])
        return box.get("v")

    def xdo(*args):
        subprocess.run(["xdotool", *[str(a) for a in args]], check=True)

    def origin():
        wid = subprocess.run(["xdotool", "search", "--pid", str(os.getpid())],
                             capture_output=True, text=True, check=False).stdout.split()
        best = None
        for w in wid:
            geo = subprocess.run(["xdotool", "getwindowgeometry", "--shell", w],
                                 capture_output=True, text=True, check=False).stdout
            f = dict(line.split("=", 1) for line in geo.split() if "=" in line)
            area = int(f["WIDTH"]) * int(f["HEIGHT"])
            if best is None or area > best[0]:
                best = (area, int(f["X"]), int(f["Y"]))
        tx, ty = on_main(lambda: win.get_surface_transform())
        return best[1] + tx, best[2] + ty

    def at_window(r, x, y):
        def read():
            ok, p = r.box.compute_point(win, Graphene.Point().init(x, y))
            return p.x, p.y
        return on_main(read)

    def centre_of_value(r, v):
        def read():
            lx, ly, _ = r.knob_centre(r.low)
            hx, _, _ = r.knob_centre(r.high)
            lv, hv = r.low.get_value(), r.high.get_value()
            if hv == lv:
                return None
            return lx + (v - lv) * (hx - lx) / (hv - lv), ly
        return on_main(read)

    def state(r):
        return on_main(lambda: {"low": r.low.get_value(), "high": r.high.get_value(),
                                "focus": "low" if r.low.has_focus() else
                                ("high" if r.high.has_focus() else None)})

    def knob_flags(r, which):
        def read():
            s = r.low if which == "low" else r.high
            knob = child_named(child_named(s, "trough"), "slider")
            f = knob.get_state_flags()
            return {"prelight": bool(f & Gtk.StateFlags.PRELIGHT),
                    "active": bool(f & Gtk.StateFlags.ACTIVE),
                    "scale_prelight": bool(s.get_state_flags() & Gtk.StateFlags.PRELIGHT)}
        return on_main(read)

    def shot(name):
        def render():
            w, h = col.get_width(), col.get_height()
            paint = Gtk.WidgetPaintable.new(col)
            snap = Gtk.Snapshot()
            snap.append_color(Gdk.RGBA(red=0.98, green=0.98, blue=0.98, alpha=1),
                              Graphene.Rect().init(0, 0, w, h))
            paint.snapshot(snap, w, h)
            node = snap.to_node()
            tex = win.get_renderer().render_texture(node, None)
            path = os.path.join(outdir, f"range-gtk-{tag}-{name}.png")
            tex.save_to_png(path)
            return path
        note(ev="shot", path=on_main(render))

    def press(ox, oy, wx, wy, drag_to=None, hold=0.15):
        sx, sy = int(round(ox + wx)), int(round(oy + wy))
        xdo("mousemove", sx, sy)
        time.sleep(0.15)
        xdo("mousemove", sx + 1, sy)
        xdo("mousemove", sx, sy)
        time.sleep(0.15)
        xdo("mousedown", 1)
        time.sleep(hold)
        if drag_to is not None:
            tx = int(round(ox + drag_to))
            for i in range(1, 9):
                xdo("mousemove", sx + (tx - sx) * i // 8, sy)
                time.sleep(0.03)
        xdo("mouseup", 1)
        time.sleep(0.25)
        xdo("mousemove", 5, 5)
        time.sleep(0.15)

    def geometry(r):
        def read():
            lx, ly, kw = r.knob_centre(r.low)
            hx, hy, _ = r.knob_centre(r.high)
            ok, fb = r.fill.compute_bounds(r.box)
            ok2, tb = r.trough.compute_bounds(r.box)
            ok3, nb = child_named(r.low, "trough").compute_bounds(r.box)
            return {"low_centre": [lx, ly], "high_centre": [hx, hy], "knob_width": kw,
                    "fill": [fb.get_x(), fb.get_y(), fb.get_width(), fb.get_height()],
                    "kaya_trough": [tb.get_x(), tb.get_y(), tb.get_width(), tb.get_height()],
                    "native_trough": [nb.get_x(), nb.get_y(), nb.get_width(), nb.get_height()]}
        return on_main(read)

    def travel(scale):
        """GtkRange's own geometry (gtk_range_compute_slider_position): the
        slider's allocation runs over the trough's size less the slider's
        MEASURED size, which carries Adwaita's -8px margins."""
        trough = child_named(scale, "trough")
        knob = child_named(trough, "slider")
        ok, kb = knob.compute_bounds(trough)
        if scale.get_orientation() == Gtk.Orientation.VERTICAL:
            size = knob.measure(Gtk.Orientation.VERTICAL, -1)[0]
            centre = kb.get_y() + kb.get_height() / 2
            return (trough.get_height() - size / 2 - centre) / (trough.get_height() - size)
        size = knob.measure(Gtk.Orientation.HORIZONTAL, -1)[0]
        centre = kb.get_x() + kb.get_width() / 2
        return (centre - size / 2) / (trough.get_width() - size)

    def travel_fraction_h(r, which):
        return on_main(lambda: travel(r.low if which == "low" else r.high))

    def fader_fraction():
        return on_main(lambda: travel(fader))

    def atspi(*args):
        out = subprocess.run([sys.executable, os.path.abspath(__file__), "atspi",
                              f"rangeprobe-{tag}", *[str(a) for a in args]],
                             capture_output=True, text=True, check=False, timeout=30)
        try:
            return json.loads(out.stdout.strip().splitlines()[-1])
        except (IndexError, ValueError):
            return {"error": out.stdout + out.stderr}

    seen = {}
    motion = Gtk.EventControllerMotion()
    motion.connect("motion", lambda _c, x, y: seen.update(at=(x, y)))
    win.add_controller(motion)

    def drive():
        time.sleep(1.5)
        ox, oy = origin()
        note(ev="origin", at=[ox, oy], window=on_main(lambda: [win.get_width(),
                                                             win.get_height()]))
        for name, r in ranges.items():
            note(ev="placed", range=name, at=at_window(r, 0, 0),
                 size=on_main(lambda: [r.box.get_width(), r.box.get_height()]))
        xdo("mousemove", int(ox + 100), int(oy + 50))
        time.sleep(0.3)
        note(ev="pointer check", sent=[100, 50], seen=on_main(lambda: seen.get("at")))
        split = ranges["split"]
        note(ev="geometry", routing="split", **geometry(split))
        shot("rest")
        for routing in ("plain", "contains", "split"):
            r = ranges[routing]
            cases = [("low knob centre", "knob", "low", 0), ("low knob +4px", "knob", "low", 4),
                     ("value 1", "value", 1.0, 0), ("value 4.8", "value", 4.8, 0),
                     ("value 5.2", "value", 5.2, 0), ("high knob centre", "knob", "high", 0),
                     ("value 9.5", "value", 9.5, 0)]
            for label, kind, what, dx in cases:
                on_main(lambda: r.put(2.0, 8.0))
                time.sleep(0.2)
                if kind == "knob":
                    x, y, _ = on_main(lambda: r.knob_centre(r.low if what == "low" else r.high))
                    x += -dx if rtl else dx
                else:
                    x, y = centre_of_value(r, what)
                wx, wy = at_window(r, x, y)
                before = state(r)
                if routing == "split" and label == "low knob centre":
                    xdo("mousemove", int(round(ox + wx)), int(round(oy + wy)))
                    time.sleep(0.3)
                    note(ev="hover", routing=routing, **knob_flags(r, "low"))
                press(ox, oy, wx, wy)
                after = state(r)
                note(ev="press", routing=routing, case=label, at=[wx, wy], before=before, after=after)
        for routing in ("plain", "split"):
            r = ranges[routing]
            on_main(lambda: r.put(2.0, 8.0))
            x, y, _ = on_main(lambda: r.knob_centre(r.low))
            wx, wy = at_window(r, x, y)
            sx, sy = int(round(ox + wx)), int(round(oy + wy))
            xdo("mousemove", sx, sy)
            time.sleep(0.2)
            xdo("mousedown", 1)
            time.sleep(0.3)
            note(ev="held", routing=routing, **knob_flags(r, "low"))
            xdo("mouseup", 1)
            time.sleep(0.2)
            xdo("mousemove", 5, 5)
        tie = ranges["tie"]
        for side, dx in (("left of centre", -3), ("right of centre", 3)):
            on_main(lambda: tie.put(5.0, 5.0))
            time.sleep(0.2)
            x, y, _ = on_main(lambda: tie.knob_centre(tie.low))
            wx, wy = at_window(tie, x + dx, y)
            before = state(tie)
            press(ox, oy, wx, wy, drag_to=wx + dx * 12, hold=0.2)
            note(ev="tie", case=side, before=before, after=state(tie))
        on_main(lambda: split.put(2.0, 8.0))
        note(ev="thumb_fraction", low=travel_fraction_h(split, "low"),
             high=travel_fraction_h(split, "high"))
        # A drag of the low thumb past the high one: the clamp on the pointer path.
        x, y, _ = on_main(lambda: split.knob_centre(split.low))
        wx, wy = at_window(split, x, y)
        hx, _, _ = on_main(lambda: split.knob_centre(split.high))
        hwx, _ = at_window(split, hx, y)
        press(ox, oy, wx, wy, drag_to=hwx + (-60 if rtl else 60))
        note(ev="drag past", after=state(split))
        on_main(lambda: split.put(2.0, 8.0))
        note(ev="atspi tree", tree=atspi("dump"))
        note(ev="atspi set In 9.5", answer=atspi("set", "In", 9.5, "Trim-split"), after=state(split))
        on_main(lambda: split.put(2.0, 8.0))
        note(ev="atspi set Out 0.5", answer=atspi("set", "Out", 0.5, "Trim-split"), after=state(split))
        note(ev="fader", inverted=on_main(fader.get_inverted),
             fraction=fader_fraction(), value=on_main(fader.get_value))
        on_main(fader.grab_focus)
        time.sleep(0.2)
        xdo("key", "Up")
        time.sleep(0.3)
        note(ev="fader Up", value=on_main(fader.get_value), fraction=fader_fraction())
        on_main(lambda: split.put(2.0, 8.0))
        on_main(split.low.grab_focus)
        time.sleep(0.2)
        xdo("key", "Right")
        time.sleep(0.3)
        note(ev="low Right key", after=state(split))
        on_main(lambda: split.put(2.0, 8.0))
        on_main(lambda: tie.put(5.0, 5.0))
        time.sleep(0.3)
        shot("end")
        with open(os.path.join(outdir, f"range-gtk-{tag}.json"), "w", encoding="utf-8") as f:
            json.dump(log, f, indent=1)
        GLib.idle_add(lambda: win.destroy() or loop.quit())

    loop = GLib.MainLoop()
    threading.Thread(target=drive, daemon=True).start()
    loop.run()
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "atspi":
        sys.exit(atspi_main(sys.argv[2:]))
    sys.exit(app_main(sys.argv[2:]))
