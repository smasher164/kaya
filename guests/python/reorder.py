"""The reorder scene: order as collection data, end to end. Each handler
repositions an entry BY KEY and never touches a widget, and expect_order
reads the toolkit's actual child order back.

THE ROOT IS A ROW so the For's container is the scene's only
column-kind widget: languages disagree on whether containers are created
before or after their children, and column#0 must name the same widget
everywhere.

Build the library first (cargo build), then:
    KAYA_SELFTEST=reorder python3 guests/python/reorder.py
"""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Item:
    title: str


app = kaya.App()


def on_rotate():
    # The MODEL owns the order, so the handler asks it which key is
    # first; it never counts widgets.
    first = items.keys()[0]
    items.move_to_end(first)


def on_lift():
    items.move_to_front(items.keys()[-1])


with app.window():
    items = kaya.collection(Item)
    with kaya.row():
        kaya.button("rotate", on_click=on_rotate)
        kaya.button("lift", on_click=on_lift)
        for item in items:
            kaya.label(bind=item.title)
    for key in ["a", "b", "c"]:
        items.insert(key, Item(title=key))

sys.exit(app.run())
