"""The dirty-state scene (tools/scenes/dirty.steps). TWO DECLARATIONS, on
purpose: kaya does not watch your signals and guess."""

import sys

import kaya

app = kaya.App()


def edit():
    doc.set("notes and a line")
    status.set("unsaved")
    app.window(dirty=True)


def save():
    status.set("saved")
    # The mark comes DOWN as well as up: only this assertion sees it.
    app.window(dirty=False)


def answered(choice):
    if choice == kaya.CANCEL:
        # Answering a dialog is not saving: the mark stays up.
        status.set("kept editing")
    else:
        # ABORTS if it runs — docs/traps.md, "An app can VETO a close but
        # cannot AGREE to one".
        kaya.destroy_window(0)


def close_asked():
    # Nothing has closed yet; the handler rides this window's declaration.
    kaya.show_alert(
        title="unsaved changes",
        message="the document has unsaved changes",
        actions=["Discard"],
        cancel="Keep Editing",
        on_result=answered,
    )


# Dirty is NOT declared here: the script reads the clean window first.
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
