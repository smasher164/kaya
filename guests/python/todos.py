"""The todos scene: records and field projection, end to end — the
design appendix's app, one sugar tier at a time. The collection's
elements are records; the dataclass IS the schema (wire-typed fields in
declaration order), the template binds each field to its own widget
(title -> label text, done -> checkbox state), and toggling a row sends
one field's delta — `patch(key, done=...)` never resends the title.
The items-left label is a derived signal recomputed from the collection
after every mutation, so no handler mentions it.

The backend selftest (KAYA_SELFTEST=todos) types "buy milk", clicks
Add, toggles the stamped row's checkbox, and expects the status label
to read exactly "0 items left".

Build the library first (cargo build), then:
    KAYA_SELFTEST=todos python3 guests/python/todos.py
"""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Todo:
    title: str
    done: bool


app = kaya.App()

draft = ""
next_key = 0


def items_left_text(items):
    n = sum(1 for t in items.values() if not t.done)
    return "1 item left" if n == 1 else f"{n} items left"


def on_change(text):
    global draft
    draft = text


def on_add():
    global next_key
    if not draft:
        return
    next_key += 1
    todos.insert(f"t{next_key}", Todo(title=draft, done=False))
    # Finish the form: the field empties on screen and reports
    # text_changed("") through its normal edit path (the fold above
    # empties the draft), and the cursor lands back in it.
    field.clear()
    field.focus()


def on_toggle(key, checked):
    # One field's delta: the title never travels; the derived signal
    # updates itself.
    todos.patch(key, done=checked)


with app.window():
    todos = kaya.collection(Todo)
    items_left = todos.derive(items_left_text)

    with kaya.column():
        field = kaya.entry(on_change=on_change)
        kaya.button("Add", on_click=on_add)
        kaya.label(bind=items_left)
        # The tracing tier: the for statement IS the For — the body
        # runs once, authoring the blueprint; stamping is the core's
        # replay.
        for todo in todos:
            with kaya.row():
                kaya.checkbox(checked=todo.done, on_toggle=on_toggle)
                kaya.label(bind=todo.title)

sys.exit(app.run())
