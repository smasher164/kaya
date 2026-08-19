"""The toolbar conformance scene, Python port: the `primary` bit as real
window chrome (docs/chrome-plan.md C2). The app declares ONE catalog and
marks two actions primary; every host promotes the same first two in
catalog preorder, and the rest of the catalog stays reachable where that
host keeps it. There is no toolbar vocabulary to spell.

Canonical semantics in guests/rust/toolbar.rs; the byte-frozen contract
in tools/scenes/toolbar.steps.
"""

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
    # The app writes this against the MENU ITEM and says nothing about
    # any button: the promoted button IS that item, so it follows or the
    # lowering kept a copy.
    can_save = kaya.signal(True)

    # CATALOG PREORDER DECIDES PROMOTION — top-level groupings in
    # menubar-append order, then each node's children in append order,
    # depth-first. Save is the first primary and Find the second, so
    # every host's promoted set is [Save, Find] whatever its own k is.
    with app.menu("File"):
        # The vocabulary has no save-specific glyph, so `done` — the
        # checkmark idiom — is the spelling (docs/styling-plan.md D6).
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
