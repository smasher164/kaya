#!/usr/bin/env python3
"""Probe 3b app: the AT-SPI follow-ups — foreground colour, size units, whether a
custom tag NAME crosses, and whether an attribute change EMITS an AT-SPI event."""
import json
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Pango, GLib

def main():
    app = Gtk.Application(application_id="dev.kaya.richtextprobe2")
    def on_activate(a):
        buf = Gtk.TextBuffer()
        view = Gtk.TextView(buffer=buf); view.set_editable(True)
        t = {}
        t["fg_red"]     = buf.create_tag("fg_red", foreground="#ff0000")
        t["fg_blue"]    = buf.create_tag("fg_blue", foreground="rgb(0,102,204)")
        t["fg_rgba"]    = buf.create_tag("fg_rgba", foreground="green")
        t["size_pts"]   = buf.create_tag("size_pts", size_points=24.0)
        t["size_units"] = buf.create_tag("size_units", size=24 * Pango.SCALE)
        t["scale15"]    = buf.create_tag("scale15", scale=1.5)
        t["named"]      = buf.create_tag("kaya-link-7")           # name only, no props
        t["rise"]       = buf.create_tag("rise", rise=5000)
        t["justify"]    = buf.create_tag("justify", justification=Gtk.Justification.CENTER)
        t["wrapnone"]   = buf.create_tag("wrapnone", wrap_mode=Gtk.WrapMode.NONE)
        t["lang"]       = buf.create_tag("lang", language="fr")
        t["invisible"]  = buf.create_tag("invisible", invisible=True)
        t["bold_it"]    = buf.create_tag("bold_it", weight=Pango.Weight.BOLD,
                                          style=Pango.Style.ITALIC)
        spans = []
        for name in ["fg_red","fg_blue","fg_rgba","size_pts","size_units","scale15",
                     "named","rise","justify","wrapnone","lang","bold_it"]:
            s = buf.get_char_count()
            buf.insert(buf.get_end_iter(), name)
            e = buf.get_char_count()
            buf.apply_tag(t[name], buf.get_iter_at_offset(s), buf.get_iter_at_offset(e))
            buf.insert(buf.get_end_iter(), " ")
            spans.append({"tag": name, "char_start": s, "char_end": e, "text": name})
        buf.insert(buf.get_end_iter(), "TAILPLAIN")
        # a BOUNDARY case: two adjacent differently-tagged runs, no gap
        b1 = buf.get_char_count(); buf.insert(buf.get_end_iter(), "AAA")
        b2 = buf.get_char_count(); buf.insert(buf.get_end_iter(), "BBB")
        b3 = buf.get_char_count()
        buf.apply_tag(t["fg_red"], buf.get_iter_at_offset(b1), buf.get_iter_at_offset(b2))
        buf.apply_tag(t["bold_it"], buf.get_iter_at_offset(b2), buf.get_iter_at_offset(b3))
        spans.append({"tag":"BOUNDARY_A","char_start":b1,"char_end":b2,"text":"AAA"})
        spans.append({"tag":"BOUNDARY_B","char_start":b2,"char_end":b3,"text":"BBB"})
        # a LATE tag, applied after the reader has connected, to test event emission
        late_start = buf.get_char_count()
        buf.insert(buf.get_end_iter(), " LATEBOLD")
        late_end = buf.get_char_count()
        spans.append({"tag":"LATE","char_start":late_start,"char_end":late_end,"text":" LATEBOLD"})
        sw = Gtk.ScrolledWindow(); sw.set_child(view); sw.set_vexpand(True)
        win = Gtk.ApplicationWindow(application=a, title="kaya-richtext-probe2")
        win.set_default_size(900, 500); win.set_child(sw); win.present()
        json.dump({"spans": spans,
                   "text": buf.get_text(buf.get_start_iter(), buf.get_end_iter(), True)},
                  open("/out/p3b_spans.json","w",encoding="utf-8"), indent=1)
        late = buf.create_tag("latebold", weight=Pango.Weight.BOLD)
        def apply_late():
            buf.apply_tag(late, buf.get_iter_at_offset(late_start),
                          buf.get_iter_at_offset(late_end))
            print("APPLIED LATE TAG", flush=True)
            return False
        GLib.timeout_add_seconds(9, apply_late)
        GLib.timeout_add_seconds(60, lambda: (a.quit(), False)[-1])
    app.connect("activate", on_activate)
    app.run([])
main()
