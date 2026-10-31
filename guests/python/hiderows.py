"""The hidden-rows scene (tools/scenes/hiderows.steps; docs/hidden-plan.md).
Canonical semantics in guests/rust/hiderows.rs."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Note:
    title: str
    unmatched: bool


@dataclass
class File:
    name: str
    size: str
    unmatched: bool


NOTES = ["alpha", "beta", "gamma"]


def file_name(i):
    return f"file {i:03d}"


app = kaya.App()


def find_notes(query):
    for title in NOTES:
        notes.patch(title, unmatched=query not in title)


def find_files(query):
    for i in range(300):
        files.patch(file_name(i), unmatched=query not in file_name(i))


with app.window(title="hiderows"):
    notes = kaya.collection(Note)
    files = kaya.collection(File)
    two = kaya.signal(False)
    with kaya.column():
        kaya.search(placeholder="Find notes", on_change=find_notes).a11y_id("find_notes")
        for note in notes.rows(a11y_id="notes"):
            with kaya.row() as line:
                line.hidden(note.unmatched)
                kaya.label(bind=note.title)
                kaya.entry().a11y_id("note")
        with kaya.grid(2) as tiles:
            tiles.a11y_id("tiles")
            kaya.label("one")
            kaya.label("two").hidden(two)
            kaya.label("three")
        kaya.checkbox("Hide two", on_toggle=two.set).a11y_id("hide_two")
        kaya.search(placeholder="Find files", on_change=find_files).a11y_id("find_files")
        for file in files.columns("Name", "Size", grow=1, a11y_id="files"):
            with kaya.row() as line:
                line.hidden(file.unmatched)
                kaya.label(bind=file.name)
                kaya.label(bind=file.size)

    for title in NOTES:
        notes.insert(title, Note(title=title, unmatched=False))
    for i in range(300):
        files.insert(file_name(i), File(name=file_name(i), size=f"{i} KB", unmatched=False))

sys.exit(app.run())
