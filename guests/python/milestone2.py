"""The milestone-2 scene, on the tier-1 surface.

    KAYA_SELFTEST=1 python3 guests/python/milestone2.py
"""

import sys

import kaya

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
        # `if steps:` RAISES: the branch must be traced, not taken.
        with kaya.when(steps == 1):
            kaya.label("extras on")
        for group in groups:
            with kaya.column():
                kaya.label(bind=group)
                items = kaya.collection()
                for item in items:
                    with kaya.column():
                        kaya.label(bind=item)
                        kaya.button("remove", on_click=on_remove)

sys.exit(app.run())
