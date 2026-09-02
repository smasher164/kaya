"""The accessibility conformance scene from Python: the two universal
props (a11y_id, a11y_label), read back out of the PLATFORM'S OWN
accessibility tree rather than kaya's model.

Every widget kind appears, and exactly one container of each container
kind — container targets are ordinal. See guests/rust/a11y.rs; the
byte-frozen contract is tools/scenes/a11y.steps.

Build the library first (cargo build), then:
    KAYA_SELFTEST=a11y python3 guests/python/a11y.py
"""

import sys

import kaya

app = kaya.App()

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
        # THE MARK THE APP'S OWN BUILD SHIPPED: the bytes never enter
        # Python, and the `with` releases the core's handle once the
        # blob table holds its own reference.
        with kaya.asset("images/a11y-logo.png") as logo:
            kaya.image(logo).a11y_id("logo").a11y_label("Logo")
        kaya.select(["Red", "Green"]).a11y_id("color").a11y_label("Color")
        kaya.radio(["Small", "Large"]).a11y_id("size").a11y_label("Size")
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
        # A spoken name that FOLLOWS A SIGNAL: the surface Python always
        # had, uniform across the nine since 2026-09-02.
        spoken = kaya.signal("Before")
        kaya.label(text="Spoken").a11y_id("spoken").a11y_label(spoken)
        kaya.button("Rename", on_click=lambda: spoken.set("After")).a11y_id("rename")
    form.a11y_id("form").a11y_label("Form")

sys.exit(app.run())
