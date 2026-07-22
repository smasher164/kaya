"""The radio conformance scene, Python port. See
guests/rust/radio.rs and tools/scenes/radio.steps."""

import sys

import kaya

OPTIONS = ["Small", "Medium", "Large"]

app = kaya.App()


def on_select(index):
    size.set(f"size: {OPTIONS[index]}")


with app.window(title="radio"):
    size = kaya.signal("size: Small")
    with kaya.column():
        kaya.radio(OPTIONS, selected=0, on_select=on_select)
        kaya.label(bind=size)

sys.exit(app.run())
