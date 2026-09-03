"""The panes scene (tools/scenes/panes.steps): nothing here is
panes-specific except `panes=3`, asked for ONCE."""

import sys

import kaya

app = kaya.App()

CONTENT = 7
DETAIL = 8


def open_detail():
    with app.push_entry(DETAIL, title="detail"):
        caption = kaya.signal("detail pane")
        with kaya.column():
            kaya.label(bind=caption).a11y_id("detail")  # label#last


def open_content():
    with app.push_entry(CONTENT, title="content"):
        caption = kaya.signal("content pane")
        with kaya.column():
            kaya.label(bind=caption).a11y_id("content")  # label#1
            kaya.button("open detail", on_click=open_detail)  # button#1


with app.window(title="panes", panes=3):
    caption = kaya.signal("root pane")
    with kaya.column():
        # Authored ids: an index read passes for an empty arm.
        kaya.label(bind=caption).a11y_id("root")  # label#0
        kaya.button("open content", on_click=open_content)  # button#0


sys.exit(app.run())
