"""The split conformance scene, Python port — adaptive list-detail as
assertions (DESIGN.md, Adaptive list-detail).

The guest asks for the presentation ONCE — `list_detail=True` on the
window — and then does nothing adaptive ever again. Everything after
that is the platform re-deciding as the window's size class changes,
which is the property being gated: an app does not write two layouts
and pick one, and there is no prop for WHICH way it presents.

The stack is the ordinary navigation stack. `push_entry` puts the
detail on it exactly as the nav scene does, and back pops it the same
way; on a regular window that entry renders BESIDE the base root
instead of covering it. Nothing here is split-specific except the one
prop, which is the whole demonstration.

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
    with app.build():
        status.set("popped detail")


def open_detail():
    # The popped handler rides the push, per-entry — the on_result
    # precedent, unchanged by the split.
    with app.push_entry(DETAIL, title="detail", on_popped=popped_detail):
        caption = kaya.signal("detail pane")
        with kaya.column():
            kaya.label(bind=caption).a11y_id("detail")


with app.window(title="split", list_detail=True):
    status = kaya.signal("list pane")
    with kaya.column():
        # Authored ids so the REAL-TREE read can address these:
        # `expect label#N` reads kaya's own model and passes whether or
        # not anything reached the screen, which is exactly the gap that
        # let a non-rendering split arm look green.
        kaya.label(bind=status).a11y_id("list")  # label#0
        kaya.button("open detail", on_click=open_detail)  # button#0


sys.exit(app.run())
