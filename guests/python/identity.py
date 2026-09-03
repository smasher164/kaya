"""The app-identity scene (tools/scenes/identity.steps): the mark's four
flat quadrants, and a second window whose blank title the NAME fills."""

import sys

import kaya

app = kaya.App()

UNTITLED = 1

draft = ""


def on_change(text):
    global draft
    draft = text


def on_go():
    status.set(f"clicked {draft}")


with app.window(title="identity", width=480.0, height=360.0):
    # BEFORE THE FIRST MOUNT: the scope mounts on exit.
    with kaya.asset("icons/kaya-mark.png") as icon:
        kaya.app_identity("Aurora Notes", icon=icon)

    # ONE PROMOTED COMMAND, AND NOT ABOUT COMMANDS: Windows mints its
    # custom caption from it, replacing the system-drawn icon.
    with app.menu("File"):
        kaya.item("Save", symbol=kaya.Symbol.DONE, primary=True)

    heading = kaya.signal("identity")
    status = kaya.signal("ready")
    with kaya.column():
        kaya.label(bind=heading)  # label#0
        kaya.label(bind=status)  # label#1
        kaya.entry(on_change=on_change)  # entry#0
        kaya.button("Go", on_click=on_go)  # button#0

# No title at all: an empty string is a title an app WROTE. The host is
# asked in every port, even where the answer is never no.
if kaya.capabilities().aux_windows:
    with app.create_window(UNTITLED, width=360.0, height=240.0):
        caption = kaya.signal("no title of its own")
        with kaya.column():
            kaya.label(bind=caption)  # label#2

sys.exit(app.run())
