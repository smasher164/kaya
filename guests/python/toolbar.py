"""The toolbar scene (tools/scenes/toolbar.steps): the `primary` bit as
window chrome, with no toolbar vocabulary to spell."""

import sys

import kaya

app = kaya.App()

save_enabled = True


def on_toggle_save():
    global save_enabled
    save_enabled = not save_enabled
    can_save.set(save_enabled)


def on_save():
    status.set("saved")


def on_find():
    status.set("found")


def on_export():
    status.set("exported")


with app.window(title="toolbar"):
    status = kaya.signal("ready")
    # Written against the MENU ITEM: the promoted button IS that item.
    can_save = kaya.signal(True)

    # CATALOG PREORDER DECIDES PROMOTION.
    with app.menu("File"):
        # The vocabulary has no save glyph, so `done` is the spelling.
        kaya.item("Save", symbol=kaya.Symbol.DONE, primary=True,
                  enabled=can_save, shortcut="primary+s", on_activate=on_save)
        kaya.item("Export", symbol=kaya.Symbol.FORWARD, on_activate=on_export)

    with app.menu("Edit"):
        kaya.item("Find", symbol=kaya.Symbol.SEARCH, primary=True,
                  on_activate=on_find)
        kaya.item("Replace", symbol=kaya.Symbol.EDIT)

    with app.menu("View"):
        kaya.item("Refresh", symbol=kaya.Symbol.REFRESH)
        kaya.item("Info", symbol=kaya.Symbol.INFO)

    with kaya.column():
        kaya.label(bind=status)  # label#0
        kaya.button("toggle save", on_click=on_toggle_save)  # button#0

sys.exit(app.run())
