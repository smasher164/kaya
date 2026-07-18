"""The entry scene: the first widget with owned state, exercising the
uncontrolled contract end to end. The field owns its text and reports
each edit as a text-changed occurrence; the app folds those into a
plain variable (`draft`) — its own model, per doctrine; there is no
read-back from the widget. The add button inserts the draft into the
todos collection and answers with the count read from the collection
model (the patch-producing fold, same as milestone 2).

The backend selftest (KAYA_SELFTEST=entry) sets the field's text to
"milk", emits the change through the delegate's own path, clicks add,
and expects the status label to read exactly "added milk, 1 total".

Build the library first (cargo build), then:
    KAYA_SELFTEST=entry python3 crates/kaya/examples/entry.py
"""

import sys

import kaya

app = kaya.App()


draft = ""
next_key = 0


def on_change(text):
    # The fold: widget-owned state arrives as occurrences; the app's
    # copy is this variable, not a widget read.
    global draft
    draft = text


def on_add():
    global next_key
    next_key += 1
    todos.insert(f"t{next_key}", draft)
    status.set(f"added {draft}, {len(todos)} total")


with app.window():
    status = kaya.signal("no todos")
    todos = kaya.collection()

    with kaya.column():
        kaya.entry(on_change=on_change)
        kaya.button("add", on_click=on_add)
        kaya.label(bind=status)
        for todo in todos:
            kaya.label(bind=todo)

sys.exit(app.run())
