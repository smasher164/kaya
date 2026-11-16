"""The layers scene (tools/scenes/layers.steps; docs/layering-plan.md LY13): a
cover with a badge, a caption on the fade form and a button over it; a button
with a badge at its trailing end; a button under a veil, an unfilled column
spanning it with a panel at its centre, that takes its taps until it is
hidden; a cover with the flat overlay panel; and the log of which handler
answered each tap. See guests/rust/layers.rs."""

import sys

import kaya

app = kaya.App()
log = ["taps:"]


def answer(word):
    log.append(word)
    answered.set(" ".join(log))


def on_hide():
    answer("hide")
    veiled.set(True)


with app.window(title="layers", width=480, height=860):
    answered = kaya.signal("taps:")
    veiled = kaya.signal(False)
    with kaya.column(spacing=16):
        with kaya.layers(inset=8) as stack:
            stack.a11y_id("photostack")
            kaya.image(kaya.asset("covers/cover-600.jpg")).max_width(320).a11y_label(
                "Kind of Blue cover").a11y_id("photo")
            with kaya.row(filled=kaya.Tint.ACCENT) as badge:
                badge.place(kaya.Place.TOP_TRAILING).a11y_id("badge")
                kaya.label("3").a11y_id("badge_text")
            with kaya.row(filled=kaya.Tint.OVERLAY_FADE) as caption:
                caption.place(kaya.Place.BOTTOM).a11y_id("caption")
                kaya.label("Kind of Blue").a11y_id("caption_text")
            kaya.button("Share", on_click=lambda: answer("share")).place(
                kaya.Place.BOTTOM_TRAILING).a11y_id("share")
        with kaya.layers() as stack:
            stack.a11y_id("veilstack")
            kaya.button("Press the base button here", on_click=lambda: answer("base")).a11y_id("base")
            with kaya.column(align=kaya.Align.CENTER) as veil:
                veil.fill(True).hidden(veiled).a11y_id("busy")
                with kaya.row(filled=kaya.Tint.OVERLAY):
                    kaya.label("Busy")
        with kaya.layers() as stack:
            stack.a11y_id("sidestack")
            kaya.button("Open the inbox", on_click=lambda: answer("side")).a11y_id("side")
            with kaya.row(filled=kaya.Tint.ACCENT) as side_badge:
                side_badge.place(kaya.Place.TRAILING).a11y_id("sidebadge")
                kaya.label("5")
        with kaya.layers(inset=8) as stack:
            stack.a11y_id("flatstack")
            kaya.image(kaya.asset("covers/cover-320.jpg")).max_width(200).a11y_label(
                "Small cover").a11y_id("smallphoto")
            with kaya.row(filled=kaya.Tint.OVERLAY) as flat:
                flat.place(kaya.Place.TOP_LEADING).a11y_id("flat")
                kaya.label("Flat panel").a11y_id("flat_text")
        kaya.label(bind=answered).a11y_id("answered")
        kaya.button("Hide the veil", on_click=on_hide).a11y_id("hideveil")

sys.exit(app.run())
