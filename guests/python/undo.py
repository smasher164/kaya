"""The undo conformance scene (tools/scenes/undo.steps). THE AMBIENT TIER
NAMES ITS TRANSACTION FROM INSIDE; a second scope in a handler raises."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Todo:
    title: str


app = kaya.App()

# Two mirrors of widget-owned text; the payload's path tells them apart.
draft = ""
row_notes = {}


def what(label):
    """What the history label says a step was. A typing episode carries an
    empty label — kaya invents none (docs/undo-plan.md D8)."""
    return label or "typing"


def key_list():
    """The app's collection mirror, rendered: every key it holds, in the
    order it holds them (D5)."""
    ks = todos.keys()
    if not ks:
        return "no keys"
    return "keys " + ",".join(str(k) for k in ks)


def note_list():
    """The app's copy of what is typed in the ROWS, rendered: every note
    it holds, by key, lowest key first."""
    if not row_notes:
        return "no notes"
    return "notes " + ",".join(
        f"{key}={text}" for key, text in sorted(row_notes.items()))


def fold_texts(texts):
    """One texts run, folded into the two mirrors. The empty path is the
    draft; a path names a row, and for a top-level `for` over a collection
    that path is one key.

    EVERY ENTRY COUNTS, never just the last: one step can restore the
    draft and a row's note at once. AN EMPTY NOTE IS NO NOTE — restoring
    a row's field to "" must REMOVE the key, which is what makes the
    scene's undo assertion falsifiable.
    """
    global draft
    for _ident, path, text in texts:
        if not path:
            draft = text
        elif not text:
            row_notes.pop(path[0], None)
        else:
            row_notes[path[0]] = text


def on_change(text):
    global draft
    draft = text


def on_note(key, text):
    """A note typed into a ROW's field: the stamped key arrives first,
    then the text."""
    if text:
        row_notes[key] = text
    else:
        row_notes.pop(key, None)
    # NOT a step: the ledger banks an uncontrolled field's typing.
    notes.set(note_list())


def on_add():
    if not draft:
        status.set(f"nothing to add, {len(todos)} total")
        return
    kaya.undoable(f"add {draft}")
    # The binding mints the key (docs/fresh-key-plan.md).
    todos.insert_fresh(Todo(title=draft))
    status.set(f"added {draft}, {len(todos)} total")
    keys.set(key_list())
    field.focus()
    # A SECOND transaction: `clear` inside the group is refused, and a
    # handler IS one transaction here.
    app.post(field.clear)


def on_remove():
    entries = todos.items()
    if not entries:
        status.set(f"nothing to remove, {len(todos)} total")
        return
    # The FIRST entry, so the restore has to come back before the rest.
    key, todo = entries[0]
    kaya.undoable(f"remove {todo.title}")
    todos.remove(key)
    status.set(f"removed {todo.title}, {len(todos)} total")
    keys.set(key_list())


def on_star():
    kaya.undoable("star")
    status.set("starred")


def on_focus():
    field.focus()


def undone(label, delta):
    """The label of the step that came back, and the whole restored
    state.

    THE DELTA IS THE ONLY NOTIFICATION for a field's text: an undo is a
    programmatic write and never echoes, so an app that folds
    `text_changed` goes stale on this step without it (D5).

    The binding reconciles its collection mirror from this payload before
    this runs, so `len(todos)` answers about the restored state.
    """
    fold_texts(delta.texts)
    history.set(f"undid {what(label)}, {len(todos)} total")
    keys.set(key_list())
    notes.set(note_list())


def redone(label, delta):
    fold_texts(delta.texts)
    history.set(f"redid {what(label)}, {len(todos)} total")
    keys.set(key_list())
    notes.set(note_list())


with app.window(title="undo", on_undone=undone, on_redone=redone):
    with app.menu("Edit"):
        kaya.item("Undo", role=kaya.ROLE_UNDO)
        kaya.item("Redo", role=kaya.ROLE_REDO)

    status = kaya.signal("no todos")
    history = kaya.signal("history empty")
    keys = kaya.signal("no keys")
    notes = kaya.signal("no notes")
    todos = kaya.collection(Todo)

    with kaya.column():
        kaya.label(bind=status).a11y_id("status")           # label#0
        kaya.label(bind=history).a11y_id("history")         # label#1
        kaya.label(bind=keys).a11y_id("keys")               # label#2
        kaya.label(bind=notes).a11y_id("notes")             # label#3
        field = kaya.entry(on_change=on_change).a11y_id("draft")  # entry#0
        kaya.button("add", on_click=on_add)                 # button#0
        kaya.button("star", on_click=on_star)               # button#1
        # The scene's way back to the field.
        kaya.button("focus", on_click=on_focus)             # button#2
        kaya.button("remove", on_click=on_remove)           # button#3
        for todo in todos:
            with kaya.row():
                kaya.label(bind=todo.title)
                kaya.entry(on_change=on_note)

    # The scene types with real keystrokes, so something must hold focus.
    field.focus()

sys.exit(app.run())
