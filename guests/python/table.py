"""The table scene: column headers and click-to-sort on the For
vocabulary (docs/tables-plan.md). A header click is a REQUEST — this
guest reorders its collection BY KEY (the reorder scene's idiom) and
re-declares the header with the new indicator; the platform sorts
nothing. The byte-frozen contract is tools/scenes/table.steps.

Build the library first (cargo build), then:
    KAYA_SELFTEST=table python3 guests/python/table.py
"""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Item:
    name: str
    size: str


app = kaya.App()

# The guest's sort policy — the platform never has one: clicking the
# sorted column flips it, clicking another starts ascending.
state = {"sorted": None}


def on_sort(column):
    current = state["sorted"]
    descending = current is not None and current[0] == column and not current[1]
    state["sorted"] = (column, descending)
    entries = items.items()
    key_of = (lambda e: e[1].name) if column == 0 else (lambda e: e[1].size)
    entries.sort(key=key_of, reverse=descending)
    # Keys, never indices: moving each key to the end in the target
    # order leaves the collection sorted.
    for key, _ in entries:
        items.move_to_end(key)
    indicator = kaya.Sort.desc(column) if descending else kaya.Sort.asc(column)
    items.set_columns("Name", "Size", sort=indicator)


with app.window():
    items = kaya.collection(Item)
    # The root is a row so the For's container is the scene's only
    # column-kind widget (the reorder scene's rule). The table IS the
    # For, with headers on the same loop that stamps the rows.
    with kaya.row():
        # Grown on purpose: this scene asserts the fill-and-scroll
        # viewport, the grown half of the empty-row ruling — ungrown
        # would hug its rows (tables-plan decision 8).
        for item in items.columns("Name", "Size", on_sort=on_sort, grow=1):
            with kaya.row():
                kaya.label(bind=item.name)
                kaya.label(bind=item.size)
    for key, name, size in [("b", "banana", "30"), ("a", "apple", "10"), ("c", "cherry", "20")]:
        items.insert(key, Item(name=name, size=size))

sys.exit(app.run())
