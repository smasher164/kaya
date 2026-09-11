"""The rich text scene (tools/scenes/richtext.steps): the app declares a
document, applies an edit, formats the widget's selection through its own
act, and reads every delta back into its own Document. THE OFFSETS ARE
UTF-8 BYTES; the é in the first word is what makes a UTF-16 reader fail
(docs/ranges-units.md)."""

import sys

import kaya

app = kaya.App()

# BYTE-IDENTICAL to guests/rust/richtext.rs's DOC.
DOC = "Héllo world\nSecond line"


def spell(runs):
    """The core's spelling of runs (`expect_runs`), so the binding's
    document and the core's mirror are compared as one string."""
    return "|".join(
        f"{run.start}:{run.end} {run.name}" if run.value == "true"
        else f"{run.start}:{run.end} {run.name}={run.value}"
        for run in runs)


def on_edit(edit):
    last.set(f"edit {edit.start}:{edit.end} <{edit.inserted}> "
             f"[{spell(edit.runs)}]")
    runs.set(spell(editor.document().runs))


def on_format(act):
    value = "off" if act.value is None else act.value
    last.set(f"format {act.start}:{act.end} {act.name}={value}")
    runs.set(spell(editor.document().runs))


def on_seed():
    doc = (kaya.Document(DOC)
           .bold(range(0, 6))
           .link(range(7, 12), "https://kaya.dev")
           .block(range(13, 24), kaya.Block.HEADING2))
    editor.set_document(doc)
    runs.set(spell(doc.runs))


def on_insert():
    edit = kaya.Edit.insert(6, ", big").mark(range(2, 5), "italic", "true")
    editor.apply_edit(edit)
    runs.set(spell(editor.document().runs))


def on_select_word():
    editor.select_range(range(0, 6))


def on_unbold():
    editor.unformat("bold")


def on_heading():
    editor.set_block(kaya.Block.HEADING1)


def on_focus():
    editor.focus()


def on_prefix():
    editor.apply_edit(kaya.Edit.insert(0, "> "))
    runs.set(spell(editor.document().runs))


with app.window(title="richtext"):
    last = kaya.signal("")
    runs = kaya.signal("")
    with kaya.column():
        editor = kaya.textarea(rich=True, on_edit=on_edit,
                               on_format=on_format)       # textarea#0
        editor.a11y_id("doc").a11y_label("Document")
        kaya.label(bind=last)                             # label#0
        kaya.label(bind=runs)                             # label#1
        with kaya.row():
            kaya.button("seed", on_click=on_seed)                # button#0
            kaya.button("insert", on_click=on_insert)            # button#1
            kaya.button("select word", on_click=on_select_word)  # button#2
            kaya.button("unbold", on_click=on_unbold)            # button#3
            kaya.button("heading", on_click=on_heading)          # button#4
            kaya.button("focus", on_click=on_focus)              # button#5
            kaya.button("prefix", on_click=on_prefix)            # button#6

sys.exit(app.run())
