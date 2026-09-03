"""The entry scene (tools/scenes/entry.steps).

    KAYA_SELFTEST=entry python3 guests/python/entry.py
"""

import sys

import kaya

app = kaya.App()


draft = ""


def on_change(text):
    global draft
    draft = text


def on_add():
    if not draft:
        status.set(f"nothing to add, {len(todos)} total")
        return
    # The binding mints the key (docs/fresh-key-plan.md).
    todos.insert_fresh(draft)
    status.set(f"added {draft}, {len(todos)} total")
    # Atomic with the insert; the field's text_changed("") empties draft.
    field.clear()
    field.focus()


with app.window():
    status = kaya.signal("no todos")
    todos = kaya.collection()

    with kaya.column():
        field = kaya.entry(on_change=on_change)
        kaya.button("add", on_click=on_add)
        kaya.label(bind=status)
        for todo in todos:
            kaya.label(bind=todo)

sys.exit(app.run())
