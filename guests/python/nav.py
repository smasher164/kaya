"""The nav conformance scene (tools/scenes/nav.steps): a programmatic
pop_entry does NOT echo entry_popped."""

import sys

import kaya

app = kaya.App()

DETAIL = 7
SETTINGS = 8


def popped_detail():
    status.set("popped detail")


def back_asked_settings():
    # Nothing has popped, and no entry_popped will follow.
    status.set("back requested")
    kaya.pop_entry()


def open_detail():
    # The push NESTS in the handler's transaction: one commit.
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
