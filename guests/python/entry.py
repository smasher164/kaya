"""The entry scene: the first widget with owned state, exercising the
uncontrolled contract end to end. The field owns its text and reports
each edit as a text-changed occurrence; the app folds those into a
plain variable (`draft`) — its own model, per doctrine; there is no
read-back from the widget. The add button inserts the draft into the
todos collection and answers with the count read from the collection
model (the patch-producing fold, same as milestone 2).

The backend selftest (KAYA_SELFTEST=entry) sets the field's text to
"milk", emits the change through the delegate's own path, clicks add,
and expects: the status label "added milk, 1 total", the field cleared
and refocused (one-shot commands riding the insert's transaction), and
a second add answering "nothing to add, 1 total" — the clear's
text_changed("") re-entered through the fold and emptied the draft.

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
    # The empty-draft guard every real form has — and the scene's
    # proof that clear emptied the draft through the occurrence fold,
    # not a side assignment.
    if not draft:
        status.set(f"nothing to add, {len(todos)} total")
        return
    next_key += 1
    todos.insert(f"t{next_key}", draft)
    status.set(f"added {draft}, {len(todos)} total")
    # Finish the form: drop the field's content and put the cursor
    # back, atomically with the insert. The field answers with
    # text_changed("") through its normal edit path, and on_change
    # empties the draft.
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
