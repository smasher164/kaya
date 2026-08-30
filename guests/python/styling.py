"""The styling conformance scene, Python port (docs/styling-plan.md,
slice 1): the brand accent, the role tier and the window inset, together
because they are one design — brand slots fill each platform's token
system, roles say what a widget MEANS, and the inset is the one layout
knob the pass admitted (D3).

`0x3584E4` is Adwaita blue, the derivation's empirical anchor; one hex is
the whole call and a platform may let its user override the result (D2).
The per-appearance form is `dark=`/`light=` on the same call.
`Role.HEADING` is the one role the steps freeze from the real tree on
every lane. `inset=0.0` is full bleed, honored unconditionally (D3).

See guests/rust/styling.rs; the byte-frozen contract is
tools/scenes/styling.steps."""

import sys

import kaya

app = kaya.App()


def delete():
    status.set("deleted")


def save():
    status.set("saved")


with app.window(title="styling", width=480.0, height=360.0, inset=0.0):
    # BEFORE THE FIRST MOUNT, per the set-once wall. The scope mounts on
    # exit, so anywhere in this body is before it.
    kaya.brand_accent(0x3584E4)
    heading = kaya.signal("Sections")
    status = kaya.signal("ready")
    with kaya.column():
        # expect_ax resolves a target through its AUTHORED id into the
        # real tree, so everything the steps read back is identified.
        kaya.heading(bind=heading).a11y_id("title")  # label#0
        kaya.label(bind=status)  # label#1
        kaya.button("Delete", on_click=delete).role(
            kaya.Role.DESTRUCTIVE).a11y_id("delete")  # button#0
        kaya.button("Save", on_click=save).role(
            kaya.Role.PROMINENT).a11y_id("save")  # button#1
        # DECLARED SO EVERY BACKEND'S CAPTION ARM RUNS, like the two
        # button roles above: the look has no universal AX observable
        # (only GTK has a caption role), so the walls are the arms'
        # own refusals plus this label's text.
        kaya.caption("captioned")  # label#2

sys.exit(app.run())
