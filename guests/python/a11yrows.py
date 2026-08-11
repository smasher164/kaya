"""The stamped-accessibility scene from Python: two entries stamped
from ONE template, each carrying its OWN ROW's accessibility identity,
read back out of the PLATFORM'S accessibility tree rather than kaya's
model.

The a11y scene proves the wrap-native bet for LIVE widgets; this one
proves it for COPIES — the case none of the accessibility milestone's
719 legs ever exercised, because until the template zone could spell the
props (docs/tpl-props-plan.md P1) no guest could author a stamped
widget's name at all.

A SEPARATE SCENE BY DESIGN, not by size: a For materializes as a column,
harness registries are creation-order, and container creation order
differs by language — so the a11y scene, which asserts every container
kind ordinally, cannot host a For without `column#0` naming different
widgets on different lanes. This scene asserts no container, so the For's
column may land at either end of the registry
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
        # variable itself is what the props bind to and there is no
        # field to project — `note.title` is the record spelling, and
        # this table has no fields to name.
        notes = kaya.collection()
        # The tracing tier: the for statement IS the For — the body runs
        # once, authoring the blueprint; stamping is the core's replay.
        for note in notes:
            # BOTH PROPS ELEMENT-SOURCED. The label is the point on its
            # own — a row that speaks its own name instead of being the
            # second of two identical text fields.
            #
            # THE ID IS FORCED. expect_ax resolves its target to the
            # AUTHORED identifier and then searches the real tree by it,
            # so copies sharing one const id are indistinguishable to
            # that read — which now refuses the ambiguity with the
            # measured count rather than answering with whichever
            # element it found first, as it did when these assertions
            # were first run (the first copy's label came back for the
            # second's index, under a correct-looking sentence). A
            # shared const id stays legal — nothing in the core
            # deduplicates — it is simply not a thing this verb can read
            # back.
            kaya.entry().a11y_id(note).a11y_label(note)
        # The two copies the steps address as entry#0 and entry#last.
        # The keys come from the binding: a note is a string with no
        # identity of its own, and nothing here reads a key back.
        notes.insert_fresh("First note")
        notes.insert_fresh("Second note")

sys.exit(app.run())
