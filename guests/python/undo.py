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

AND THE APP NAMES NO TODO. A todo is a title and nothing else — it has
no identity of its own — so the key comes from `insert_fresh`, which
mints one per collection instance and hands it back
(docs/fresh-key-plan.md). What that buys here is the whole point of the
minter: this file used to carry `next_key`, a module global reached
through `global` in the handler that adds, whose safety rested on never
rewinding, and an undo that rewound it would have handed the same name
to two todos.

A ROW'S FIELD IS A FIELD TOO, and it is why this file keeps TWO mirrors
of widget-owned text instead of one. The draft is a live widget whose id
the app holds; a row's entry is a stamped copy, whose identity is
(template node, key path) — the same pair its clicks and its edits
already arrive under, and the reason the payload's texts run carries a
path at all. One rule folds both: an empty path is the draft, a path is
a row, and an empty text is no note.

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
# these two, not a widget read. Two of them, because there are two kinds
# of text field on screen — the draft, and one per row — and the
# payload's path is what tells them apart.
draft = ""
row_notes = {}


def what(label):
    """What the history label says a step was. A typing episode has no
    authored name and kaya invents none ("Undo Typing" is an Apple
    convention, not a scene string — docs/undo-plan.md D8), so the empty
    label is the app's to spell."""
    return label or "typing"


def key_list():
    """The app's collection mirror, rendered: every key it holds, in the
    order it holds them.

    THIS IS THE ONLY PART OF AN UNDO A COUNT CANNOT SEE. A restored entry
    that came back under a fresh name, or at the end instead of where it
    was, leaves every total in this file correct — the entries and orders
    runs of the delta are what say otherwise, and this is where the scene
    reads them (D5).
    """
    # The minter's keys are ints, so the model's own keys stringify
    # straight; nothing here parses or invents a name.
    ks = todos.keys()
    if not ks:
        return "no keys"
    return "keys " + ",".join(str(k) for k in ks)


def note_list():
    """The app's copy of what is typed in the ROWS, rendered: every note
    it holds, by key, lowest key first.

    THE ROWS' FIELDS ARE UNCONTROLLED LIKE THE DRAFT, so this map is the
    app's own and nothing reads it back off a widget. It is also where
    this scene proves the payload's shape: an undone note arrives naming
    (template node, key path), and an app with two rows can only put it
    back in the right one because the path says which.
    """
    if not row_notes:
        return "no notes"
    return "notes " + ",".join(
        f"{key}={text}" for key, text in sorted(row_notes.items()))


def fold_texts(texts):
    """One texts run, folded into the app's two mirrors of widget-owned
    text. The empty path is the draft; a path names a row, and for a
    top-level `for` over a collection that path is one key — the todo's
    own, minted by `insert_fresh` and already an int here, exactly as
    `key_list` reads the collection's keys.

    EVERY ENTRY COUNTS, never just the last: one step can restore the
    draft and a row's note at once, and reading `texts[-1]` alone drops
    whichever field came first.

    AN EMPTY NOTE IS NO NOTE, which is what makes the undo assertion in
    the scene falsifiable: the restore of a row's field to "" has to
    REMOVE the key, so an app that ignored this run reads its stale note
    back out and the script says so.
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
    """A note typed into a ROW's field: the copy's key, then the text.

    Same occurrence as `on_change` one level down — the field is
    uncontrolled either way — and the stamped keys arrive first, which
    is how the app knows which row it was. Folded by exactly the rule
    the payload's restore of the same field uses, so the script's
    assertion cannot pass through a second spelling of "what a note is".
    """
    if text:
        row_notes[key] = text
    else:
        row_notes.pop(key, None)
    # Its own transaction — a handler IS one here — and NOT a step: an
    # uncontrolled field's typing is banked by the ledger, never by the
    # app.
    notes.set(note_list())


def on_add():
    if not draft:
        # NOT A STEP, so it names no group and the forward history
        # survives it. It is also the one place this app READS ITS OWN
        # DRAFT out loud, which is how the script proves the restored
        # text of an undone typing episode reached it at all.
        status.set(f"nothing to add, {len(todos)} total")
        return
    # ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name is what the
    # step is called; everything else in this transaction is what it did.
    kaya.undoable(f"add {draft}")
    # NO KEY, AND NO COUNTER TO GET WRONG: the binding mints the name and
    # hands it back. This app has no use for it — a todo is looked up by
    # nothing — and an app that does (selecting the new row, say) takes
    # it from here rather than inventing a second name for the same
    # datum.
    todos.insert_fresh(Todo(title=draft))
    status.set(f"added {draft}, {len(todos)} total")
    keys.set(key_list())
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


def on_remove():
    """THE STEP WHOSE INVERSE IS AN IDENTITY, not a content. The core
    captured the entry and the instance's order before the removal, so
    undoing this puts the entry back under the key it already had, where
    it already was — neither of which this app has to remember."""
    entries = todos.items()
    if not entries:
        status.set(f"nothing to remove, {len(todos)} total")
        return
    # The collection's FIRST entry, from the model — never a widget — so
    # the entry that comes back has to come back BEFORE the one that
    # stayed.
    key, todo = entries[0]
    kaya.undoable(f"remove {todo.title}")
    todos.remove(key)
    status.set(f"removed {todo.title}, {len(todos)} total")
    keys.set(key_list())


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

    THE RUN IS TAKEN WHOLE, not reduced to one string, because an entry
    NAMES the field it restores: the empty path is the draft, and a path
    names the row whose note came back.

    The binding has already reconciled its collection mirror from this
    payload before this runs, which is why `len(todos)` below answers
    about the restored state.
    """
    fold_texts(delta.texts)
    history.set(f"undid {what(label)}, {len(todos)} total")
    # ONE TRANSACTION WITH THE LABEL ABOVE — a handler IS one here, so
    # this needs no ceremony, and it is deliberate: the script reads that
    # label first, so by the time it reads these the app's own answer is
    # what is on screen, not the value the core restored on its way past.
    # The notes ride the same transaction for the same reason.
    keys.set(key_list())
    notes.set(note_list())


def redone(label, delta):
    fold_texts(delta.texts)
    history.set(f"redid {what(label)}, {len(todos)} total")
    keys.set(key_list())
    notes.set(note_list())


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
        # THE SCENE'S WAY BACK TO THE FIELD. `star` does not move the
        # cursor on its own — an app that reaches for focus after every
        # action is deciding where the user is looking — so the scene
        # says so itself, and the routing question ("what is focused?")
        # stays visible in the script rather than hidden in a handler.
        kaya.button("focus", on_click=on_focus)             # button#2
        kaya.button("remove", on_click=on_remove)           # button#3
        for todo in todos:
            with kaya.row():
                kaya.label(bind=todo.title)
                # THE ROW'S OWN FIELD, and the reason this scene grew: a
                # copy's text edits are the same occurrence a live
                # field's are, one identity deeper, and the ledger banks
                # them the same way now that the payload can name them.
                # Python's template tier has no widget-kind floor to
                # reach for — the kind constructors ARE the surface in
                # both zones, and the binding allocates a node here
                # rather than a widget — so this is the same `entry`
                # call the draft above makes, handed a node handler
                # instead of a widget one.
                kaya.entry(on_change=on_note)

    # THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
    # holding focus when it does — and focus is the routing question's
    # other half.
    field.focus()

sys.exit(app.run())
