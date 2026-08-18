"""The stamped-accessibility scene from Python: two entries stamped
from ONE template, each carrying its OWN ROW's accessibility identity,
read back out of the PLATFORM'S accessibility tree rather than kaya's
model.

The a11y scene proves the wrap-native bet for LIVE widgets; this one
proves it for COPIES (docs/tpl-props-plan.md P1).

A SEPARATE SCENE BY DESIGN: a For materializes as a column, harness
registries are creation-order, and container creation order differs by
language — so the a11y scene, which asserts every container kind
ordinally, cannot host a For. This scene asserts no container, so the
For's column may land at either end of the registry
(guests/haskell/reorder.hs documents the ordering rule).

Canonical note in guests/rust/a11yrows.rs; the byte-frozen contract is
tools/scenes/a11yrows.steps.

Build the library first (cargo build), then:
    KAYA_SELFTEST=a11yrows python3 guests/python/a11yrows.py
"""

import sys

import kaya

app = kaya.App()

with app.window():
    with kaya.column():
        # A SCALAR collection: an entry's value IS the note, so the loop
        # variable itself is what the props bind to.
        notes = kaya.collection()
        for note in notes:
            # THE ID MUST BE ELEMENT-SOURCED. expect_ax searches the real
            # tree by the AUTHORED identifier and refuses an ambiguous
            # one (docs/deferred.md), so copies cannot share a const id.
            kaya.entry().a11y_id(note).a11y_label(note)
        # The two copies the steps address as entry#0 and entry#last.
        notes.insert_fresh("First note")
        notes.insert_fresh("Second note")

        # THE STAMPED STYLING PROPS. A second collection because a scalar
        # row has one field to spend on an id, and expect_ax needs an
        # unambiguous one.
        #
        # BOTH PROPS ARE CONST, here and in every binding: what a copy
        # MEANS, and how far its prototype insets its children, are facts
        # about the PROTOTYPE and not the row (`accepts`'s rule).
        heads = kaya.collection()
        for head in heads:
            with kaya.row(inset=8):
                kaya.label(bind=head).role(kaya.Role.HEADING).a11y_id(head)
        heads.insert_fresh("Heading one")
        heads.insert_fresh("Heading two")

sys.exit(app.run())
