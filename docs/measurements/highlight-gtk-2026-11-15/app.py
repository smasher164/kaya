#!/usr/bin/env python3
"""docs/highlight-plan.md §3, GTK's measurement: two background tags over one
range paint by priority, and the AT-SPI attributes of a mark tag that sets
background_full_height FALSE. Writes /out/pixels.txt and /out/spans.json."""
import json
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gtk, Gdk, GLib, GdkPixbuf

WORDS = ["MARKONLY", "FINDONLY", "FINDOVERMARK", "MARKOVERCODE", "LATEMARK", "CODEONLY"]
TEXT = " ".join(WORDS)
OUT = []


def say(s):
    OUT.append(s)
    print(s, flush=True)
    open("/out/pixels.txt", "w").write("\n".join(OUT) + "\n")


def rgba(hexs):
    c = Gdk.RGBA()
    c.parse(hexs)
    return c


def span(word):
    s = TEXT.index(word)
    return s, s + len(word)


def main():
    app = Gtk.Application(application_id="dev.kaya.hlprobe")

    def activate(app):
        win = Gtk.ApplicationWindow(application=app, title="hlprobe")
        win.set_default_size(1200, 120)
        view = Gtk.TextView()
        view.set_pixels_above_lines(10)
        view.set_pixels_below_lines(10)
        buf = view.get_buffer()
        buf.set_text(TEXT)
        table = buf.get_tag_table()
        code = Gtk.TextTag.new("kaya-rich-code")
        code.set_property("background-rgba", rgba("#c8c8c8"))
        table.add(code)
        find = Gtk.TextTag.new("kaya-highlight")
        find.set_property("background", "#ffe066")
        find.set_property("background-full-height", True)
        table.add(find)
        # The mark, minted AFTER find (as a rich tag would be) with its
        # priority put just below find's.
        mark = Gtk.TextTag.new("kaya-rich-v-highlight=yellow")
        mark.set_property("background-rgba", rgba("#F7E8AF"))
        mark.set_property("background-full-height", False)
        table.add(mark)
        mark.set_priority(find.get_priority())
        # The control: a second mark minted after find and left at the top.
        late = Gtk.TextTag.new("kaya-rich-v-highlight=blue")
        late.set_property("background-rgba", rgba("#D5EBFF"))
        late.set_property("background-full-height", False)
        table.add(late)
        say("priorities code=%d find=%d mark=%d late=%d" % (code.get_priority(), find.get_priority(), mark.get_priority(), late.get_priority()))

        def apply(tag, word):
            s, e = span(word)
            buf.apply_tag(tag, buf.get_iter_at_offset(s), buf.get_iter_at_offset(e))

        apply(mark, "MARKONLY")
        apply(find, "FINDONLY")
        apply(mark, "FINDOVERMARK")
        apply(find, "FINDOVERMARK")
        apply(code, "MARKOVERCODE")
        apply(mark, "MARKOVERCODE")
        apply(late, "LATEMARK")
        apply(find, "LATEMARK")
        apply(code, "CODEONLY")
        json.dump({"text": TEXT, "spans": [dict(word=w, start=span(w)[0], end=span(w)[1]) for w in WORDS]},
                  open("/out/spans.json", "w"))
        win.set_child(view)
        win.present()

        def shoot():
            w, h = view.get_width(), view.get_height()
            paintable = Gtk.WidgetPaintable.new(view)
            snap = Gtk.Snapshot()
            paintable.snapshot(snap, w, h)
            node = snap.to_node()
            tex = view.get_native().get_renderer().render_texture(node, None)
            tex.save_to_png("/out/view.png")
            pb = GdkPixbuf.Pixbuf.new_from_file("/out/view.png")
            px, stride, nch = pb.get_pixels(), pb.get_rowstride(), pb.get_n_channels()
            scale = pb.get_width() / w

            def at(x, y):
                o = int(y * scale) * stride + int(x * scale) * nch
                return "%02X%02X%02X" % (px[o], px[o + 1], px[o + 2])

            for word in WORDS:
                s, e = span(word)
                a = view.get_iter_location(buf.get_iter_at_offset(s))
                b = view.get_iter_location(buf.get_iter_at_offset(e))
                ly, lh = view.get_line_yrange(buf.get_iter_at_offset(s))
                x0, y0 = view.buffer_to_window_coords(Gtk.TextWindowType.WIDGET, a.x, ly)
                x1, _ = view.buffer_to_window_coords(Gtk.TextWindowType.WIDGET, b.x, ly)
                gx, gy = view.buffer_to_window_coords(Gtk.TextWindowType.WIDGET, a.x, a.y)
                counts = {}
                for x in range(x0 + 1, x1 - 1):
                    for y in range(gy, gy + a.height):
                        c = at(x, y)
                        counts[c] = counts.get(c, 0) + 1
                top = sorted(counts.items(), key=lambda kv: -kv[1])[:2]
                # The line's gap above the glyph box (pixels_above_lines=10).
                gap = at((x0 + x1) // 2, y0 + 3)
                say("%-13s glyphbox commonest=%s  above-line gap=%s" % (word, top, gap))
            say("DONE")
            GLib.timeout_add_seconds(25, lambda: (app.quit(), False)[1])
            return False

        GLib.timeout_add(1500, shoot)

    app.connect("activate", activate)
    app.run([])


main()
