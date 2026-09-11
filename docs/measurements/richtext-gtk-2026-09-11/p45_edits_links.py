#!/usr/bin/env python3
"""Probe 4 (edit reporting) + probe 5 (synthesized links).

kaya's textarea shape: an editable GtkTextView inside a GtkScrolledWindow.
Real input is driven with xdotool through XTEST against the Xvfb server, so
typing, pasting and clicking take the platform's own path, not a programmatic one.

Offsets: GtkTextIter counts CHARACTERS (Unicode code points).  kaya's unit is
UTF-8 BYTES.  The conversion used here is
    byte_off(iter) = len(buffer.get_text(start, iter, True).encode("utf-8"))
i.e. encode the prefix.  The cheap per-line equivalent GTK offers directly is
GtkTextIter.get_line_index() (bytes within the line); both are printed so they
can be checked against each other.
"""
import os, subprocess, sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Graphene", "1.0")
from gi.repository import Gtk, Gdk, GLib, Pango, GObject, Graphene

LOG = []
def say(s=""):
    LOG.append(s); print(s, flush=True)
    open("/out/p45.txt", "w", encoding="utf-8").write("\n".join(LOG) + "\n")

def xdo(*args, window=None):
    cmd = ["xdotool"] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()

class Probe:
    def __init__(self):
        self.buf = Gtk.TextBuffer()
        self.view = Gtk.TextView(buffer=self.buf)
        self.view.set_editable(True)
        self.view.set_wrap_mode(Gtk.WrapMode.WORD)
        self.view.set_monospace(False)
        sw = Gtk.ScrolledWindow(); sw.set_child(self.view); sw.set_vexpand(True)
        self.win = Gtk.Window(title="kaya-richtext-probe")
        self.win.set_default_size(900, 400)
        self.win.set_child(sw)
        self.events = []
        self.recording = False
        self.tags = {}
        self.link_urls = {}          # the SIDE TABLE probe 5 is about: tag -> url
        self.activated = []
        self.wire_signals()
        self.wire_gesture()

    # ---------- offsets ----------
    def byte_off(self, it):
        return len(self.buf.get_text(self.buf.get_start_iter(), it, True).encode("utf-8"))

    def text(self):
        return self.buf.get_text(self.buf.get_start_iter(), self.buf.get_end_iter(), True)

    # ---------- signals ----------
    def wire_signals(self):
        b = self.buf
        b.connect("insert-text", self.on_insert)
        b.connect_after("insert-text", self.on_insert_after)
        b.connect("delete-range", self.on_delete)
        b.connect_after("delete-range", self.on_delete_after)
        b.connect("apply-tag", self.on_apply_tag)
        b.connect("remove-tag", self.on_remove_tag)
        b.connect("changed", lambda *_: self.rec("changed", ""))
        b.connect("begin-user-action", lambda *_: self.rec("begin-user-action", ""))
        b.connect("end-user-action", lambda *_: self.rec("end-user-action", ""))

    def rec(self, name, detail):
        if self.recording:
            self.events.append((name, detail))
            say("      %-18s %s" % (name, detail))

    def on_insert(self, buf, loc, text, length):
        if not self.recording: return
        self.rec("insert-text", "char_off=%d BYTE_off=%d line=%d line_index(bytes)=%d "
                                "text=%r len_arg=%d utf8_len=%d chars=%d"
                 % (loc.get_offset(), self.byte_off(loc), loc.get_line(), loc.get_line_index(),
                    text, length, len(text.encode("utf-8")), len(text)))

    def on_insert_after(self, buf, loc, text, length):
        if not self.recording: return
        self.rec("insert-text(after)", "iter now at char_off=%d BYTE_off=%d (end of inserted text)"
                 % (loc.get_offset(), self.byte_off(loc)))

    def on_delete(self, buf, start, end):
        if not self.recording: return
        gone = buf.get_text(start, end, True)
        self.rec("delete-range", "chars[%d,%d) BYTES[%d,%d) removed=%r utf8_len=%d"
                 % (start.get_offset(), end.get_offset(),
                    self.byte_off(start), self.byte_off(end), gone, len(gone.encode("utf-8"))))

    def on_delete_after(self, buf, start, end):
        if not self.recording: return
        self.rec("delete-range(after)", "chars[%d,%d) (deleted text NOT readable here)"
                 % (start.get_offset(), end.get_offset()))

    def on_apply_tag(self, buf, tag, start, end):
        if not self.recording: return
        self.rec("apply-tag", "tag=%r chars[%d,%d) BYTES[%d,%d)"
                 % (tag.get_property("name"), start.get_offset(), end.get_offset(),
                    self.byte_off(start), self.byte_off(end)))

    def on_remove_tag(self, buf, tag, start, end):
        if not self.recording: return
        self.rec("remove-tag", "tag=%r chars[%d,%d)"
                 % (tag.get_property("name"), start.get_offset(), end.get_offset()))

    # ---------- probe 5: the click gesture ----------
    def wire_gesture(self):
        g = Gtk.GestureClick()
        g.set_button(1)
        g.connect("released", self.on_click)
        self.view.add_controller(g)
        self.gesture = g
        m = Gtk.EventControllerMotion()
        m.connect("motion", self.on_motion)
        self.view.add_controller(m)

    def on_click(self, gesture, n_press, x, y):
        # x,y arrive in the WIDGET's coordinate space (the controller's widget = the view)
        bx, by = self.view.window_to_buffer_coords(Gtk.TextWindowType.WIDGET, int(x), int(y))
        over, it = self.view.get_iter_at_location(bx, by)
        names = [t.get_property("name") for t in it.get_tags()]
        hit = None
        for t in it.get_tags():
            if t in self.link_urls:
                hit = (t, self.link_urls[t]); break
        say("   CLICK widget(%.0f,%.0f) -> buffer(%d,%d) -> over_text=%s char_off=%d "
            "BYTE_off=%d tags=%s"
            % (x, y, bx, by, over, it.get_offset(), self.byte_off(it), names))
        if hit:
            self.activated.append(hit[1])
            say("   >>> LINK ACTIVATED: tag=%r url=%s" % (hit[0].get_property("name"), hit[1]))
        else:
            say("   >>> not a link (no activation)")

    def on_motion(self, ctrl, x, y):
        bx, by = self.view.window_to_buffer_coords(Gtk.TextWindowType.WIDGET, int(x), int(y))
        over, it = self.view.get_iter_at_location(bx, by)
        on_link = any(t in self.link_urls for t in it.get_tags())
        self.view.set_cursor_from_name("pointer" if on_link else "text")
        self._last_cursor = "pointer" if on_link else "text"

