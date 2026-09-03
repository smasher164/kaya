"""The drag-and-drop scene (tools/scenes/dnd.steps; docs/dnd-plan.md D1, D8).
THE ROOT IS A ROW so column#0 is the reorderable For's container."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Item:
    title: str


app = kaya.App()


def on_dropped(name, target, dropped):
    op = dropped.operation or "none"
    match dropped.clip:
        case kaya.Representation.Text(text):
            drop_status.set(f"{name} got text {text} ({op})")
            target.set(text)
        case kaya.Representation.Custom(ident, data):
            drop_status.set(f"{name} got {ident} {len(data)} bytes ({op})")
        case other:
            drop_status.set(f"{name} got {other!r} ({op})")
    # A same-app MOVE removes its original in the same batch (D2).
    if dropped.operation == kaya.OP_MOVE:
        source_text.set("moved out")
        source.draggable()


def on_drag_ended(operation):
    drag_status.set(f"drag ended {operation or 'none'}")


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
    drop_status = kaya.signal("no drop yet")
    drag_status = kaya.signal("no drag yet")
    source_text = kaya.signal("hello")
    text_target = kaya.signal("text target")
    note_target = kaya.signal("note target")
    files_target = kaya.signal("files target")
    with kaya.row():
        for item in items.rows(reorderable=True, on_drop=on_reorder):
            kaya.label(bind=item.title).a11y_id("row")
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
             .drop_target(kaya.OP_COPY))
            kaya.label(bind=drop_status)  # label#4
            kaya.label(bind=drag_status)  # label#5
    source.on_drag_ended(on_drag_ended)
    for key in ["a", "b", "c"]:
        items.insert(key, Item(title=key))

sys.exit(app.run())
