"""The window conformance scene, Python port — see guests/rust/window.rs
and tools/scenes/window.steps. The north-star spelling from DESIGN.md's
appendix, live: the surface's props ride the window() scope itself."""

import sys

import kaya

app = kaya.App()

with app.window(title="window probe", width=640, height=400):
    probe = kaya.signal("window probe")
    with kaya.column():
        kaya.label(bind=probe)  # label#0

sys.exit(app.run())
