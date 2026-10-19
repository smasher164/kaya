"""The grounds scene (tools/scenes/grounds.steps; docs/styling-pass-plan.md
Y2, Y3): an artist header covered by the picture with the name on the
platform's panel, at the top of a window giving no inset (on a phone it runs
under the status bar, docs/media-player-plan.md M15), an album header fading
from the art's own colour into the page, and a column with no ground. See guests/rust/grounds.rs."""

import sys

import kaya

app = kaya.App()
art = kaya.asset("covers/cover-600.jpg").bytes()
colour = kaya.image_dominant(art)
assert colour is not None, "the cover decodes"

with app.window(title="grounds", width=480, height=560, inset=0):
    with kaya.column(spacing=12):
        with kaya.column(inset=24, ground_image=art) as hero:
            hero.a11y_id("hero")
            with kaya.row(filled=kaya.Tint.OVERLAY) as scrim:
                scrim.a11y_id("scrim")
                kaya.label("Miles Davis")
        with kaya.column(inset=24, ground_gradient=colour) as header:
            header.a11y_id("header")
            kaya.heading("Kind of Blue").a11y_id("title")
            kaya.caption("Miles Davis · 1959")
        with kaya.column(inset=24) as plain:
            plain.a11y_id("plain")
            kaya.label("Plain")

sys.exit(app.run())
