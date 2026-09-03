"""The panels conformance scene (tools/scenes/panels.steps): the inspector
is one create_window scope, its veto class one handler."""

import sys

import kaya

app = kaya.App()

with app.window(title="panels"):
    status = kaya.signal("two panels")
    with kaya.column():
        kaya.label(bind=status)  # label#0

INSPECTOR = 1


def close_asked():
    # Bound at the inspector's declaration: only THIS window's close.
    status.set("close requested")
    kaya.destroy_window(INSPECTOR)


with app.create_window(INSPECTOR, title="inspector", width=480, height=320,
                    veto_close=True, on_close_requested=close_asked):
    caption = kaya.signal("inspector pane")
    with kaya.column():
        kaya.label(bind=caption)  # label#1


sys.exit(app.run())
