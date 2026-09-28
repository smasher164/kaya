"""The scroll conformance scene, Python port — the viewport grows so
the enclosing track constrains it (an unconstrained viewport hugs its
content and nothing overflows); the bottom button, reachable only by
scrolling, proves the scrolled-to content is live. See
guests/rust/scroll.rs and tools/scenes/scroll.steps."""

import sys

import kaya

app = kaya.App()


def bottom_clicked():
    status.set("bottom clicked")


def last_card_clicked():
    status.set("last card clicked")


with app.window(title="scroll"):
    status = kaya.signal("at top")
    with kaya.column():
        kaya.label(bind=status)  # label#0
        with kaya.scroll(grow=1) as rows:
            with kaya.column():
                for i in range(1, 30):
                    kaya.label(bind=kaya.signal(f"row {i}"))
                kaya.button("bottom", on_click=bottom_clicked)  # button#0
        rows.a11y_id("rows")
        # A strip wider than the window, scrolled sideways
        # (docs/hscroll-plan.md), addressed as scroll@strip.
        with kaya.scroll(axis=kaya.Axis.HORIZONTAL) as strip:
            with kaya.row():
                for i in range(1, 20):
                    kaya.label(bind=kaya.signal(f"card {i}"))
                kaya.button("last card", on_click=last_card_clicked).a11y_id("last")
        strip.a11y_id("strip")

sys.exit(app.run())
