#!/usr/bin/env python3
"""Probe 3 app half: a GtkTextView (in a GtkScrolledWindow, editable — kaya's textarea
shape) carrying one tag per rich-text vocabulary item, held open for an AT-SPI reader.

Also does the IN-PROCESS read through GtkAccessibleText (GTK 4.14+), which is the same
data the bridge publishes, before the reader ever connects.
"""
import json, sys
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Pango, GLib, Gdk

SEGMENTS = []   # (tagname, text)

def build_buffer(buf):
    tt = buf.get_tag_table()
    def tag(name, **props):
        t = buf.create_tag(name, **props)
        return t
    tags = {
        "bold":      tag("bold",      weight=Pango.Weight.BOLD),
        "italic":    tag("italic",    style=Pango.Style.ITALIC),
        "underline": tag("underline", underline=Pango.Underline.SINGLE),
        "strike":    tag("strike",    strikethrough=True),
        "mono":      tag("mono",      family="Monospace"),
        "h_scale":   tag("h_scale",   scale=1.5, weight=Pango.Weight.BOLD),
        "h_points":  tag("h_points",  size_points=24.0, weight=Pango.Weight.BOLD),
        "link":      tag("link",      underline=Pango.Underline.SINGLE, foreground="#0066cc"),
        "namedonly": tag("namedonly"),                       # a NAME and nothing else
        "bg":        tag("bg",        background="#ffff00"),
        "quote":     tag("quote",     left_margin=40, indent=0),
    }
    layout = [
        (None, "plain "),
        ("bold", "bold"), (None, " "),
        ("italic", "italic"), (None, " "),
        ("underline", "under"), (None, " "),
        ("strike", "strike"), (None, " "),
        ("mono", "mono"), (None, "\n"),
        ("h_scale", "HeadScale"), (None, "\n"),
        ("h_points", "HeadPoints"), (None, "\n"),
        ("link", "clickme"), (None, " "),
        ("namedonly", "namedonly"), (None, " "),
        ("bg", "bg"), (None, "\n"),
        ("quote", "a quoted paragraph"), (None, "\n"),
    ]
    spans = []
    for name, s in layout:
        start = buf.get_char_count()
        buf.insert(buf.get_end_iter(), s)
        end = buf.get_char_count()
        if name:
            buf.apply_tag(tags[name], buf.get_iter_at_offset(start), buf.get_iter_at_offset(end))
        spans.append({"tag": name, "text": s, "char_start": start, "char_end": end})
    # the link also carries the custom NAME, applied on top of the visual tag
    for sp in spans:
        if sp["tag"] == "link":
            buf.apply_tag(tags["namedonly"], buf.get_iter_at_offset(sp["char_start"]),
                          buf.get_iter_at_offset(sp["char_end"]))
    return spans

def inproc_read(view, spans, log):
    log("=== IN-PROCESS GtkAccessibleText read (GTK 4.14+ interface, what the bridge publishes) ===")
    has = isinstance(view, Gtk.AccessibleText)
    log("GtkTextView implements GtkAccessibleText: %s" % has)
    if not has:
        return
    for sp in spans:
        if sp["tag"] is None or not sp["text"].strip():
            continue
        off = (sp["char_start"] + sp["char_end"]) // 2
        try:
            res = Gtk.AccessibleText.get_attributes(view, off)
        except Exception as e:
            log("  offset %-3d tag=%-10s ERROR %r" % (off, sp["tag"], e)); continue
        log("  offset %-3d tag=%-10s -> %s" % (off, sp["tag"], fmt_gtk_attrs(res)))
    try:
        d = Gtk.AccessibleText.get_default_attributes(view)
        log("  default attributes -> %s" % fmt_gtk_attrs(d))
    except Exception as e:
        log("  default attributes ERROR %r" % e)

def fmt_gtk_attrs(res):
    # (ok, ranges, names, values) in some binding shape; print defensively
    try:
        ok = res[0]; rest = res[1:]
    except Exception:
        return repr(res)
    out = ["ok=%s" % ok]
    names = values = ranges = None
    for item in rest:
        if item is None: continue
        if isinstance(item, (list, tuple)) and item and isinstance(item[0], str):
            if names is None: names = list(item)
            elif values is None: values = list(item)
        else:
            ranges = item
    if names is not None and values is not None:
        out.append("{" + ", ".join("%s=%s" % (n, v) for n, v in zip(names, values)) + "}")
    else:
        out.append(repr(rest))
    if ranges is not None:
        try:
            out.append("ranges=" + repr([(r.start, r.length) for r in ranges]))
        except Exception:
            out.append("ranges=" + repr(ranges))
    return " ".join(out)

def main():
    log_lines = []
    def log(s):
        log_lines.append(s); print(s, flush=True)

    app = Gtk.Application(application_id="dev.kaya.richtextprobe")
    state = {}

    def on_activate(a):
        buf = Gtk.TextBuffer()
        view = Gtk.TextView(buffer=buf)
        view.set_editable(True)
        view.set_wrap_mode(Gtk.WrapMode.WORD)
        spans = build_buffer(buf)
        sw = Gtk.ScrolledWindow(); sw.set_child(view); sw.set_vexpand(True)
        win = Gtk.ApplicationWindow(application=a)
        win.set_title("kaya-richtext-probe")
        win.set_default_size(900, 500)
        win.set_child(sw)
        win.present()
        state.update(view=view, buf=buf, spans=spans, win=win)
        full = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
        json.dump({"spans": spans, "text": full},
                  open("/out/p3_spans.json", "w", encoding="utf-8"), indent=1)
        log("buffer text = %r" % full)
        log("char_count=%d  utf8 bytes=%d" % (buf.get_char_count(), len(full.encode("utf-8"))))
        for sp in spans:
            if sp["tag"]:
                log("  span %-10s chars [%d,%d) text=%r" % (sp["tag"], sp["char_start"], sp["char_end"], sp["text"]))
        GLib.timeout_add(400, lambda: (inproc_read(view, spans, log),
                                       open("/out/p3_inproc.txt", "w", encoding="utf-8")
                                           .write("\n".join(log_lines) + "\n"), False)[-1])
        # stay alive for the reader; the runner kills us
        GLib.timeout_add_seconds(120, lambda: (a.quit(), False)[-1])

    app.connect("activate", on_activate)
    app.run([])

main()
