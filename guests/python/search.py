"""The search scene (tools/scenes/search.steps): a search field filtering a
list on every keystroke, the app owning the predicate (docs/search-plan.md
S9) and each row hiding in place (docs/hidden-plan.md)."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Item:
    name: str
    unmatched: bool


ITEMS = ["apple", "banana", "cherry", "mango"]

app = kaya.App()


def on_query(text):
    query = text.lower()
    for name in ITEMS:
        items.patch(name, unmatched=query not in name)
    wanted = sum(1 for name in ITEMS if query in name)
    count.set(f"{len(ITEMS)} items" if query == ""
              else f"{wanted} of {len(ITEMS)} match")


with app.window(title="search"):
    items = kaya.collection(Item)
    count = kaya.signal(f"{len(ITEMS)} items")

    with kaya.column():
        (kaya.search(placeholder="Search", on_change=on_query)
            .a11y_id("find").a11y_label("Find items"))
        kaya.label(bind=count).a11y_id("count")
        # The For IS the list: expect_order reads its label children.
        for item in items.rows(a11y_id="list"):
            kaya.label(bind=item.name).hidden(item.unmatched)

    for name in ITEMS:
        items.insert(name, Item(name=name, unmatched=False))

sys.exit(app.run())
