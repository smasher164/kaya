"""The typeface conformance scene, Python port (docs/styling-plan.md
Slice 2b): the brand typeface swaps the FAMILY and leaves the platform's
ramp alone.

The scene names NO SIZE anywhere: sizes, weights and metrics stay the
platform's, and the role tier carries emphasis (`Role.HEADING` on the
title label below).

WHY A BUNDLED FONT — the canonical note is guests/rust/typeface.rs's doc
comment. `font=` is Python's spelling of the blob form; `platforms=` is
the per-platform mapping a name-based app would reach for instead.

THE FONT IS AN ASSET NOW (docs/assets-plan.md, ratified 2026-08-18).
This scene used to read `KAYA_FONT_FILE` with a repo-relative default
and raise in its own words, as its seven siblings each did in their own
language. `kaya.asset(name)` is the whole thing now: where the file
lives is the core's knowledge, and the failure sentence has one author.

The byte-frozen contract is tools/scenes/typeface.steps."""

import sys

import kaya

app = kaya.App()


draft = ""


def on_change(text):
    # The fold: widget-owned state arrives as occurrences, and the app's
    # copy is this variable rather than a widget read.
    global draft
    draft = text


def on_go():
    status.set(f"clicked {draft}")


with app.window(title="typeface", width=480.0, height=360.0):
    # BEFORE THE FIRST MOUNT, per the set-once wall. The scope mounts on
    # exit, so anywhere in this body is before it. The blob registers
    # with the platform's app-font machinery and the "Sora" request then
    # resolves to it.
    # The asset's bytes go from the core's read straight to the
    # platform's font API: this scene never holds them, and the `with`
    # releases the core's handle on the way out.
    with kaya.asset("fonts/sora-wght.ttf") as font:
        kaya.brand_typeface("Sora", font=font)
    heading = kaya.signal("typeface")
    status = kaya.signal("ready")
    with kaya.column():
        # The heading's text style OVERRIDES the root font, so this label
        # is the one a root-only lowering leaves in the system face;
        # expect_ax resolves it through its authored id.
        kaya.label(bind=heading).role(kaya.Role.HEADING).a11y_id("title")  # label#0
        kaya.label(bind=status)  # label#1
        # Both a field and a textarea: they take the swap by DIFFERENT
        # routes (the field inherits the root font, the textarea names its
        # own ramp rung), so one alone could not tell a half-applied
        # lowering from a whole one.
        kaya.entry(on_change=on_change)  # entry#0
        kaya.textarea()  # textarea#0
        kaya.button("Go", on_click=on_go)  # button#0

sys.exit(app.run())
