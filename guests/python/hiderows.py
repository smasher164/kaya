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


def select_first():
    draft.focus()
    draft.select_range(range(0, 5))


with app.window(title="hiderows", width=480.0, height=760.0):
    notes = kaya.collection(Note)
    files = kaya.collection(File)
    two = kaya.signal(False)
    pane = kaya.signal(False)
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
        with kaya.column() as hideable:
            hideable.hidden(pane)
            with kaya.scroll(axis=kaya.Axis.HORIZONTAL) as strip:
                with kaya.row():
                    for i in range(1, 21):
                        kaya.label(bind=kaya.signal(f"card {i}"))
            strip.a11y_id("strip")
            draft = kaya.textarea().a11y_id("draft").a11y_label("Draft")
        with kaya.row():
            kaya.checkbox("Hide two", on_toggle=two.set).a11y_id("hide_two")
            kaya.checkbox("Hide pane", on_toggle=pane.set).a11y_id("hide_pane")
        kaya.button("select first", on_click=select_first).a11y_id("select_first")
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
