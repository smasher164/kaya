"""The panels conformance scene, Python port — the north-star
spelling for the auxiliary-window grammar: the inspector is one
`create_window` scope, its veto class one handler. See
guests/rust/panels.rs and tools/scenes/panels.steps."""

import sys

import kaya

app = kaya.App()

with app.window(title="panels"):
    status = kaya.signal("two panels")
    with kaya.column():
        kaya.label(bind=status)  # label#0

INSPECTOR = 1


def close_asked():
    # Bound to the inspector at its declaration (handlers scope to
    # the thing that creates them): this can only ever mean this
    # window's close was vetoed.
    with app.build():
        status.set("close requested")
        kaya.destroy_window(INSPECTOR)


with app.create_window(INSPECTOR, title="inspector", width=480, height=320,
                    veto_close=True, on_close_requested=close_asked):
    caption = kaya.signal("inspector pane")
    with kaya.column():
        kaya.label(bind=caption)  # label#1


sys.exit(app.run())
