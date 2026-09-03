"""The stamped-a11y scene (tools/scenes/a11yrows.steps). It asserts NO
container: a For materializes one, and their registries are ordinal."""

import sys

import kaya

app = kaya.App()

with app.window():
    with kaya.column():
        # A SCALAR collection: the loop variable IS the element.
        notes = kaya.collection()
        for note in notes:
            # expect_ax REFUSES copies that share one const id.
            kaya.entry().a11y_id(note).a11y_label(note)
        notes.insert_fresh("First note")
        notes.insert_fresh("Second note")

        # A SECOND collection: a scalar row has one field for an id, and
        # both props below are CONST in every binding.
        heads = kaya.collection()
        for head in heads:
            with kaya.row(inset=8):
                kaya.label(bind=head).role(kaya.Role.HEADING).a11y_id(head)
        heads.insert_fresh("Heading one")
        heads.insert_fresh("Heading two")

sys.exit(app.run())
