"""The app-owned undo scene (tools/scenes/ownundo.steps;
docs/rich-text-plan.md R6, §14): two rich textareas, one on the platform's
own undo tier and one whose app keeps its own history of Documents.
Edit>Undo reaches the app through the role item's own activation while the
owned textarea is focused, and the platform's tier while the other one is."""

import sys

import kaya

app = kaya.App()

# THE APP'S OWN HISTORY: the document before each user edit, and the
# documents an undo took away. The binding's mirror is the document AFTER
# the edit it just delivered.
undo = []
redo = []
current = kaya.Document("")


def publish():
    status.set(f"undo {len(undo)} redo {len(redo)}")
    owned.can_undo(bool(undo))
    owned.can_redo(bool(redo))


def on_edit(edit):
    global current
    undo.append(current)
    current = owned.document()
    redo.clear()
    publish()


def on_undo():
    global current
    if not undo:
        return
    before = undo.pop()
    redo.append(current)
    current = before
    owned.set_document(before)
    publish()


def on_redo():
    global current
    if not redo:
        return
    after = redo.pop()
    undo.append(current)
    current = after
    owned.set_document(after)
    publish()


def on_focus_native():
    native.focus()


def on_focus_owned():
    owned.focus()


with app.window(title="ownundo"):
    with app.menu("Edit"):
        kaya.item("Undo", role=kaya.MenuRole.UNDO, on_activate=on_undo)
        kaya.item("Redo", role=kaya.MenuRole.REDO, on_activate=on_redo)

    status = kaya.signal("undo 0 redo 0")

    with kaya.column():
        kaya.label(bind=status).a11y_id("status")            # label#0
        native = kaya.textarea(rich=True)                    # textarea#0
        native.a11y_id("native").a11y_label("Native")
        owned = kaya.textarea(rich=True, own_undo=True,
                              on_edit=on_edit)               # textarea#1
        owned.a11y_id("owned").a11y_label("Owned")
        with kaya.row():
            kaya.button("focus native", on_click=on_focus_native)  # button#0
            kaya.button("focus owned", on_click=on_focus_owned)    # button#1

sys.exit(app.run())
