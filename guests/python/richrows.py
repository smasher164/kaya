"""The rich rows scene (tools/scenes/richrows.steps): a rich textarea per
stamped ROW whose document is a FIELD of the row (docs/rich-text-plan.md
§19). The app writes a copy's document by patching its row, and a copy's
own act folds into the row the app reads back."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Note:
    title: str
    body: kaya.Document


app = kaya.App()


def spell(runs):
    """The core's spelling of runs (`expect_runs`), so the row's field and
    the core's mirror are compared as one string."""
    return "|".join(
        f"{run.range.start}:{run.range.stop} {run.name}"
        if run.is_flag
        else f"{run.range.start}:{run.range.stop} {run.name}={run.value}"
        for run in runs)


def on_acted(key, _act):
    # The row's field already carries the copy's act when this fires: the
    # app reads the row, never the widget.
    note = notes.get(key)
    last.set(f"{key}: {spell(note.body.runs)}")


def on_patch():
    kaya.undoable("patch b")
    notes.patch("b", body=kaya.Document("Patched").mark((0, 7), "italic", True))


def on_read():
    note = notes.get("a")
    view.set(f"{note.body.text} | {spell(note.body.runs)}")


def on_restored(_label, _delta):
    # An undo or redo moved the row back: the app reads ITS OWN mirror of
    # row b, which is the fold a restored Blob field lands in.
    note = notes.get("b")
    view.set(f"{note.body.text} | {spell(note.body.runs)}")


with app.window(title="richrows", on_undone=on_restored, on_redone=on_restored):
    with app.menu("Edit"):
        kaya.item("Undo", role=kaya.MenuRole.UNDO)
        kaya.item("Redo", role=kaya.MenuRole.REDO)

    notes = kaya.collection(Note)
    last = kaya.signal("")
    view = kaya.signal("")
    with kaya.column():
        kaya.label(bind=last)  # label#0
        kaya.label(bind=view)  # label#1
        with kaya.row():
            kaya.button("patch b", on_click=on_patch)  # button#0
            kaya.button("read a", on_click=on_read)    # button#1
        for note in notes:
            with kaya.column():
                kaya.label(bind=note.title)
                kaya.textarea(document=note.body, on_edit=on_acted,
                              on_format=on_acted).a11y_id("body")
    notes.insert("a", Note(
        title="a",
        body=kaya.Document("Héllo world").mark((0, 6), "bold", True)))
    notes.insert("b", Note(
        title="b",
        body=kaya.Document("Second note").mark((7, 11), "link",
                                               "https://kaya.dev")))

sys.exit(app.run())
