"""The confirm conformance scene, Python port — the modal-alert
grammar (the request/result grammar's first client): TWO different
dialogs from two buttons — delete (two actions) and eject (one) —
each bound to its OWN handler at show time, so the association is
the registration itself. The result
handler rides the REQUEST (on_result=, the widget-handler
precedent) and retires with its one answer; ids are
binding-allocated, so the guest carries no correlation plumbing.
See guests/rust/confirm.rs and tools/scenes/confirm.steps."""

import sys

import kaya

app = kaya.App()


def delete_answered(choice):
    with app.build():
        if choice == kaya.CANCEL:
            status.set("kept")
        elif choice == 1:
            status.set("archived")
        else:
            status.set("deleted")


def eject_answered(choice):
    # A different dialog, a different handler: the association is the
    # registration itself — this function can never see a delete
    # answer.
    with app.build():
        status.set("held" if choice == kaya.CANCEL else "ejected")


def ask_delete():
    # A widget handler runs inside the ambient transaction already;
    # the request rides the same commit as any other mutation.
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
