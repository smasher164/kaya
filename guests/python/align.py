"""The align conformance scene, Python port — see
guests/rust/align.rs and tools/scenes/align.steps for the full
rationale. The stretched root spans three container children across the
window; column#1 centers children of three different natural widths;
the row aligns baselines across a label, a button, and a tall
no-baseline image whose bottom sits ON the baseline (the CSS
replaced-element rule); and row#1 hosts the grown, stretched nested
column the ruling's own construction pins.
"""

import sys

import kaya

# A 100x20 PNG: exact pixel widths, so row@wrapped breaks onto two lines
# in every lane's window (docs/layout-knobs-plan.md §2).
WIDE_PNG = bytes([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68,
                  82, 0, 0, 0, 100, 0, 0, 0, 20, 8, 2, 0, 0, 0, 244,
                  162, 15, 194, 0, 0, 0, 56, 73, 68, 65, 84, 120, 218, 237, 208,
                  1, 13, 0, 0, 8, 3, 160, 7, 177, 164, 109, 141, 99, 133, 7,
                  96, 35, 1, 153, 61, 74, 81, 32, 75, 150, 44, 89, 178, 100, 41,
                  144, 37, 75, 150, 44, 89, 178, 20, 200, 146, 37, 75, 150, 44, 89,
                  10, 122, 15, 34, 121, 229, 167, 65, 55, 75, 87, 0, 0, 0, 0,
                  73, 69, 78, 68, 174, 66, 96, 130])

TALL_PNG = bytes([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68,
                  82, 0, 0, 0, 2, 0, 0, 0, 64, 8, 2, 0, 0, 0, 191,
                  68, 49, 20, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 8,
                  8, 138, 2, 34, 134, 81, 106, 104, 82, 0, 67, 50, 126, 1, 49,
                  1, 65, 124, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])

app = kaya.App()

with app.window():
    probe = kaya.signal("align probe")
    base = kaya.signal("base")
    anchor = kaya.signal("anchor")
    fit = kaya.signal("fit")
    plain = kaya.signal("plain probe")

    with kaya.column(align="stretch") as root:
        root.a11y_id("root")
        with kaya.column(align="center") as centered:  # the center trio
            centered.a11y_id("centered")
            kaya.label(bind=probe)  # label#0
            kaya.button("mid")
            with kaya.row(align="baseline") as baseline:  # the baseline trio
                baseline.a11y_id("baseline")
                kaya.label(bind=base)  # label#1
                kaya.button("tick")
                kaya.image(TALL_PNG)
        with kaya.row():  # row#1: the stretch pair's host
            kaya.label(bind=anchor)  # label#2
            with kaya.column(grow=1, align="stretch") as fitcol:
                fitcol.a11y_id("fitcol")
                kaya.label(bind=fit)  # label#3
                kaya.button("wide")
        # row@plain: NO align, so the core's centre default is what the
        # scene reads
        with kaya.row() as plain_row:
            plain_row.a11y_id("plain")
            kaya.label(bind=plain).a11y_id("plainlabel")  # label#4
            kaya.image(TALL_PNG)
        # column@knobs: NO align; fill opts one child out of its default
        # and one in
        with kaya.column() as knobs:
            knobs.a11y_id("knobs")
            kaya.textarea().fill(False).a11y_id("optout")
            kaya.button("fills").fill(True).a11y_id("fills")
            # row@wrapped: six exact-width images flow onto two lines
            with kaya.row() as wrapped:
                wrapped.wrap(True).a11y_id("wrapped")
                for _ in range(6):
                    kaya.image(WIDE_PNG)

sys.exit(app.run())
