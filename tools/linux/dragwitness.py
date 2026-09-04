#!/usr/bin/env python3
"""A FOREIGN drag-and-drop app, for the cross-app witness legs
(docs/dnd-plan.md D9, §5 step 7).

Nothing here links kaya. It is a stock GTK4 client that offers a drag and
takes one, so a leg can drive a REAL pointer between its window and kaya's
and read both sides — the clipboard milestone's rule that every assertion
crosses a process boundary (docs/clipboard-plan.md §5b), one input device
over.

    dragwitness.py --text <s> --file <path>

Two labels: `source` offers `<s>` as text AND `<path>` as a file, `target`
takes text and files and says what arrived. Everything it learns goes to
stdout under WITNESS, line by line, because the leg reads it as it runs:

    WITNESS geometry tx=<x> ty=<y> source=<x>,<y>,<w>,<h> target=<x>,<y>,<w>,<h>
    WITNESS ready
    WITNESS got text <s>
    WITNESS got file <name> <bytes> bytes
    WITNESS handed over <copy|move|none>

The geometry is in the window's CONTENT coordinates with its own surface
transform beside it, which is what tools/linux/dragdrive.py adds the
server's window origin to.

Runs INSIDE the container under a leg's environment; no dev-shell prelude,
like the other in-container python here.
"""
import argparse
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, GObject, Gtk


def say(line):
    print(f"WITNESS {line}", flush=True)


def build(app, text, path):
    win = Gtk.ApplicationWindow(application=app, title="dragwitness")
    win.set_default_size(360, 200)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
    box.set_margin_top(24)
    box.set_margin_bottom(24)
    box.set_margin_start(24)
    box.set_margin_end(24)

    source = Gtk.Label(label="witness source")
    source.set_size_request(300, 60)
    target = Gtk.Label(label="witness target")
    target.set_size_request(300, 60)
    box.append(source)
    box.append(target)
    win.set_child(box)

    # THE SOURCE. One item, two representations. The file rides
    # `text/uri-list` as RAW BYTES with the RFC's CRLF terminator, which is
    # the only files spelling kaya's accept list names
    # (crates/kaya/src/gtk.rs's accept_formats) and the shape every foreign
    # toolkit puts on the wire. NOT `gdk_content_provider_new_typed`: it
    # takes a GType and varargs and is not introspectable, so PyGObject has
    # no such attribute (measured 2026-09-03, and the traceback arrives
    # inside the prepare handler where a drag just silently offers nothing).
    drag = Gtk.DragSource()
    drag.set_actions(Gdk.DragAction.COPY)

    def prepare(_source, _x, _y):
        uri = Gio.File.new_for_path(path).get_uri()
        return Gdk.ContentProvider.new_union([
            Gdk.ContentProvider.new_for_bytes(
                "text/uri-list", GLib.Bytes.new(f"{uri}\r\n".encode())),
            Gdk.ContentProvider.new_for_value(GObject.Value(str, text)),
        ])

    drag.connect("prepare", prepare)
    drag.connect("drag-end", lambda _s, d, _del: say(
        f"handed over {action_word(d.get_selected_action())}"))
    source.add_controller(drag)

    # THE TARGET, a plain GtkDropTarget: the witness only has to say what
    # arrived, so the synchronous surface is the whole need.
    drop = Gtk.DropTarget.new(GObject.TYPE_NONE, Gdk.DragAction.COPY)
    drop.set_gtypes([GObject.TYPE_STRING, Gdk.FileList, Gio.File])
    drop.connect("drop", on_drop)
    target.add_controller(drop)

    def report():
        native = win.get_native()
        tx, ty = native.get_surface_transform()
        rects = []
        for widget in (source, target):
            ok, r = widget.compute_bounds(win)
            if not ok:
                return True
            rects.append(f"{int(r.get_x())},{int(r.get_y())},"
                         f"{int(r.get_width())},{int(r.get_height())}")
        say(f"geometry tx={int(tx)} ty={int(ty)} "
            f"source={rects[0]} target={rects[1]}")
        say("ready")
        return False

    win.present()
    GLib.timeout_add(200, report)


def action_word(action):
    if action & Gdk.DragAction.MOVE:
        return "move"
    if action & Gdk.DragAction.COPY:
        return "copy"
    return "none"


def on_drop(_target, value, _x, _y):
    """What arrived, in the words of whatever it turned out to be. A drop
    this cannot name is a finding, never silence."""
    if isinstance(value, str):
        say(f"got text {value}")
        return True
    files = []
    if isinstance(value, Gdk.FileList):
        files = value.get_files()
    elif isinstance(value, Gio.File):
        files = [value]
    if files:
        for f in files:
            try:
                data = f.load_contents(None)[1]
            except GLib.Error as e:
                say(f"got file {f.get_basename()} UNREADABLE {e.message}")
                continue
            say(f"got file {f.get_basename()} {len(data)} bytes")
        return True
    say(f"got a {type(value).__name__} this witness cannot name")
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--file", required=True)
    args = ap.parse_args()

    app = Gtk.Application(application_id="dev.kaya.dragwitness")
    app.connect("activate", lambda a: build(a, args.text, args.file))
    return app.run([])


if __name__ == "__main__":
    sys.exit(main())
