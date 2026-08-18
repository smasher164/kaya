"""The app-identity conformance scene, Python port: an app declares what
it is called and what it looks like, and the platform shows both.
Canonical semantics in guests/rust/identity.rs; the byte-frozen contract
in tools/scenes/identity.steps.

THE MARK IS THE VENDORED ONE (guests/assets/icons/kaya-mark.png, four
flat quadrants) because no platform's own default icon can land on four
declared colours, so a lowering that never applied can never read as a
pass. KAYA_ICON_FILE is how a runner that cannot see the repo points at
a pushed copy.

THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is the
blank an app's NAME fills on every platform.
"""

import os
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
    # BEFORE THE FIRST MOUNT, per the declared-once wall. The scope
    # mounts on exit, so anywhere in this body is before it.
    icon_path = os.environ.get(
        "KAYA_ICON_FILE", "guests/assets/icons/kaya-mark.png")
    try:
        with open(icon_path, "rb") as handle:
            icon = handle.read()
    except OSError as exc:
        raise RuntimeError(
            f"kaya: the identity scene needs the vendored mark at "
            f"{icon_path} (set KAYA_ICON_FILE or run from the repo root): "
            f"{exc}"
        ) from exc
    kaya.app_identity("Aurora Notes", icon=icon)

    # ONE PROMOTED COMMAND, AND IT IS NOT ABOUT COMMANDS. Windows mints
    # its custom caption from the first promotion and from nothing else,
    # and a custom caption REPLACES the system one — taking the
    # system-drawn app icon with it. That is why the identity has a
    # second Windows sink at all, and a scene with no promotion anywhere
    # would leave that sink's arm unreached.
    with app.menu("File"):
        kaya.item("Save", symbol=kaya.Symbol.DONE, primary=True)

    heading = kaya.signal("identity")
    status = kaya.signal("ready")
    with kaya.column():
        kaya.label(bind=heading)  # label#0
        kaya.label(bind=status)  # label#1
        kaya.entry(on_change=on_change)  # entry#0
        kaya.button("Go", on_click=on_go)  # button#0

# THE UNTITLED WINDOW. It declares no title at all rather than an empty
# one: an empty string is a title an app WROTE, and the rule under test
# is what a window with nothing written shows.
with app.create_window(UNTITLED, width=360.0, height=240.0):
    caption = kaya.signal("no title of its own")
    with kaya.column():
        kaya.label(bind=caption)  # label#2

sys.exit(app.run())
