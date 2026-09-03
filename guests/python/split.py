"""The split scene, driven by TWO scripts (tools/scenes/split.steps and
listdetail.steps): the presentation is asked for ONCE and never again."""

import sys

import kaya

app = kaya.App()

DETAIL = 7


def popped_detail():
    # Retention: the base root took this write while the detail was up.
    status.set("popped detail")


def open_detail():
    with app.push_entry(DETAIL, title="detail", on_popped=popped_detail):
        caption = kaya.signal("detail pane")
        with kaya.column():
            kaya.label(bind=caption).a11y_id("detail")


with app.window(title="split", panes=2):
    status = kaya.signal("list pane")
    with kaya.column():
        # Authored ids: an index read passes for an empty arm.
        kaya.label(bind=status).a11y_id("list")  # label#0
        kaya.button("open detail", on_click=open_detail)  # button#0


sys.exit(app.run())
