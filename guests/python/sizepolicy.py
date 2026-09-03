"""The canvas size-policy scene (tools/scenes/sizepolicy.steps). ALL FOUR
CANVASES GROW, or an ungrown track IS its viewbox and nothing differs."""

import sys

import kaya

# The declared box of the two CONSTANT-mode canvases.
BOX = (300.0, 120.0)


def panel(d, box, left, top, right, bottom, paint):
    """An axis-aligned rectangle at left..right and top..bottom as
    FRACTIONS of the box, filled with one paint role."""
    w, h = box
    (d.move_to(left * w, top * h)
     .line_to(right * w, top * h)
     .line_to(right * w, bottom * h)
     .line_to(left * w, bottom * h)
     .close()
     .fill(paint))


def figure(d, box):
    """The figure the three drawing canvases share: a ground panel inset
    a twentieth of the width with a translucent series panel over its
    middle half."""
    panel(d, box, 0.05, 0.0, 0.95, 1.0, "ground")
    panel(d, box, 0.25, 0.0, 0.75, 1.0, "series_fill")


def bar(d, box, frame):
    """The animating canvas's bar, whose RIGHT EDGE is the frame number:
    35 hundredths plus ten per frame."""
    panel(d, box, 0.25, 0.0, 0.35 + 0.10 * frame, 1.0, "axis")


def frame_of(time):
    """Seconds back to the frame the harness drove. The guest reads the
    time it was HANDED and never a clock of its own (§15.4)."""
    return max(0, round(time * 60.0))


app = kaya.App()

with app.window(title="sizepolicy", width=480, height=420):
    with kaya.column():
        # SCALE, the default: declared by writing nothing.
        fit = kaya.canvas(BOX, grow=1)
        fit.a11y_id("fit").a11y_label("Scaled panel")
        with fit.draw() as d:
            figure(d, BOX)

        # FIXED: drawn at BOX and blitted 1:1.
        mark = kaya.canvas(BOX, grow=1, fixed=True)
        mark.a11y_id("mark").a11y_label("Fixed mark")
        with mark.draw() as d:
            figure(d, BOX)

        # REDRAW: this viewbox is only the size before the first answer.
        live = kaya.canvas(BOX, grow=1, on_draw=figure)
        live.a11y_id("live").a11y_label("Redrawn panel")

        # TICK: once a frame, at the time the platform supplied.
        clock = kaya.canvas(
            BOX, grow=1,
            on_tick=lambda d, size, time: bar(d, size, frame_of(time)))
        clock.a11y_id("clock").a11y_label("Animated bar")

sys.exit(app.run())
