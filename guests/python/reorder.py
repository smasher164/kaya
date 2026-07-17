"""The reorder scene: order as collection data, end to end. Three
stamped rows and two buttons that never touch a widget — each handler
repositions an entry by key (collection_move on the wire, move_child at
the toolkit), and the selftest's expect_order reads the toolkit's
actual child order back, which no creation-ordered registry could
observe. The root is a row so the For's container is the scene's only
column-kind widget: languages disagree on whether containers are
created before or after their children, and column#0 must name the
same widget everywhere.

The backend selftest (KAYA_SELFTEST=reorder) checks "a|b|c", clicks
rotate (first entry to the end), checks "b|c|a", clicks lift (last
entry before the first), and checks "a|b|c" again.

Build the library first (cargo build), then:
    KAYA_SELFTEST=reorder python3 guests/python/reorder.py
"""

import pathlib
import sys
from dataclasses import dataclass

_here = pathlib.Path(__file__).resolve().parent
for _base in [_here, *_here.parents]:
    if (_base / "bindings" / "python").is_dir():
        sys.path.insert(0, str(_base / "bindings" / "python"))
        break

import kaya_app as kaya


@dataclass
class Item:
    title: str


app = kaya.App()


def on_rotate():
    # First entry to the end. The model owns the order, so the handler
    # asks it which key is first — it never counts widgets.
    first = items.keys()[0]
    items.move_to_end(first)


def on_lift():
    # Last entry to the front: move_to_front is sugar for move_before
    # the current first key — the same wire op, keys never indices.
    items.move_to_front(items.keys()[-1])


with app.window():
    items = kaya.collection(Item)
    with kaya.row():
        kaya.button("rotate", on_click=on_rotate)
        kaya.button("lift", on_click=on_lift)
        with kaya.for_each(items) as item:
            kaya.label(bind=item.title)
    for key in ["a", "b", "c"]:
        items.insert(key, Item(title=key))

sys.exit(app.run())
