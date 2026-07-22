"""The progress conformance scene, Python port. See
guests/rust/progress.rs and tools/scenes/progress.steps."""

import sys

import kaya

app = kaya.App()

with app.window(title="progress"):
    with kaya.column():
        kaya.progress(value=0.25)  # progress#0
        kaya.progress(indeterminate=True)  # progress#1

sys.exit(app.run())
