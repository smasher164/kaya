"""The menus conformance scene (tools/scenes/menus.steps). Canonical
semantics in guests/rust/menus.rs."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Task:
    title: str


app = kaya.App()


def on_enable_export():
    can_export.set(True)


def on_details(on):
    status.set("details on" if on else "details off")


def on_sorted(index):
    status.set("sorted date" if index == 1 else "sorted name")


def on_save():
    status.set("saved")


def on_share():
    status.set("shared")


def on_reset():
    # The folds never echo, so these reset the user-state mirror.
    details.set(False)
    sort.set(0.0)
    status.set("ready")


def on_rename():
    status.set("renamed")


def on_remove(group, item):
    items.at(group).remove(item)
    status.set(f"removed {group}/{item}")


def on_rework():
    share.primary(False)
    file.label("Document")
    with file.append():
        kaya.item("Publish", primary=True, symbol=kaya.Symbol.COPY,
                  on_activate=on_share)
    with app.menu("Tools"):
        kaya.item("Inspect", symbol=kaya.Symbol.SEARCH)


with app.window(title="menus"):
    status = kaya.signal("ready")
    can_export = kaya.signal(False)
    details = kaya.signal(False)
    sort = kaya.signal(0.0)

    with app.menu("File", enabled=can_export) as file:
        # The vocabulary has no `save` glyph, so `done` is the spelling.
        kaya.item("Save", symbol=kaya.Symbol.DONE, shortcut="primary+s",
                  on_activate=on_save)
        kaya.item("Export", enabled=can_export, symbol=kaya.Symbol.FORWARD)
        share = kaya.item("Share", primary=True, on_activate=on_share)

    with app.menu("View"):
        kaya.toggle("Details", checked=details, symbol=kaya.Symbol.INFO,
                    on_toggle=on_details)

    # Option order IS the index.
    with app.radio_group("Sort", value=sort, on_select=on_sorted):
        kaya.option("Name")
        kaya.option("Date")

    groups = kaya.collection()
    with kaya.context_catalog() as catalog:
        kaya.item("Remove", symbol=kaya.Symbol.DELETE, on_activate=on_remove)

    with kaya.column():
        kaya.label(bind=status)  # label#0
        kaya.button("enable export", on_click=on_enable_export)  # button#0
        kaya.button("reset menu state", on_click=on_reset)  # button#1
        kaya.button("extend menus", on_click=on_rework)  # button#2

        target_text = kaya.signal("rename target")
        target = kaya.label(bind=target_text)  # label#1
        with target.context_menu():
            kaya.item("Rename", symbol=kaya.Symbol.EDIT, on_activate=on_rename)

        for _g in groups:
            with kaya.column():
                items = kaya.collection(Task)
                for task in items:
                    row = kaya.label(bind=task.title)  # label#2 once g2/a stamps
                    row.context_menu(catalog)

# Seed after mount: the stamp path attaches the shared catalog and keys.
with app.build():
    groups.insert("g2", "Home")
    items.at("g2").insert("a", Task(title="water plants"))

sys.exit(app.run())
