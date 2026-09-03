"""The reorder scene (tools/scenes/reorder.steps). THE ROOT IS A ROW so the
For's container is the only column, and column#0 names it everywhere."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Item:
    title: str


app = kaya.App()


def on_rotate():
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
