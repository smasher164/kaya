"""The todos scene: records and field projection, end to end. The
collection's elements are records; the dataclass IS the schema (wire-typed
fields in declaration order), the template binds each field to its own
widget, and toggling a row sends one field's delta — `patch(key, done=...)`
never resends the title. The items-left label is a derived signal
recomputed from the collection after every mutation.

THE DERIVED LABEL COMES BACK FROM AN UNDO WITH NOBODY RESTORING IT,
which is why this file registers no `on_undone`: the derive's write
lands in the add's own batch, so the core banks it in both directions.

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


def items_left_text(items):
    n = sum(1 for t in items.values() if not t.done)
    return "1 item left" if n == 1 else f"{n} items left"


def on_change(text):
    global draft
    draft = text


def on_add():
    if not draft:
        return
    # The ambient tier names the step from INSIDE the handler — the
    # binding opened this transaction, not the app — and the marker still
    # leads the batch wherever the call sits in the body.
    kaya.undoable(f"add {draft}")
    # The binding mints the key (docs/fresh-key-plan.md); the toggle
    # handler below receives that same minted key.
    todos.insert_fresh(Todo(title=draft, done=False))
    # Finishing the form is a SECOND transaction: `clear` inside an
    # undoable group is refused at apply (docs/undo-plan.md D4), and
    # undoing the add must not put "buy milk" back beside a todo that is
    # gone. A handler IS one transaction here, so this one is posted.
    app.post(finish_form)


def finish_form():
    """The add's second transaction, on the app thread. CLEAR BEFORE
    FOCUS, so focus is the last word."""
    field.clear()
    field.focus()


def on_toggle(key, checked):
    # One field's delta: the title never travels; the derived signal
    # updates itself.
    todos.patch(key, done=checked)


with app.window(title="todos"):
    with app.menu("Edit"):
        kaya.item("Undo", role=kaya.ROLE_UNDO)
        kaya.item("Redo", role=kaya.ROLE_REDO)

    todos = kaya.collection(Todo)
    items_left = todos.derive(items_left_text)

    with kaya.column():
        field = kaya.entry(on_change=on_change)
        kaya.button("Add", on_click=on_add)
        kaya.label(bind=items_left)
        # The for statement IS the For: the body runs ONCE, authoring the
        # blueprint; stamping is the core's replay.
        for todo in todos:
            with kaya.row():
                kaya.checkbox(checked=todo.done, on_toggle=on_toggle)
                kaya.label(bind=todo.title)

sys.exit(app.run())
