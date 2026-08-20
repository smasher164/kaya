"""The panes conformance scene, Python port — a THREE-pane ceiling as
assertions (docs/multicolumn-plan.md D1/D5).

Nothing here is panes-specific except `panes=3`, asked for ONCE — the
stack is the ordinary navigation stack, and how many of the three fit is
the platform's re-decision at every width. See guests/rust/panes.rs and
tools/scenes/panes.steps.
"""

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
        # Authored ids so the REAL-TREE read can address these:
        # `expect_ax label#N` reads the platform's own tree, where the
        # model reads above pass for an arm that ran and drew nothing.
        kaya.label(bind=caption).a11y_id("root")  # label#0
        kaya.button("open content", on_click=open_content)  # button#0


sys.exit(app.run())
