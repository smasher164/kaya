"""The styling conformance scene (tools/scenes/styling.steps): brand accent,
role tier, window inset."""

import sys

import kaya

app = kaya.App()


def delete():
    status.set("deleted")


def save():
    status.set("saved")


with app.window(title="styling", width=480.0, height=360.0, inset=0.0):
    # BEFORE THE FIRST MOUNT: the scope mounts on exit.
    kaya.brand_accent(0x3584E4)
    heading = kaya.signal("Sections")
    status = kaya.signal("ready")
    with kaya.column():
        # expect_ax resolves a target through its AUTHORED id.
        kaya.heading(bind=heading).a11y_id("title")  # label#0
        kaya.label(bind=status)  # label#1
        kaya.button("Delete", on_click=delete).role(
            kaya.Role.DESTRUCTIVE).a11y_id("delete")  # button#0
        kaya.button("Save", on_click=save).role(
            kaya.Role.PROMINENT).a11y_id("save")  # button#1
        # Declared so every backend's caption arm runs: no AX observable.
        kaya.caption("captioned")  # label#2

sys.exit(app.run())
