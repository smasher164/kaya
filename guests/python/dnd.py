"""The drag-and-drop scene (tools/scenes/dnd.steps; docs/dnd-plan.md D1, D8).
THE ROOT IS A ROW so column#0 is the reorderable For's container."""

import os
import pathlib
import sys
import tempfile
from dataclasses import dataclass

import kaya


@dataclass
class Item:
    title: str


app = kaya.App()

# The file the scene drops as a FOREIGN source (D6), written by the guest
# at $TMP/kaya-dnd-$PID/dropped.txt — the picker and clipboard scenes'
# convention. `tempfile.gettempdir()` and NEVER `TMPDIR` (docs/traps.md).
dropped_dir = pathlib.Path(tempfile.gettempdir()) / f"kaya-dnd-{os.getpid()}"
dropped_dir.mkdir(parents=True, exist_ok=True)
(dropped_dir / "dropped.txt").write_text("dropped bytes")


def read_back(picked):
    try:
        handle, _seekable = picked.open(kaya.wire.FILE_MODE_READ)
        with handle as f:
            return f.read().decode()
    except OSError as e:
        return f"open failed: {e}"


def on_dropped(name, target, dropped):
    op = dropped.operation or "none"
    match dropped.clip:
        case kaya.Representation.Text(text):
            drop_status.set(f"{name} got text {text} ({op})")
            target.set(text)
        case kaya.Representation.Custom(ident, data):
            drop_status.set(f"{name} got {ident} {len(data)} bytes ({op})")
        case kaya.Representation.Files(files):
            # A dropped file IS a picked file (D6): read it back through
            # the same table the picker fills.
            said = ", ".join(f"{f.name} {read_back(f)}" for f in files)
            drop_status.set(f"{name} got {said} ({op})")
        case other:
            drop_status.set(f"{name} got {other!r} ({op})")
    # A same-app MOVE removes its original in the same batch (D2).
    if dropped.operation == kaya.OP_MOVE:
        source_text.set("moved out")
        source.draggable()


def on_drag_ended(operation):
    drag_status.set(f"drag ended {operation or 'none'}")


def on_item_dropped(key, dropped):
    op = dropped.operation or "none"
    match dropped.clip:
        case kaya.Representation.Text(text):
            drop_status.set(f"item {key} got text {text} ({op})")
        case other:
            drop_status.set(f"item {key} got {other!r} ({op})")


def node_drag_ended(what):
    def ended(key, operation):
        drag_status.set(f"{what} {key} drag ended {operation or 'none'}")
    return ended


def on_rename():
    # The bound payload follows the row's record (docs/dnd-plan.md §4).
    items2.update("y", Item(title="yy"))


def on_reorder(dropped):
    # The moved row's key rides as the kaya-private custom representation;
    # the anchor is the row it landed on (D8).
    if not isinstance(dropped.clip, kaya.Representation.Custom):
        return
    moved = dropped.clip.bytes.decode()
    if not dropped.anchor:
        return
    if dropped.before:
        items.move_before(moved, dropped.anchor[0])
    else:
        items.move_after(moved, dropped.anchor[0])


with app.window(title="dnd"):
    items = kaya.collection(Item)
    items2 = kaya.collection(Item)
    drop_status = kaya.signal("no drop yet")
    drag_status = kaya.signal("no drag yet")
    source_text = kaya.signal("hello")
    text_target = kaya.signal("text target")
    note_target = kaya.signal("note target")
    files_target = kaya.signal("files target")
    with kaya.row():
        for item in items.rows(reorderable=True, on_drop=on_reorder,
                               a11y_id="rows"):
            (kaya.label(bind=item.title)
             .a11y_id("row")
             .on_drag_ended(node_drag_ended("row")))
        with kaya.column():
            source = kaya.label(bind=source_text)  # label#0
            source.draggable(text="hello",
                             custom={"dev.kaya/note": b"note!"},
                             operations=(kaya.OP_COPY, kaya.OP_MOVE))
            (kaya.label(bind=text_target)  # label#1
             .accepts(kaya.ACCEPT_TEXT)
             .drop_target(kaya.OP_COPY)
             .on_drop(lambda d: on_dropped("text target", text_target, d)))
            (kaya.label(bind=note_target)  # label#2
             .accepts("dev.kaya/note")
             .drop_target(kaya.OP_COPY, kaya.OP_MOVE)
             .on_drop(lambda d: on_dropped("note target", note_target, d)))
            (kaya.label(bind=files_target)  # label#3
             .accepts(kaya.ACCEPT_FILES)
             .drop_target(kaya.OP_COPY)
             .on_drop(lambda d: on_dropped("files target", files_target, d)))
            kaya.label(bind=drop_status)  # label#4
            kaya.label(bind=drag_status)  # label#5
        # THE TEMPLATE ZONE (docs/dnd-plan.md §4): every stamped item is a
        # text destination, and its payload IS the row's own field —
        # resolved per copy and re-declared when the field changes.
        for item in items2.rows(a11y_id="items"):
            (kaya.label(bind=item.title)
             .a11y_id("item")
             .accepts(kaya.ACCEPT_TEXT)
             .drop_target(kaya.OP_COPY)
             .draggable(text=item.title, operations=(kaya.OP_COPY,))
             .on_drop(on_item_dropped)
             .on_drag_ended(node_drag_ended("item")))
        kaya.button("rename y", on_click=on_rename)  # button#0
    source.on_drag_ended(on_drag_ended)
    for key in ["a", "b", "c"]:
        items.insert(key, Item(title=key))
    for key in ["x", "y"]:
        items2.insert(key, Item(title=key))

sys.exit(app.run())
