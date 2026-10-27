"""The code surface scene (tools/scenes/codesurface.steps,
docs/code-surface-plan.md): a textarea that numbers its lines, the
platform's monospaced face, a family the app picks from the platform's
list, a family the platform lacks, and a label at twice the platform's size."""

import sys

import kaya

# Forty lines; the third wraps at every lane's width.
DOC = "\n".join(
    ["// codesurface",
     "fn main() {",
     '    let note = "this line is long on purpose, so that the textarea wraps it onto a second row '
     'and the gutter has a continuation to leave unnumbered, the way every editor does";']
    + [f"    let value_{i:02} = {i} * 2;" for i in range(4, 40)]
    + ["}"])
END = len(DOC.encode())

app = kaya.App()


def on_end():
    code.focus()
    code.select_range(range(END, END))
    code.reveal_range(range(END, END))


def on_families(families):
    ordered = all(a < b for a, b in zip(families, families[1:]))
    if not families:
        listed.set("families: none")
    elif ordered:
        listed.set("families: listed, unique, in order")
    else:
        listed.set("families: out of order")
    if families:
        picked.family(families[0])


kaya.on_font_families(on_families)

with app.window(title="codesurface"):
    listed = kaya.signal("families: -")
    with kaya.column():
        code = kaya.textarea().line_numbers().monospaced().a11y_id("code")
        code.set_text(DOC)
        kaya.textarea().a11y_id("plain").set_text("plain text\nin the app's face")
        kaya.label("let x = 1;").monospaced().a11y_id("mono")
        kaya.entry().monospaced().a11y_id("mono_entry").set_text("let y = 2;")
        kaya.label("missing").family("Kaya No Such Family").monospaced().a11y_id("missing")
        kaya.label("Big").text_scale(2).a11y_id("big")
        kaya.label("Plain").a11y_id("plain_label")
        kaya.label(bind=listed).a11y_id("families")
        picked = kaya.label("picked").a11y_id("picked")
        with kaya.row():
            kaya.button("end", on_click=on_end).a11y_id("end")
            kaya.button("fonts", on_click=kaya.list_font_families).a11y_id("fonts")

sys.exit(app.run())
