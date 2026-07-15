"""The milestone-2 scene from Python, on the idiomatic surface
(kaya_app): typed handles instead of hand-numbered ids, `with` blocks
instead of template_end bookkeeping, and click handlers instead of a
hand-rolled dispatch loop. The wire vocabulary underneath (kaya_wire)
is generated from kaya::spec by kaya-bindgen.

Build the library first (cargo build), then:
    KAYA_SELFTEST=1 python3 crates/kaya/examples/milestone2.py
"""

import pathlib
import sys

_here = pathlib.Path(__file__).resolve().parent
for _base in [_here, *_here.parents]:
    if (_base / "bindings" / "python").is_dir():
        sys.path.insert(0, str(_base / "bindings" / "python"))
        break

from kaya_app import App
from kaya_wire import KIND_BUTTON, KIND_COLUMN, KIND_LABEL

app = App()

with app.build() as tx:
    status = tx.signal("step 0")
    extras = tx.signal(False)

    column = tx.widget(KIND_COLUMN)
    step = tx.widget(KIND_BUTTON)
    tx.set_text(step, "step")
    status_label = tx.widget(KIND_LABEL)
    tx.bind_text(status_label, status)

    with tx.when(extras) as t:
        banner_label = t.widget(KIND_LABEL)
        t.set_text(banner_label, "extras on")
        banner = t.node

    groups = tx.collection()
    with tx.for_each(groups) as t:
        group_column = t.widget(KIND_COLUMN)
        name = t.widget(KIND_LABEL)
        t.bind_text_element(name)
        t.add_child(group_column, name)

        items = t.collection()
        with t.for_each(items) as item:
            row = item.widget(KIND_COLUMN)
            text = item.widget(KIND_LABEL)
            item.bind_text_element(text)
            remove = item.widget(KIND_BUTTON)
            item.set_text(remove, "remove")
            item.add_child(row, text)
            item.add_child(row, remove)
            item_list = item.node
        t.add_child(group_column, item_list)
        group_list = t.node

    tx.add_child(column, step)
    tx.add_child(column, status_label)
    tx.add_child(column, banner)
    tx.add_child(column, group_list)
    tx.mount(column)

steps = 0


@app.on_click(step)
def _(tx):
    global steps
    steps += 1
    if steps == 1:
        tx.insert(groups, "g1", "Work")
        tx.insert(items, "a", "send report", path=["g1"])
        tx.insert(items, "b", "buy milk", path=["g1"])
    elif steps == 2:
        tx.insert(groups, "g2", "Home")
        tx.insert(items, "a", "water plants", path=["g2"])
        tx.update(groups, "g1", "Office")
    tx.write(extras, steps == 1)
    tx.write(status, f"step {steps}")


@app.on_click(remove)
def _(tx, group, item_key):
    tx.remove(items, item_key, path=[group])
    tx.write(status, f"removed {group}/{item_key}")


sys.exit(app.run())
