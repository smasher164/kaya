"""The typeface conformance scene, Python port (docs/styling-plan.md
Slice 2b): the brand typeface swaps the FAMILY and leaves the platform's
ramp alone.

One call is the whole surface — a family name, plus the per-platform rows
a lane needs — and everything after it is ordinary widgets, which is the
claim the scene makes: a typeface is chrome, so the field still takes
text and the button still fires. What it does NOT do is name a size
anywhere. Sizes, weights and metrics stay the platform's; the role tier
is what carries emphasis (`Role.HEADING` on the title label below), and
that is exactly what makes a family swap safe.

WHY A BUNDLED FONT, and why no per-platform row: the reasoning is in
guests/rust/typeface.rs's doc comment, which is the canonical note for
this scene. In short, the scene requests the VENDORED font's bytes so
the resolved family is one string on every lane and no platform's
fallback can equal it. `font=` is Python's spelling of the blob form;
`platforms=` — the per-platform mapping — is what a name-based app would
reach for instead, and this scene needs none.

The byte-frozen contract is tools/scenes/typeface.steps."""

import os
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
    # BEFORE THE FIRST MOUNT, per the set-once wall: brand is identity,
    # not state, and a backend never sees a typeface it would have to
    # un-apply. The scope mounts on exit, so anywhere in this body is
    # before it — declared first because that is where it reads.
    # THE VENDORED BYTES, then the family they carry: the blob registers
    # with the platform's app-font machinery and the "Sora" request
    # resolves to it — register-then-resolve, the same call a brand
    # book's licensed font would make.
    font_path = os.environ.get(
        "KAYA_FONT_FILE", "guests/assets/fonts/sora-wght.ttf")
    try:
        with open(font_path, "rb") as handle:
            font = handle.read()
    except OSError as exc:
        raise RuntimeError(
            f"kaya: the typeface scene needs the vendored font at "
            f"{font_path} (set KAYA_FONT_FILE or run from the repo root): "
            f"{exc}"
        ) from exc
    kaya.brand_typeface("Sora", font=font)
    heading = kaya.signal("typeface")
    status = kaya.signal("ready")
    with kaya.column():
        # The heading's text style OVERRIDES the root font, so this label
        # is the one a root-only lowering leaves in the system face.
        # expect_ax resolves it through its authored id, the a11y scene's
        # discipline.
        kaya.label(bind=heading).role(kaya.Role.HEADING).a11y_id("title")  # label#0
        kaya.label(bind=status)  # label#1
        # A FIELD AND A TEXTAREA, because they are the two views the
        # observation reads (NSTextField and NSTextView on this platform)
        # and they arrive by DIFFERENT routes: the field inherits the
        # root font, the textarea names its own ramp rung and takes the
        # swap explicitly. A scene with one of them could not tell a
        # half-applied lowering from a whole one.
        kaya.entry(on_change=on_change)  # entry#0
        kaya.textarea()  # textarea#0
        kaya.button("Go", on_click=on_go)  # button#0

sys.exit(app.run())
