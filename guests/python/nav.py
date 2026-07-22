"""The nav conformance scene, Python port — the north-star spelling
for the serial navigation grammar: each pushed screen is one
`push_entry` scope (nesting inside the click handler's ambient
transaction), the veto class one handler. The covered root is
RETAINED (status keeps taking writes while covered); a programmatic
kaya.pop_entry does not echo entry_popped, so the settings round's
final status stays "back requested". See guests/rust/nav.rs and
tools/scenes/nav.steps."""

import sys

import kaya

app = kaya.App()

DETAIL = 7
SETTINGS = 8


def popped_detail():
    # Bound to the detail entry at push (the on_result precedent):
    # this can only ever mean the detail screen popped.
    with app.build():
        status.set("popped detail")


def back_asked_settings():
    # The veto class: nothing has popped; agree and confirm. No
    # entry_popped will fire — this write is the round's final status.
    with app.build():
        status.set("back requested")
        kaya.pop_entry()


def open_detail():
    # A widget handler runs inside the ambient transaction already;
    # the push scope nests, and the status write rides the same commit.
    with app.push_entry(DETAIL, title="detail", on_popped=popped_detail):
        caption = kaya.signal("detail pane")
        with kaya.column():
            kaya.label(bind=caption)
    status.set("pushed detail")


def open_settings():
    with app.push_entry(SETTINGS, title="settings", intercept_back=True,
                        on_back=back_asked_settings):
        caption = kaya.signal("settings pane")
        with kaya.column():
            kaya.label(bind=caption)
    status.set("pushed settings")


with app.window(title="nav"):
    status = kaya.signal("at root")
    with kaya.column():
        kaya.label(bind=status)  # label#0
        kaya.button("open detail", on_click=open_detail)  # button#0
        kaya.button("open settings", on_click=open_settings)  # button#1


sys.exit(app.run())
