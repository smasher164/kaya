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

sys.exit(app.run())
