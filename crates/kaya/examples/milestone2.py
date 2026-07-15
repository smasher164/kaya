"""The milestone-2 scene from Python, on the tier-1 surface: ambient
transactions (handlers and the window block are transactions), container
auto-parenting, co-located click handlers, element proxies, and handles
with methods. The wire vocabulary underneath (kaya_wire) is generated
from kaya::spec by kaya-bindgen.

Build the library first (cargo build), then:
    KAYA_SELFTEST=1 python3 crates/kaya/examples/milestone2.py
"""

import itertools
import pathlib
import sys

_here = pathlib.Path(__file__).resolve().parent
for _base in [_here, *_here.parents]:
    if (_base / "bindings" / "python").is_dir():
        sys.path.insert(0, str(_base / "bindings" / "python"))
        break

import kaya_app as kaya

app = kaya.App()

counter = itertools.count(1)


def on_step():
    n = next(counter)
    if n == 1:
        groups.insert("g1", "Work")
        items.at("g1").insert("a", "send report")
        items.at("g1").insert("b", "buy milk")
    elif n == 2:
        groups.insert("g2", "Home")
        items.at("g2").insert("a", "water plants")
        groups.update("g1", "Office")
    extras.set(n == 1)
    status.set(f"step {n}")


def on_remove(group, item_key):
    items.at(group).remove(item_key)
    status.set(f"removed {group}/{item_key}")


with app.window():
    status = kaya.signal("step 0")
    extras = kaya.signal(False)
    groups = kaya.collection()

    with kaya.column():
        kaya.button("step", on_click=on_step)
        kaya.label(bind=status)
        with kaya.when(extras):
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
