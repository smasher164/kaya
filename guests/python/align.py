"""The align conformance scene, Python port — see
guests/rust/align.rs and tools/scenes/align.steps for the full
rationale. The root column centers children of three different natural
widths; the row aligns baselines across a label, a checkbox, and a
tall no-baseline image whose bottom sits ON the baseline (the CSS
replaced-element rule) — the construction that separates the modes on
every platform's control metrics.

`align=` at construction is the declarative spelling; Widget.align is
the dynamic path this scene has no reason to use.
"""

import sys

import kaya

TALL_PNG = bytes([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68,
                  82, 0, 0, 0, 2, 0, 0, 0, 64, 8, 2, 0, 0, 0, 191,
                  68, 49, 20, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 8,
                  8, 138, 2, 34, 134, 81, 106, 104, 82, 0, 67, 50, 126, 1, 49,
                  1, 65, 124, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])

app = kaya.App()

with app.window():
    probe = kaya.signal("align probe")
    base = kaya.signal("base")

    with kaya.column(align="center"):
        kaya.label(bind=probe)  # label#0
        kaya.button("mid")
        with kaya.row(align="baseline"):
            kaya.label(bind=base)  # label#1
            kaya.button("tick")
            kaya.image(TALL_PNG)

sys.exit(app.run())
