"""The todos scene: records and field projection, end to end — the
design appendix's app, one sugar tier at a time. The collection's
elements are records; the dataclass IS the schema (wire-typed fields in
declaration order), the template binds each field to its own widget
(title -> label text, done -> checkbox state), and toggling a row sends
one field's delta — `patch(key, done=...)` never resends the title.
The items-left label is a derived signal recomputed from the collection
after every mutation, so no handler mentions it.

AND THE DERIVED LABEL COMES BACK FROM AN UNDO WITH NOBODY RESTORING IT.
The add is a named step (`kaya.undoable`), and the derive's write is in
that same batch: `insert_fresh` recomputes and appends an ordinary
signal write to the transaction the binding opened for the handler, so
the core banks the label in both directions of the step and hands it
back with the collection. That is why this file registers no
`on_undone` — there is nothing for a handler to fix up, and a binding
that recomputed the derive while absorbing the payload would be writing
a value the ledger never banked (see `App._absorb_undo`).

The backend selftest (KAYA_SELFTEST=todos) types "buy milk", clicks
Add, reads "1 item left", walks the add back and forward through the
Edit menu reading the label at each end, then toggles the stamped row's
checkbox and expects the status label to read exactly "0 items left".

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
    # ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. What makes the
    # ITEMS-LEFT LABEL come back with the todo is that the derive's
    # write lands in this same batch: the insert below recomputes and
    # appends an ordinary signal write, and a named transaction banks
    # every signal it dirtied in both directions. So the step's inverse
    # carries "0 items left" and its forward carries "1 item left", and
    # the label is restored by the same mechanism as the collection.
    # The ambient tier names the step from INSIDE the handler — the
    # binding opened this transaction, not the app — and the marker
    # still leads the batch wherever the call sits in the body.
    kaya.undoable(f"add {draft}")
    # A todo is a title and a flag — no identity of its own — so the key
    # comes from the binding: insert_fresh mints one per collection
    # instance and hands it back (docs/fresh-key-plan.md). The key the
    # toggle handler receives below is that minted one, round-tripped
    # through the stamped row.
    todos.insert_fresh(Todo(title=draft, done=False))
    # FINISHING THE FORM IS NOT PART OF THE STEP, so it does not ride
    # this transaction: undoing the add must not put "buy milk" back
    # beside a todo that is gone (docs/undo-plan.md §2), and `clear`
    # inside a group is refused at apply anyway (D4) because it destroys
    # widget-owned text the core never held. A handler IS one
    # transaction here, so the second one is posted — same two commits
    # in the same order, one turn later.
    app.post(finish_form)


def finish_form():
    """The add's second transaction, on the app thread. The field
    empties on screen and reports text_changed("") through its normal
    edit path (the fold above empties the draft), and the cursor lands
    back in it — clear before focus, so focus is the last word."""
    field.clear()
    field.focus()


def on_toggle(key, checked):
    # One field's delta: the title never travels; the derived signal
    # updates itself.
    todos.patch(key, done=checked)


with app.window(title="todos"):
    # THE GESTURE LAYER, and the two items are the whole of it: an app
    # declares them and writes nothing else. They act on what is
    # focused, lower to the platform's own command where it has one, and
    # work out their own enablement from what the ledger holds
    # (docs/undo-plan.md D1-D6).
    with app.menu("Edit"):
        kaya.item("Undo", role=kaya.ROLE_UNDO)
        kaya.item("Redo", role=kaya.ROLE_REDO)

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
