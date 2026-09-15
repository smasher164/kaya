"""The rich label scene (tools/scenes/richlabel.steps; docs/rich-text-plan.md
R8, §15): a label carries the inline vocabulary read-only — the app writes
its document and edits it, and the widget draws the runs over the role's own
font. THE OFFSETS ARE UTF-8 BYTES (docs/ranges-units.md)."""

import sys

import kaya

app = kaya.App()

# BYTE-IDENTICAL to guests/rust/richlabel.rs's DOC.
DOC = "Héllo world, code"


def spell(runs):
    """The core's spelling of runs (`expect_runs`), so the binding's
    document and the core's mirror are compared as one string."""
    return "|".join(
        f"{run.start}:{run.end} {run.name}" if run.value == "true"
        else f"{run.start}:{run.end} {run.name}={run.value}"
        for run in runs)


def on_seed():
    doc = (kaya.Document(DOC)
           .bold(range(0, 6))
           .link(range(7, 12), "https://kaya.dev")
           .mark(range(14, 18), "code", "true"))
    title = kaya.Document("Heading with italic").mark(
        range(13, 19), "italic", "true")
    body.set_document(doc)
    heading.set_document(title)
    runs.set(spell(doc.runs))


def on_insert():
    edit = kaya.Edit.insert(6, ", big").mark(range(2, 5), "italic", "true")
    body.apply_edit(edit)
    runs.set(spell(body.document().runs))


with app.window(title="richlabel"):
    runs = kaya.signal("")
    with kaya.column():
        body_text = kaya.signal("")
        heading_text = kaya.signal("Heading with italic")
        body = kaya.label(bind=body_text, rich=True).a11y_id("body")
        # label#0
        heading = (kaya.label(bind=heading_text, rich=True)
                   .role("heading").a11y_id("heading"))   # label#1
        kaya.label(bind=runs).a11y_id("runs")             # label#2
        with kaya.row():
            kaya.button("seed", on_click=on_seed)         # button#0
            kaya.button("insert", on_click=on_insert)     # button#1

sys.exit(app.run())
