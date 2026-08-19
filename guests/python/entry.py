"""The entry scene: the first widget with owned state, exercising the
uncontrolled contract end to end. The field owns its text and reports
each edit as a text-changed occurrence; the app folds those into
`draft` and never reads back from the widget.

Build the library first (cargo build), then:
    KAYA_SELFTEST=entry python3 guests/python/entry.py
"""

import sys

import kaya

app = kaya.App()


draft = ""


def on_change(text):
    # The fold: widget-owned state arrives as occurrences; the app's
    # copy is this variable, not a widget read.
    global draft
    draft = text


def on_add():
    if not draft:
        status.set(f"nothing to add, {len(todos)} total")
        return
    # The binding mints the key (docs/fresh-key-plan.md).
    todos.insert_fresh(draft)
    status.set(f"added {draft}, {len(todos)} total")
    # Finish the form, atomically with the insert. The field answers with
    # text_changed("") through its normal edit path, so on_change empties
    # the draft.
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
