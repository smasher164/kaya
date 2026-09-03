"""The table scene (tools/scenes/table.steps): a header click is a REQUEST,
and the platform sorts nothing."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Item:
    name: str
    size: str


app = kaya.App()

# The guest's sort policy; the platform never has one.
state = {"sorted": None}


def on_sort(column):
    current = state["sorted"]
    descending = current is not None and current[0] == column and not current[1]
    state["sorted"] = (column, descending)
    entries = items.items()
    key_of = (lambda e: e[1].name) if column == 0 else (lambda e: e[1].size)
    entries.sort(key=key_of, reverse=descending)
    # Each key to the end, in the target order.
    for key, _ in entries:
        items.move_to_end(key)
    indicator = kaya.Sort.desc(column) if descending else kaya.Sort.asc(column)
    items.set_columns("Name", "Size", sort=indicator)


with app.window():
    items = kaya.collection(Item)
    # The root is a row: the For's container is the only column.
    with kaya.row():
        # Grown on purpose: ungrown, a table hugs its rows.
        for item in items.columns("Name", "Size", on_sort=on_sort, grow=1):
            with kaya.row():
                kaya.label(bind=item.name)
                kaya.label(bind=item.size)
    for key, name, size in [("b", "banana", "30"), ("a", "apple", "10"), ("c", "cherry", "20")]:
        items.insert(key, Item(name=name, size=size))

sys.exit(app.run())
