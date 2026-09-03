"""The todos scene (tools/scenes/todos.steps). IT REGISTERS NO `on_undone`:
the derive's write rides the add's batch, so the ledger banks it."""

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
    # The marker leads the batch wherever the call sits in the body.
    kaya.undoable(f"add {draft}")
    # The binding mints the key (docs/fresh-key-plan.md).
    todos.insert_fresh(Todo(title=draft, done=False))
    # A SECOND transaction: `clear` inside an undoable group is refused at
    # apply, and a handler IS one transaction here.
    app.post(finish_form)


def finish_form():
    """The add's second transaction, on the app thread. CLEAR BEFORE
    FOCUS, so focus is the last word."""
    field.clear()
    field.focus()


def on_toggle(key, checked):
    # One field's delta: the title never travels.
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
        # The body runs ONCE, authoring the blueprint.
        for todo in todos:
            with kaya.row():
                kaya.checkbox(checked=todo.done, on_toggle=on_toggle)
                kaya.label(bind=todo.title)

sys.exit(app.run())
