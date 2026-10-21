"""The dock scene (tools/scenes/dock.steps; docs/styling-pass-plan.md Y8): a
window with a now-playing bar docked under its content, gone while nothing
plays because the dock's root then holds no widget. See guests/rust/dock.rs."""

import sys

import kaya

app = kaya.App()
art = kaya.asset("covers/cover-600.jpg").bytes()

with app.window(title="dock", width=720, height=480):
    playing = kaya.signal(True)
    player = kaya.player(muted=True)
    with app.dock(40, player=player):
        with kaya.column():
            with kaya.when(playing):
                with kaya.row() as bar:
                    bar.a11y_id("bar")
                    kaya.image(art, fit=kaya.Fit.COVER, shape=kaya.Shape.ROUNDED) \
                        .max_width(40).max_height(40)
                    with kaya.column():
                        kaya.label("Blue in Green")
                        kaya.caption("Miles Davis")
                    kaya.slider(0.4, min=0.0, max=1.0).a11y_id("progress")
                    kaya.button("Pause").a11y_id("pause")
    with kaya.column():
        kaya.label("Library")
        kaya.button("stop", on_click=lambda: playing.set(False)).a11y_id("stop")
        kaya.button("play", on_click=lambda: playing.set(True)).a11y_id("play")

sys.exit(app.run())
