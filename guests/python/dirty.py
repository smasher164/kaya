"""The dirty-state conformance scene, Python port — unsaved work as
window chrome (docs/dirty-plan.md). One boolean beside `title` and
`veto_close` on the window construct: the app declares STATE, and each
backend spells its own platform's affordance — the dot in the close
button on macOS, a leading `*` in the rendered caption on Windows, a
bullet in the GTK header bar, nothing on the phones, which have none.

TWO DECLARATIONS, ON PURPOSE. An edit writes the document AND says
`dirty=True`; saving writes it back and says `dirty=False`. kaya does
not watch your signals and guess — "the document has unsaved changes"
is a statement only the app can make, and the window construct is where
it makes it.

AND THE MARK ARMS NOTHING. The close attempt fires the veto class this
window already opted into, the app opens its own dialog, and cancelling
keeps the window with the mark still up. That flow is composed here out
of parts that predate this prop — which is the whole reason `dirty` is
presentation and nothing else.

See guests/rust/dirty.rs and tools/scenes/dirty.steps."""

import sys

import kaya

app = kaya.App()


def edit():
    # ONE TRANSACTION, THREE STATEMENTS: a widget handler already runs
    # inside one, so these commit together. Neither implies the other —
    # writing the document does not mark the window, and marking it
    # writes nothing.
    doc.set("notes and a line")
    status.set("unsaved")
    # The LIVE spelling of the window construct: the same call, without
    # the `with`, because this handler's transaction is already open. A
    # window attribute never lives as a loose function outside the
    # construct (DESIGN.md, Binding conventions).
    app.window(dirty=True)


def save():
    status.set("saved")
    # The mark comes DOWN as well as up — a lowering that only ever sets
    # the flag would pass every assertion before this one.
    app.window(dirty=False)


def answered(choice):
    if choice == kaya.CANCEL:
        # Answering a dialog is not saving: the mark stays up.
        status.set("kept editing")
    else:
        # Agreeing destroys the surface, which for the PRIMARY window is
        # the process itself — so the scene answers cancel and this arm
        # stays the honest spelling of "yes, close it" rather than a
        # step.
        kaya.destroy_window(0)


def close_asked():
    # Nothing has closed: the veto class says so. An editor with unsaved
    # work asks; a clean one agrees at once. The handler rides the window
    # construct at its declaration, so it can only ever mean this
    # surface's close.
    kaya.show_alert(
        title="unsaved changes",
        message="the document has unsaved changes",
        actions=["Discard"],
        cancel="Keep Editing",
        on_result=answered,
    )


# `dirty` and `veto_close` are orthogonal — either can be set without the
# other, on every platform. This window takes veto_close because it is an
# editor: it owns its close so it can ask. It does NOT declare dirty
# here, deliberately — the default false is the scene's first assertion.
with app.window(title="dirty", veto_close=True,
                on_close_requested=close_asked):
    doc = kaya.signal("notes")
    status = kaya.signal("saved")
    with kaya.column():
        kaya.label(bind=doc)  # label#0
        kaya.label(bind=status)  # label#1
        kaya.button("edit", on_click=edit)  # button#0
        kaya.button("save", on_click=save)  # button#1

sys.exit(app.run())
