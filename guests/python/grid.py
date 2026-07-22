"""The grid conformance scene, Python port. See
guests/rust/grid.rs and tools/scenes/grid.steps."""

import sys

import kaya

app = kaya.App()

with app.window(title="grid"):
    with kaya.column():
        with kaya.grid(2):
            kaya.label(text="Name:")  # label#0
            kaya.label(text="Ada Lovelace")  # label#1
            kaya.label(text="Role:")  # label#2
            kaya.label(text="Engine programmer")  # label#3
        with kaya.row(grow=1.0):
            kaya.button("left")  # button#0
            kaya.spacer()
            kaya.button("right")  # button#1

sys.exit(app.run())
