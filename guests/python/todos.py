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
    KAYA_SELFTEST=todos python3 crates/kaya/examples/todos.py
"""

import pathlib
import sys
from dataclasses import dataclass

_here = pathlib.Path(__file__).resolve().parent
for _base in [_here, *_here.parents]:
    if (_base / "bindings" / "python").is_dir():
        sys.path.insert(0, str(_base / "bindings" / "python"))
        break

import kaya_app as kaya


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
    next_key += 1
    todos.insert(f"t{next_key}", Todo(title=draft, done=False))


def on_toggle(key, checked):
    # One field's delta: the title never travels; the derived signal
    # updates itself.
    todos.patch(key, done=checked)


with app.window():
    todos = kaya.collection(Todo)
    items_left = todos.derive(items_left_text)

    with kaya.column():
        kaya.entry(on_change=on_change)
        kaya.button("Add", on_click=on_add)
        kaya.label(bind=items_left)
        with kaya.for_each(todos) as todo:
            with kaya.row():
                kaya.checkbox(checked=todo.done, on_toggle=on_toggle)
                kaya.label(bind=todo.title)

sys.exit(app.run())
