"""The row menu scene (tools/scenes/rowmenu.steps; docs/media-player-plan.md
M26). Canonical semantics in guests/rust/rowmenu.rs."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Entry:
    title: str
    mark: str


app = kaya.App()


def on_star(row):
    on = row.mark == "Star"
    row.mark = "Unstar" if on else "Star"
    status.set(f"{'starred' if on else 'unstarred'} {row.key}")


def on_pin(row):
    on = row.mark == "Pin"
    row.mark = "Unpin" if on else "Pin"
    status.set(f"{'pinned' if on else 'unpinned'} {row.key}")


def on_open(row):
    status.set(f"opened {row.key}")


with app.window(title="rowmenu"):
    status = kaya.signal("ready")
    notes = kaya.collection(Entry)
    files = kaya.collection(Entry)
    with kaya.context_catalog() as note_menu:
        star = kaya.item("Star", on_activate=on_star)
        kaya.separator()
        kaya.item("Open", on_activate=on_open)
    with kaya.context_catalog() as file_menu:
        pin = kaya.item("Pin", on_activate=on_pin)
        kaya.separator()
        kaya.item("Open", on_activate=on_open)

    with kaya.column():
        kaya.label(bind=status)
        for note in notes:
            with kaya.row() as line:
                line.a11y_id("note")
                line.context_menu(note_menu)
                line.context_label(star, note.mark)
                kaya.label(bind=note.title)
        for file in files.columns("Name", grow=1):
            with kaya.row() as line:
                line.a11y_id("file")
                line.context_menu(file_menu)
                line.context_label(pin, file.mark)
                kaya.label(bind=file.title)

    for key, title, mark in [("a", "apples", "Star"), ("b", "bread", "Unstar")]:
        notes.insert(key, Entry(title=title, mark=mark))
    for key, title, mark in [("x", "x.txt", "Pin"), ("y", "y.txt", "Unpin")]:
        files.insert(key, Entry(title=title, mark=mark))

sys.exit(app.run())
