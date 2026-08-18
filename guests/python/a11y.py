"""The accessibility conformance scene from Python: the two universal
props (a11y_id, a11y_label) and the verb that reads them back out of
the PLATFORM'S OWN accessibility tree rather than kaya's model.

Every widget kind appears, and exactly one container of each container
kind — the props are universal, and container targets are stable only
while a scene keeps one of each. See guests/rust/a11y.rs for the full
note; the byte-frozen contract is tools/scenes/a11y.steps.

Build the library first (cargo build), then:
    KAYA_SELFTEST=a11y python3 guests/python/a11y.py
"""

import sys

import kaya

app = kaya.App()

# A 2x2 RGB PNG, 75 bytes, embedded as source: scenes carry their inputs
# and do no runtime file I/O.
TEST_PNG = bytes([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68,
                  82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154,
                  115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207,
                  192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11,
                  217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96,
                  130])

with app.window():
    with kaya.column() as form:
        # Caption-bearing controls: identified, deliberately NOT labelled
        # — the platform must speak the caption.
        kaya.button("Save").a11y_id("save").a11y_hint("save the draft")
        kaya.checkbox("Details").a11y_id("details").a11y_hint("show more detail")
        kaya.button("Reset").a11y_id("reset")
        kaya.label(text="Ready").a11y_id("status")
        # Caption-less controls: an app MUST name these, and the tree
        # must report the authored name.
        kaya.entry().a11y_id("name").a11y_label("Full name")
        kaya.textarea().a11y_id("notes").a11y_label("Notes")
        kaya.slider(min=0.0, max=1.0, value=0.5).a11y_id("volume").a11y_label("Volume")
        kaya.progress(value=0.25).a11y_id("loading").a11y_label("Loading")
        kaya.image(TEST_PNG).a11y_id("logo").a11y_label("Logo")
        # The two CHOICE kinds: their options carry captions, the choice
        # itself does not.
        kaya.select(["Red", "Green"]).a11y_id("color").a11y_label("Color")
        kaya.radio(["Small", "Large"]).a11y_id("size").a11y_label("Size")
        # Containers are GROUPS to an assistive client; naming one is how
        # an app declares it a group.
        with kaya.grid(2) as cells:
            kaya.label(text="Name")
            kaya.label(text="Ada")
        cells.a11y_id("cells").a11y_label("Cells")
        with kaya.scroll() as feed:
            kaya.label(text="Item")
        feed.a11y_id("feed").a11y_label("Feed")
        with kaya.row() as actions:
            kaya.button("Cancel").a11y_id("cancel")
            kaya.button("OK").a11y_id("ok")
        actions.a11y_id("actions").a11y_label("Actions")
    form.a11y_id("form").a11y_label("Form")

sys.exit(app.run())
