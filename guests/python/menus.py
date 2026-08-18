"""The menus conformance scene, Python port: the command vocabulary (a
File/View/Sort menu bar, context menus on a live label and on stamped
rows), the uncontrolled-menu echo doctrine, and a late
rename/append/promotion rework. Canonical semantics in
guests/rust/menus.rs; the byte-frozen contract in tools/scenes/menus.steps.
"""

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
    # The folds never echo the user's pick, so details/sort still hold
    # False/0; these two prop writes are real checked/value records (never
    # coalesced) that reset the backend's user-state mirror.
    details.set(False)
    sort.set(0.0)
    status.set("ready")


def on_rename():
    status.set("renamed")


def on_remove(group, item):
    items.at(group).remove(item)
    status.set(f"removed {group}/{item}")


def on_rework():
    # Append-only: rename the retained File, move the promotion hint from
    # Share to Publish, grow the bar by Tools.
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

    # File and its Export leaf share one enablement signal: one write
    # moves both.
    with app.menu("File", enabled=can_export) as file:
        # The symbol is a CONCEPT drawn by each platform in its own set
        # (docs/styling-plan.md D6). The vocabulary has no `save`, so
        # `done` — the checkmark idiom — is the spelling.
        kaya.item("Save", symbol=kaya.Symbol.DONE, shortcut="primary+s",
                  on_activate=on_save)
        kaya.item("Export", enabled=can_export, symbol=kaya.Symbol.FORWARD)
        share = kaya.item("Share", primary=True, on_activate=on_share)

    with app.menu("View"):
        kaya.toggle("Details", checked=details, symbol=kaya.Symbol.INFO,
                    on_toggle=on_details)

    # Option order IS the index vocabulary: Name = 0, Date = 1.
    with app.radio_group("Sort", value=sort, on_select=on_sorted):
        kaya.option("Name")
        kaya.option("Date")

    groups = kaya.collection()
    # Catalog built LIVE: items are shared across stamped copies, the
    # template only attaches, and each activation carries its key path.
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

        # Remove's activation names BOTH keys (group, then item).
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
