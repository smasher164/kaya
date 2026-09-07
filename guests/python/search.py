"""The search scene (tools/scenes/search.steps): a search field filtering a
list on every keystroke, the app owning the filter (docs/search-plan.md
S9) — the visible set is a diff of removes and inserts by key."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Item:
    name: str


ITEMS = ["apple", "banana", "cherry", "mango"]

app = kaya.App()

visible = list(ITEMS)


def on_query(text):
    global visible
    query = text.lower()
    wanted = [name for name in ITEMS if query in name]
    # A DIFF, never clear-and-refill: only the rows whose membership
    # changed move (docs/search-plan.md S9).
    for name in visible:
        if name not in wanted:
            items.remove(name)
    for name in wanted:
        if name not in visible:
            items.insert(name, Item(name=name))
    # Insertion order is arrival order, so a row coming back lands last;
    # walking the wanted keys to the end in order puts the list back in
    # ITEMS order.
    for name in wanted:
        items.move_to_end(name)
    count.set(f"{len(ITEMS)} items" if query == ""
              else f"{len(wanted)} of {len(ITEMS)} match")
    visible = wanted


with app.window():
    items = kaya.collection(Item)
    count = kaya.signal(f"{len(ITEMS)} items")

    with kaya.column():
        (kaya.search(placeholder="Search", on_change=on_query)
            .a11y_id("find").a11y_label("Find items"))
        kaya.label(bind=count).a11y_id("count")
        # The For IS the list: expect_order reads its label children.
        for item in items.rows(a11y_id="list"):
            kaya.label(bind=item.name)

    for name in ITEMS:
        items.insert(name, Item(name=name))

sys.exit(app.run())
