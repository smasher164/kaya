"""The panels conformance scene, Python port — the north-star
spelling for the auxiliary-window grammar: the inspector is one
`aux_window` scope, its veto class one handler. See
guests/rust/panels.rs and tools/scenes/panels.steps."""

import sys

import kaya

app = kaya.App()

with app.window(title="panels"):
    status = kaya.signal("two panels")
    with kaya.column():
        kaya.label(bind=status)  # label#0

with app.aux_window(1, title="inspector", width=480, height=320,
                    veto_close=True):
    caption = kaya.signal("inspector pane")
    with kaya.column():
        kaya.label(bind=caption)  # label#1


def close_asked(window_id):
    with app.build():
        status.set("close requested")
        kaya.destroy_window(window_id)


app.on_close_requested(close_asked)

sys.exit(app.run())
