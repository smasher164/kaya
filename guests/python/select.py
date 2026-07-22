"""The select conformance scene, Python port. See
guests/rust/select.rs and tools/scenes/select.steps."""

import sys

import kaya

OPTIONS = ["Red", "Green", "Blue"]

app = kaya.App()


def on_select(index):
    picked.set(f"picked: {OPTIONS[index]}")


with app.window(title="select"):
    picked = kaya.signal("picked: Red")
    with kaya.column():
        kaya.select(OPTIONS, selected=0, on_select=on_select)
        kaya.label(bind=picked)

sys.exit(app.run())