def main():
    p = Probe()
    p.win.present()

    ctx = GLib.MainContext.default()
    def pump(ms=250):
        end = GLib.get_monotonic_time() + ms * 1000
        while GLib.get_monotonic_time() < end:
            while ctx.pending():
                ctx.iteration(False)
            GLib.usleep(5000)

    pump(800)

    # the X window id, for pointer placement
    rc, wid, err = xdo("search", "--name", "kaya-richtext-probe")
    wid = wid.split("\n")[0] if wid else ""
    say("=== probe 4/5 — GTK %d.%d.%d ===" % (Gtk.get_major_version(),
        Gtk.get_minor_version(), Gtk.get_micro_version()))
    say("xdotool window id = %r (rc=%d err=%r)" % (wid, rc, err))
    rc, geo, _ = xdo("getwindowgeometry", wid) if wid else (1, "", "")
    say("window geometry: %s" % geo.replace("\n", " | "))
    if wid:
        xdo("windowfocus", wid)
        xdo("mousemove", "--window", wid, "300", "40")   # pointer INTO the window: PointerRoot focus
    pump(400)

    # =====================================================================
    say("\n########## PROBE 4 — EDIT REPORTING ##########")

    say("\n--- 4.1 PROGRAMMATIC insert (ASCII) ---")
    p.recording = True; p.events = []
    p.buf.insert(p.buf.get_end_iter(), "Hello")
    pump(150)
    say("   text=%r  char_count=%d  utf8_bytes=%d"
        % (p.text(), p.buf.get_char_count(), len(p.text().encode("utf-8"))))

    say("\n--- 4.2 PROGRAMMATIC insert (MULTI-BYTE 'héllo 👋') ---")
    p.events = []
    p.buf.insert(p.buf.get_end_iter(), " héllo 👋")
    pump(150)
    t = p.text()
    say("   text=%r" % t)
    say("   char_count=%d (GtkTextIter unit)   utf8_bytes=%d (kaya unit)"
        % (p.buf.get_char_count(), len(t.encode("utf-8"))))
    say("   per-char widths: %s"
        % [(c, len(c.encode("utf-8"))) for c in " héllo 👋"])
    e = p.buf.get_end_iter()
    say("   end iter: get_offset()=%d  byte_off()=%d  get_line_index()=%d"
        % (e.get_offset(), p.byte_off(e), e.get_line_index()))

    say("\n--- 4.3 PROGRAMMATIC delete across the multi-byte run ---")
    p.events = []
    # delete the ' 👋' at the end: last 2 chars
    n = p.buf.get_char_count()
    p.buf.delete(p.buf.get_iter_at_offset(n - 2), p.buf.get_iter_at_offset(n))
    pump(150)
    say("   text=%r" % p.text())

    say("\n--- 4.4 REAL TYPING through XTEST (xdotool type) ---")
    p.events = []
    p.buf.place_cursor(p.buf.get_end_iter())
    p.view.grab_focus(); pump(200)
    rc, out, err = xdo("type", "--delay", "60", "abc")
    say("   xdotool type rc=%d err=%r" % (rc, err))
    pump(900)
    say("   text=%r  (%d insert-text events)" % (p.text(),
        sum(1 for n_, _ in p.events if n_ == "insert-text")))

    say("\n--- 4.5 REAL TYPING of a NON-ASCII character (é) ---")
    p.events = []
    rc, out, err = xdo("key", "--delay", "80", "eacute")
    say("   xdotool key eacute rc=%d err=%r" % (rc, err))
    pump(700)
    say("   text=%r" % p.text())

    say("\n--- 4.6 REAL BACKSPACE (a delete through the platform's own path) ---")
    p.events = []
    xdo("key", "BackSpace"); pump(600)
    say("   text=%r" % p.text())

    say("\n--- 4.7 PASTE (clipboard set in-process, Ctrl+V through XTEST) ---")
    p.events = []
    cb = Gdk.Display.get_default().get_clipboard()
    payload = "PASTE-é👋-END"
    done = []
    try:
        cb.set_text(payload); done.append("set_text")
    except Exception as ex1:
        try:
            v = GObject.Value(str, payload)
            cb.set_content(Gdk.ContentProvider.new_for_value(v)); done.append("set_content")
        except Exception as ex2:
            done.append("FAILED %r / %r" % (ex1, ex2))
    say("   clipboard set via %s, payload=%r (%d bytes)"
        % (done, payload, len(payload.encode("utf-8"))))
    pump(300)
    xdo("key", "ctrl+v"); pump(1200)
    say("   after Ctrl+V: text=%r" % p.text())
    if not any(n_ == "insert-text" for n_, _ in p.events):
        say("   (no XTEST paste seen; falling back to the widget's own clipboard.paste action)")
        p.events = []
        p.view.activate_action("clipboard.paste", None); pump(1200)
        say("   after clipboard.paste action: text=%r" % p.text())

    say("\n--- 4.8 does apply-tag fire as its OWN signal, and on nothing else? ---")
    bold = p.buf.create_tag("bold", weight=Pango.Weight.BOLD)
    p.tags["bold"] = bold
    say("   (a) PROGRAMMATIC apply_tag over chars [0,5):")
    p.events = []
    p.buf.apply_tag(bold, p.buf.get_iter_at_offset(0), p.buf.get_iter_at_offset(5))
    pump(200)
    say("       -> signals seen: %s" % [n_ for n_, _ in p.events])
    say("   (b) PROGRAMMATIC insert INSIDE the bold run (text inherits the tag):")
    p.events = []
    p.buf.insert(p.buf.get_iter_at_offset(2), "ZZ")
    pump(200)
    say("       -> signals seen: %s" % [n_ for n_, _ in p.events])
    say("       -> bold now covers chars [0,%d): inherited WITHOUT an apply-tag signal? %s"
        % (7, "YES" if not any(n_ == "apply-tag" for n_, _ in p.events) else "NO"))
    say("   (c) REAL TYPING inside the bold run:")
    p.buf.place_cursor(p.buf.get_iter_at_offset(3))
    p.view.grab_focus(); pump(200)
    p.events = []
    xdo("type", "--delay", "60", "Q"); pump(700)
    say("       -> signals seen: %s" % [n_ for n_, _ in p.events])
    it = p.buf.get_iter_at_offset(3)
    say("       -> typed char has bold? %s" % it.has_tag(bold))
    say("   (d) remove_tag:")
    p.events = []
    p.buf.remove_tag(bold, p.buf.get_iter_at_offset(0), p.buf.get_iter_at_offset(3))
    pump(200)
    say("       -> signals seen: %s" % [n_ for n_, _ in p.events])
    say("   (e) 'changed' also fires for a tag change? %s"
        % ("YES" if any(n_ == "changed" for n_, _ in p.events) else "NO"))

    say("\n--- 4.9 NATIVE UNDO through Ctrl+Z: what does it look like on the wire? ---")
    say("   (undo-plan A6 / R4's `source: native_undo` — is an undo distinguishable "
        "from typing at the signal level?)")
    p.buf.place_cursor(p.buf.get_end_iter())
    p.view.grab_focus(); pump(200)
    p.events = []
    before = p.text()
    xdo("key", "ctrl+z"); pump(900)
    say("   text before=%r" % before)
    say("   text after =%r" % p.text())
    say("   -> signals seen: %s" % [n_ for n_, _ in p.events])
    say("   -> any signal that SAYS 'this was an undo'? %s"
        % ("NO — it is an ordinary delete-range/insert-text pair"
           if p.events else "no signals at all"))

    # =====================================================================
    say("\n########## PROBE 5 — LINKS AS A SYNTHESIZED TIER ##########")
    p.recording = False
    p.buf.set_text("")
    p.recording = False
    link = p.buf.create_tag("kaya-link-0", underline=Pango.Underline.SINGLE,
                            foreground="#0b57d0")
    p.link_urls[link] = "https://example.invalid/kaya"
    p.buf.insert(p.buf.get_end_iter(), "plain words ")
    s = p.buf.get_char_count()
    p.buf.insert(p.buf.get_end_iter(), "CLICKME")
    e2 = p.buf.get_char_count()
    p.buf.apply_tag(link, p.buf.get_iter_at_offset(s), p.buf.get_iter_at_offset(e2))
    p.buf.insert(p.buf.get_end_iter(), " and plain tail")
    pump(400)
    say("text=%r" % p.text())
    say("link tag covers chars [%d,%d) = BYTES [%d,%d); side table holds %r"
        % (s, e2, p.byte_off(p.buf.get_iter_at_offset(s)),
           p.byte_off(p.buf.get_iter_at_offset(e2)), p.link_urls[link]))

    def widget_xy_for_char(off):
        """buffer coords of a character -> WIDGET coords (the transform under test)."""
        it = p.buf.get_iter_at_offset(off)
        rect = p.view.get_iter_location(it)        # BUFFER coordinates
        wx, wy = p.view.buffer_to_window_coords(Gtk.TextWindowType.WIDGET,
                                                rect.x + rect.width // 2,
                                                rect.y + rect.height // 2)
        return rect, wx, wy

    rect, lx, ly = widget_xy_for_char(s + 3)
    say("get_iter_location(char %d) = buffer rect x=%d y=%d w=%d h=%d"
        % (s + 3, rect.x, rect.y, rect.width, rect.height))
    say("buffer_to_window_coords(WIDGET, ...) = widget (%d,%d)" % (lx, ly))
    # widget -> window-relative: the view sits inside the ScrolledWindow inside the window
    pt = p.view.compute_point(p.win, Graphene.Point().init(lx, ly))
    ok, wpt = (pt if isinstance(pt, tuple) else (True, pt))
    say("view.compute_point(window) = ok=%s (%.0f,%.0f)  [widget->toplevel offset]"
        % (ok, wpt.x, wpt.y))

    say("\n--- 5.1 REAL CLICK on the link ---")
    p.activated = []
    if wid:
        xdo("mousemove", "--window", wid, str(int(wpt.x)), str(int(wpt.y)))
        pump(300)
        say("   hover cursor now: %r" % getattr(p, "_last_cursor", None))
        xdo("click", "--window", wid, "1")
        pump(200)
        xdo("click", "1")           # XTEST fallback at the same pointer position
        pump(700)
    say("   activations = %s" % p.activated)

    say("\n--- 5.2 REAL CLICK on plain text (must NOT activate) ---")
    rect2, px, py = widget_xy_for_char(2)
    pt2 = p.view.compute_point(p.win, Graphene.Point().init(px, py))
    ok2, wpt2 = (pt2 if isinstance(pt2, tuple) else (True, pt2))
    p.activated = []
    if wid:
        xdo("mousemove", "--window", wid, str(int(wpt2.x)), str(int(wpt2.y)))
        pump(300)
        say("   hover cursor now: %r" % getattr(p, "_last_cursor", None))
        xdo("click", "1"); pump(700)
    say("   activations = %s" % p.activated)

    say("\n--- 5.3 the transform, stated ---")
    say("   gesture 'released' (x,y)  : WIDGET coords of the GtkTextView")
    say("   gtk_text_view_window_to_buffer_coords(view, GTK_TEXT_WINDOW_WIDGET, x, y)")
    say("   gtk_text_view_get_iter_at_location(view, &iter, bx, by) -> (over_text, iter)")
    say("   gtk_text_iter_get_tags/has_tag(iter, link_tag) -> side table lookup -> activate")
    say("   NOTE (measured in p6_final 6.3 and p6b_margin): get_iter_at_location")
    say("   answers over_text=FALSE past the last character on a line and still")
    say("   returns the LINE-END iter. That iter never carries a link tag, because a")
    say("   tag's end toggle is exclusive, so the right margin cannot activate a link")
    say("   by accident on GTK. Honour over_text for caret placement, not for safety.")

    say("\nDONE")
    p.win.close()
    return False

loop = GLib.MainLoop()

def _run():
    try:
        main()
    except Exception:
        import traceback
        say("\nEXCEPTION:\n" + traceback.format_exc())
    loop.quit()
    return False

GLib.idle_add(_run)
GLib.timeout_add_seconds(150, lambda: (loop.quit(), False)[-1])
loop.run()
