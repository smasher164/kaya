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


with app.window(title="scroll"):
    status = kaya.signal("at top")
    with kaya.column():
        kaya.label(bind=status)  # label#0
        with kaya.scroll(grow=1):  # scroll#0
            with kaya.column():
                for i in range(1, 30):
                    kaya.label(bind=kaya.signal(f"row {i}"))
                kaya.button("bottom", on_click=bottom_clicked)  # button#0

sys.exit(app.run())
