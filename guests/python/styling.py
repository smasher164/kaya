"""The styling conformance scene, Python port (docs/styling-plan.md,
slice 1): the brand accent, the role tier and the window inset, together
because they are one design — brand slots fill each platform's token
system, roles say what a widget MEANS, and the inset is the one layout
knob the pass admitted (D3).

What each piece demonstrates:
  - `kaya.brand_accent(0x3584E4)` — Adwaita blue, the derivation's
    empirical anchor: one hex is the whole call, the core derives fills
    and foregrounds, and a platform may let its user override the result
    (D2). The per-appearance form is `dark=`/`light=` keywords on this
    same call, which most apps never write.
  - `.role(kaya.Role.HEADING)` on the title label — the platform's
    heading text style AND the assistive heading trait, which is the one
    role the steps freeze from the real tree on every lane.
  - `.role(kaya.Role.DESTRUCTIVE)` / `.role(kaya.Role.PROMINENT)` on the
    two buttons — the platform's own emphasis chrome, and (the scene's
    point) NO change to what pressing them does.
  - `inset=0.0` — full bleed, the editor's own need, honored
    unconditionally because the inset is kaya's padding (D3).

See guests/rust/styling.rs; the byte-frozen contract is
tools/scenes/styling.steps."""

import sys

import kaya

app = kaya.App()


def delete():
    # A ROLE NEVER CHANGES WHAT A BUTTON DOES: the destructive button
    # presses like any other and this handler is what acts.
    status.set("deleted")


def save():
    status.set("saved")


with app.window(title="styling", width=480.0, height=360.0, inset=0.0):
    # BEFORE THE FIRST MOUNT, per the set-once wall: brand is identity,
    # not state. The scope mounts on exit, so anywhere in this body is
    # before it — declared first because that is where it reads.
    kaya.brand_accent(0x3584E4)
    heading = kaya.signal("Sections")
    status = kaya.signal("ready")
    with kaya.column():
        # expect_ax resolves a target through its AUTHORED id into the
        # real tree, so everything the steps read back is identified
        # (the a11y scene's discipline).
        kaya.label(bind=heading).role(kaya.Role.HEADING).a11y_id("title")  # label#0
        kaya.label(bind=status)  # label#1
        kaya.button("Delete", on_click=delete).role(
            kaya.Role.DESTRUCTIVE).a11y_id("delete")  # button#0
        kaya.button("Save", on_click=save).role(
            kaya.Role.PROMINENT).a11y_id("save")  # button#1

sys.exit(app.run())
