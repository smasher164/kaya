"""The confirm conformance scene, Python port — the modal-alert grammar:
TWO dialogs from two buttons (delete has two actions, eject one), each
bound to its OWN handler at show time. The result handler rides the
REQUEST and retires with its one answer; ids are binding-allocated, so
the guest carries no correlation plumbing.
See guests/rust/confirm.rs and tools/scenes/confirm.steps."""

import sys

import kaya

app = kaya.App()


def delete_answered(choice):
    if choice == kaya.CANCEL:
        status.set("kept")
    elif choice == 1:
        status.set("archived")
    else:
        status.set("deleted")


def eject_answered(choice):
    status.set("held" if choice == kaya.CANCEL else "ejected")


def ask_delete():
    kaya.show_alert(
        title="delete item?",
        message="this cannot be undone",
        actions=["Delete", "Archive"],
        cancel="Keep",
        on_result=delete_answered,
    )


def ask_eject():
    kaya.show_alert(
        title="eject disk?",
        message="it is still mounted",
        actions=["Eject"],
        cancel="Hold",
        on_result=eject_answered,
    )


with app.window(title="confirm"):
    status = kaya.signal("no decision")
    with kaya.column():
        kaya.label(bind=status)  # label#0
        kaya.button("delete", on_click=ask_delete)
        kaya.button("eject", on_click=ask_eject)

sys.exit(app.run())
