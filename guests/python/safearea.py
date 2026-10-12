"""The safe-area scene (tools/scenes/safearea.steps; docs/safe-area-plan.md
A3, A8)."""

import sys

import kaya

GROUND = (300.0, 200.0)


def ground(d, size):
    w, h = size
    d.move_to(0.0, 0.0).line_to(w, 0.0).line_to(w, h).line_to(0.0, h).close().fill("series_fill")


app = kaya.App()


def no_inset():
    app.window(inset=0)
    caption.set("inset 0")


def fullscreen():
    app.window(fullscreen=True)
    caption.set("fullscreen")


with app.window(title="safearea", width=420, height=640):
    caption = kaya.signal("inset 16")
    with kaya.column():
        with kaya.asset("images/photo.jpg") as photo:
            kaya.image(photo, bleed=True).max_height(160).a11y_id("picture").a11y_label("Photo")
        kaya.label(bind=caption).a11y_id("caption")
        kaya.button("No inset", on_click=no_inset).a11y_id("inset")
        kaya.button("Fullscreen", on_click=fullscreen).a11y_id("full")
        kaya.canvas(GROUND, grow=1, on_draw=ground, bleed=True).a11y_id("ground").a11y_label("Ground")

sys.exit(app.run())
