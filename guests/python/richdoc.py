"""The rich document scene (tools/scenes/richdoc.steps,
docs/rich-document-plan.md §9 step 2): a heading, a body paragraph with a
preset colour, a bullet list with a nested item, a numbered list and a
checklist, then the paragraph acts from buttons, the platform's colour
picker and a `.kdoc` round trip, then a file carrying keys this kaya does
not know (RD17). label#1 is the binding's own Document, folded from the
same deltas, so it must spell what the core holds."""

import sys

import kaya

app = kaya.App()

# BYTE-IDENTICAL to guests/rust/richdoc.rs's DOC.
DOC = ("Groceries\nFresh from the market.\nApples\nGreen ones\nBread\n"
       "Wash\nSlice\nMilk\nEggs")

# BYTE-IDENTICAL to guests/rust/richdoc.rs's UNKNOWN.
UNKNOWN = ('{"kaya": "document", "version": 1, "com.example.theme": '
           '{"page": "sepia"}, "paragraphs": [{"embed": "e1", "spans": '
           '[["Loose"]]}, {"com.example.pinned": true, "spans": '
           '[["Pinned"]]}]}')


def spell(runs):
    return "|".join(
        f"{run.range.start}:{run.range.stop} {run.name}" if run.is_flag
        else f"{run.range.start}:{run.range.stop} {run.name}={run.value}"
        for run in runs)


SEEDED = (kaya.Document(DOC)
          .block(range(0, 9), kaya.Block.HEADING1)
          .color(range(25, 31), "#016FEF")
          .list(range(33, 56), kaya.ListKind.BULLET)
          .indent(range(40, 50), 1)
          .list(range(57, 67), kaya.ListKind.NUMBERED)
          .checked(range(68, 72))
          .list(range(68, 77), kaya.ListKind.CHECK))


def on_edit(edit):
    inserted = edit.inserted.replace("\n", "\\n")
    source = "?" if edit.source is None else edit.source
    last.set(f"edit {edit.range.start}:{edit.range.stop} <{inserted}> "
             f"{source} [{spell(edit.runs)}]")
    runs.set(spell(editor.document().runs))


def on_format(act):
    value = "off" if act.value is None else act.value
    last.set(f"format {act.range.start}:{act.range.stop} {act.name}={value}")
    runs.set(spell(editor.document().runs))


def on_numbered():
    editor.set_list(kaya.ListKind.NUMBERED)


def on_indent():
    editor.indent()


def on_red():
    editor.color("#DD1F24")


def on_colour():
    editor.pick_text_color()


def on_kdoc():
    now = editor.document()
    data = now.to_kdoc()
    back = kaya.Document.from_kdoc(data)
    read_only = "none" if back.read_only is None else back.read_only
    same = "true" if back.document == now else "false"
    extra = back.document.extra.replace('"', "'") or "none"
    editor.set_document(back.document)
    kdoc.set(f"kdoc {len(data)} bytes, read_only {read_only}, same {same}, "
             f"extra {extra}")
    runs.set(spell(back.document.runs))


def on_unknown():
    file = kaya.Document.from_kdoc(UNKNOWN.encode("utf-8"))
    read_only = "none" if file.read_only is None else file.read_only
    extra = file.document.extra.replace('"', "'")
    editor.set_document(file.document)
    kdoc.set(f"opened read_only {read_only}, extra {extra}")
    runs.set(spell(file.document.runs))


with app.window(title="richdoc", width=560.0, height=620.0):
    with app.menu("Edit"):
        kaya.item("Cut", role=kaya.MenuRole.CUT)
        kaya.item("Copy", role=kaya.MenuRole.COPY)
        kaya.item("Paste", role=kaya.MenuRole.PASTE)

    last = kaya.signal("")
    runs = kaya.signal(spell(SEEDED.runs))
    kdoc = kaya.signal("")
    with kaya.column():
        editor = kaya.textarea(rich=True, grow=1.0, on_edit=on_edit,
                               on_format=on_format)        # textarea#0
        editor.a11y_id("doc").a11y_label("Document")
        editor.set_document(SEEDED)
        kaya.label(bind=last)                              # label#0
        kaya.label(bind=runs)                              # label#1
        kaya.label(bind=kdoc)                              # label#2
        with kaya.row():
            kaya.button("numbered", on_click=on_numbered)  # button#0
            kaya.button("indent", on_click=on_indent)      # button#1
            kaya.button("red", on_click=on_red)            # button#2
            kaya.button("colour", on_click=on_colour)      # button#3
            kaya.button("kdoc", on_click=on_kdoc)          # button#4
            kaya.button("keys", on_click=on_unknown)    # button#5

sys.exit(app.run())
