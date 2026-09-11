#!/usr/bin/env python3
"""Probe 3c app: colour serialization matrix + a POSITIVE CONTROL for the AT-SPI
event listener (an insert, which MUST emit object:text-changed) before the thing
under test (a tag application, which may or may not emit)."""
import json
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Pango, GLib

COLOURS = ["#ff0000", "#00ff00", "#0000ff", "#ffffff", "#808080", "#0066cc", "#123456"]

def main():
    app = Gtk.Application(application_id="dev.kaya.richtextprobe3")
    def on_activate(a):
        buf = Gtk.TextBuffer()
        view = Gtk.TextView(buffer=buf); view.set_editable(True)
        spans = []
        for i, c in enumerate(COLOURS):
            fg = buf.create_tag("fg%d" % i, foreground=c)
            bg = buf.create_tag("bg%d" % i, background=c)
            for kind, tag in (("fg", fg), ("bg", bg)):
                s = buf.get_char_count()
                buf.insert(buf.get_end_iter(), "%s%s" % (kind, c.replace("#", "")))
                e = buf.get_char_count()
                buf.apply_tag(tag, buf.get_iter_at_offset(s), buf.get_iter_at_offset(e))
                buf.insert(buf.get_end_iter(), " ")
                spans.append({"tag": "%s %s" % (kind, c), "char_start": s, "char_end": e})
        buf.insert(buf.get_end_iter(), "\nCONTROLZONE")
        czs = buf.get_char_count() - len("CONTROLZONE")
        cze = buf.get_char_count()
        sw = Gtk.ScrolledWindow(); sw.set_child(view); sw.set_vexpand(True)
        win = Gtk.ApplicationWindow(application=a, title="kaya-richtext-probe3")
        win.set_default_size(1000, 500); win.set_child(sw); win.present()
        json.dump({"spans": spans}, open("/out/p3c_spans.json","w",encoding="utf-8"), indent=1)
        late = buf.create_tag("latebold", weight=Pango.Weight.BOLD)
        def ctl():
            buf.insert(buf.get_end_iter(), "-INSERTED")
            print("CONTROL: inserted text (must emit object:text-changed)", flush=True)
            return False
        def tagit():
            buf.apply_tag(late, buf.get_iter_at_offset(czs), buf.get_iter_at_offset(cze))
            print("TEST: applied bold tag over CONTROLZONE", flush=True)
            return False
        def delit():
            buf.delete(buf.get_iter_at_offset(czs), buf.get_iter_at_offset(czs+3))
            print("CONTROL: deleted 3 chars", flush=True)
            return False
        GLib.timeout_add_seconds(8,  ctl)
        GLib.timeout_add_seconds(12, tagit)
        GLib.timeout_add_seconds(16, delit)
        GLib.timeout_add_seconds(60, lambda: (a.quit(), False)[-1])
    app.connect("activate", on_activate)
    app.run([])
main()
