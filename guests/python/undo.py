"""The undo scene, Python port: two tiers, one Edit menu, and one ledger
that orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).

WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. `kaya.undoable(...)`
names the transaction it is called in, and that name is the step: the
core keeps the inverse of what the batch did to signals and collections,
and hands it back through `on_undone`. There is no undo stack in this
file, no command objects, and no re-run of any handler — an undo is a
programmatic write of the state that was there before, which is why it
emits nothing and why the occurrence carries the whole delta.

THE AMBIENT TIER NAMES ITS TRANSACTION FROM INSIDE, because a handler
does not open one: the binding does (App._dispatch), and a second scope
inside a handler raises. The marker still leads the batch — the call
inserts it at the head wherever it sits in the body, exactly as
`tx.undoable` does in the languages that hand the guest a transaction
handle. Same semantics, Python's spelling.

THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S, and this app writes
nothing for it at all. Both tiers arrive through the same Edit>Undo
item, and which one answers is kaya's routing question, not the app's
(D6).

THE SCENARIO THAT MOTIVATED THE MILESTONE is the add button, which is
the entry scene's add: it appends a todo AND empties the field. Two
transactions, deliberately — the undoable group is the insert and the
status it wrote, and the clear that finishes the form is not part of the
step. Under two unordered stacks one Cmd+Z takes back the CLEAR: "milk"
returns to the field, the todo stays, and the user is looking at a state
that never existed (docs/undo-plan.md §2). Here it takes back the ADD.

It is also the design saying the same thing twice: `clear` inside a
group is REFUSED at apply, because it destroys widget-owned text the
core never held (D4). Undo restores state, and state is signals plus
collections.

Canonical semantics in guests/rust/undo.rs; the byte-frozen contract in
tools/scenes/undo.steps.
"""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Todo:
    title: str


app = kaya.App()

# The fold: widget-owned state arrives as occurrences; the app's copy is
# this variable, not a widget read.
draft = ""
next_key = 0


def what(label):
    """What the history label says a step was. A typing episode has no
    authored name and kaya invents none ("Undo Typing" is an Apple
    convention, not a scene string — docs/undo-plan.md D8), so the empty
    label is the app's to spell."""
    return label or "typing"


def on_change(text):
    global draft
    draft = text


def on_add():
    global next_key
    if not draft:
        status.set(f"nothing to add, {len(todos)} total")
        return
    next_key += 1
    # ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name is what the
    # step is called; everything else in this transaction is what it did.
    kaya.undoable(f"add {draft}")
    todos.insert(f"t{next_key}", Todo(title=draft))
    status.set(f"added {draft}, {len(todos)} total")
    # A PURE EFFECT rides along and is simply not restored: undo restores
    # state, not where you were looking (A2).
    field.focus()
    # FINISHING THE FORM IS NOT PART OF THE STEP. Its own transaction, so
    # undoing the add does not put the draft back beside a todo that is
    # gone — and `clear` inside a group would be refused anyway. A
    # handler IS one transaction here, so the second one is posted: same
    # two commits in the same order, and the field empties on screen and
    # reports text_changed("") through its normal edit path, so the fold
    # above empties the draft.
    app.post(field.clear)


def on_star():
    # A group at its smallest: one signal write, which is the undoable
    # set's whole vocabulary on the reactive side.
    kaya.undoable("star")
    status.set("starred")


def on_focus():
    field.focus()


def undone(label, delta):
    """The label of the step that came back, and the whole restored
    state.

    THE DELTA IS THE ONLY NOTIFICATION for a field's text: restoring an
    episode is a programmatic write, and a programmatic write never
    echoes, so an app that folds `text_changed` into its own model —
    which is every app, the field being uncontrolled — would go stale on
    exactly this step if the payload did not carry it (D5).

    The binding has already reconciled its collection mirror from this
    payload before this runs, which is why `len(todos)` below answers
    about the restored state.
    """
    global draft
    if delta.texts:
        draft = delta.texts[-1][1]
    history.set(f"undid {what(label)}, {len(todos)} total")


def redone(label, delta):
    global draft
    if delta.texts:
        draft = delta.texts[-1][1]
    history.set(f"redid {what(label)}, {len(todos)} total")


# Per window, and PERSISTENT: a history is walked as often as the user
# likes, so the two handlers ride the window declaration and outlive
# every step.
with app.window(title="undo", on_undone=undone, on_redone=redone):
    # THE GESTURE LAYER, one tier deeper: an app declares the two items
    # and writes nothing else. They act on the focused widget, lower to
    # the platform's own command where it has one, and work out their own
    # enablement from what is focused and what the ledger holds.
    with app.menu("Edit"):
        kaya.item("Undo", role=kaya.ROLE_UNDO)
        kaya.item("Redo", role=kaya.ROLE_REDO)

    status = kaya.signal("no todos")
    history = kaya.signal("history empty")
    todos = kaya.collection(Todo)

    with kaya.column():
        kaya.label(bind=status).a11y_id("status")           # label#0
        kaya.label(bind=history).a11y_id("history")         # label#1
        field = kaya.entry(on_change=on_change).a11y_id("draft")  # entry#0
        kaya.button("add", on_click=on_add)                 # button#0
        kaya.button("star", on_click=on_star)               # button#1
        # THE SCENE'S WAY BACK TO THE FIELD. `star` does not move the
        # cursor on its own — an app that reaches for focus after every
        # action is deciding where the user is looking — so the scene
        # says so itself, and the routing question ("what is focused?")
        # stays visible in the script rather than hidden in a handler.
        kaya.button("focus", on_click=on_focus)             # button#2
        for todo in todos:
            with kaya.row():
                kaya.label(bind=todo.title)

    # THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
    # holding focus when it does — and focus is the routing question's
    # other half.
    field.focus()

sys.exit(app.run())
