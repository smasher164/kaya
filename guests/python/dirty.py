"""The dirty-state conformance scene, Python port — unsaved work as
window chrome (docs/dirty-plan.md). The app declares STATE, and each
backend spells its own platform's affordance.

TWO DECLARATIONS, ON PURPOSE: an edit writes the document AND says
`dirty=True`. kaya does not watch your signals and guess.

See guests/rust/dirty.rs and tools/scenes/dirty.steps."""

import sys

import kaya

app = kaya.App()


def edit():
    doc.set("notes and a line")
    status.set("unsaved")
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
        # UNREACHED BY THE SCENE, AND IT ABORTS IF IT EVER RUNS: there is
        # no verb for agreeing to a close (docs/traps.md, "An app can
        # VETO a close but cannot AGREE to one"). The scene answers
        # cancel; this arm is the honest spelling, not a step.
        kaya.destroy_window(0)


def close_asked():
    # Nothing has closed yet: the veto class says so. The handler rides
    # the window construct at its declaration, so it can only ever mean
    # this surface's close.
    kaya.show_alert(
        title="unsaved changes",
        message="the document has unsaved changes",
        actions=["Discard"],
        cancel="Keep Editing",
        on_result=answered,
    )


# `dirty` and `veto_close` are orthogonal. This window does NOT declare
# dirty here: the default false is the scene's first assertion.
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
