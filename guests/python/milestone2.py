"""The milestone-2 scene from Python, on the tier-1 surface: ambient
transactions, container auto-parenting, co-located click handlers,
element proxies, handles with methods — plus derived signals: the
extras banner's When binds `steps.eq(1)`, recomputed by the binding at
write time and batched into the same transaction; the core never
knows. The counter itself is a guest variable — signals are a render
pipe, written and never read back. The
wire vocabulary underneath (kaya_wire) is generated from kaya::spec by
kaya-bindgen.

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

import kaya_app as kaya

app = kaya.App()


step_count = 0


def on_step():
    global step_count
    step_count += 1
    n = step_count
    steps.set(n)
    if n == 1:
        groups.insert("g1", "Work")
        with items.at("g1").change() as todo:
            todo["a"] = "send report"
            todo["b"] = "buy milk"
    elif n == 2:
        groups.insert("g2", "Home")
        items.at("g2").insert("a", "water plants")
        groups.update("g1", "Office")
    status.set(f"step {n}")


def on_remove(group, item_key):
    # The collection is the model: after the patch, reading it back is
    # exact — the count in the status proves the fold, not a shadow copy.
    todos = items.at(group)
    todos.remove(item_key)
    status.set(f"removed {group}/{item_key}, {len(todos)} left")


with app.window():
    steps = kaya.signal(0)
    status = kaya.signal("step 0")
    groups = kaya.collection()

    with kaya.column():
        kaya.button("step", on_click=on_step)
        kaya.label(bind=status)
        with kaya.when(steps.eq(1)):
            kaya.label("extras on")
        with kaya.for_each(groups) as group:
            with kaya.column():
                kaya.label(bind=group)
                items = kaya.collection()
                with kaya.for_each(items) as item:
                    with kaya.column():
                        kaya.label(bind=item)
                        kaya.button("remove", on_click=on_remove)

sys.exit(app.run())
