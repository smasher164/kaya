"""The split conformance scene, Python port — adaptive list-detail as
assertions (DESIGN.md, Adaptive list-detail).

The guest asks for the presentation ONCE — `list_detail=True` on the
window — and does nothing adaptive after that; the platform re-decides
as the size class changes, and there is no prop for WHICH way it
presents. The stack is the ordinary navigation stack: nothing here is
split-specific except that one prop.

TWO scripts drive this ONE app: `split` resizes and names the
presentation on each side, `listdetail` asserts the bare invariant at
whatever width its host gives. See guests/rust/split.rs,
tools/scenes/split.steps and tools/scenes/listdetail.steps.
"""

import sys

import kaya

app = kaya.App()

DETAIL = 7


def popped_detail():
    # Retention: the base root took this write while the detail was up,
    # on a regular window where it was VISIBLE the whole time.
    status.set("popped detail")


def open_detail():
    with app.push_entry(DETAIL, title="detail", on_popped=popped_detail):
        caption = kaya.signal("detail pane")
        with kaya.column():
            kaya.label(bind=caption).a11y_id("detail")


with app.window(title="split", list_detail=True):
    status = kaya.signal("list pane")
    with kaya.column():
        # Authored ids so the REAL-TREE read can address these:
        # `expect label#N` reads kaya's own model and passes whether or
        # not anything reached the screen — the gap that let a
        # non-rendering split arm look green.
        kaya.label(bind=status).a11y_id("list")  # label#0
        kaya.button("open detail", on_click=open_detail)  # button#0


sys.exit(app.run())
