"""The colour picker scene (tools/scenes/colorpicker.steps;
docs/color-picker-plan.md §5)."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Swatch:
    name: str
    fill: kaya.Color


app = kaya.App()


def on_title(picked):
    title_text.set(f"color: {picked}")


def on_glaze(picked):
    glaze_text.set(f"alpha: {picked}")


def on_row_fill(swatch, picked):
    row_text.set(f"row {swatch.key}: {picked}")


def on_reset():
    # Must NOT come back as a title occurrence.
    title_value.set(kaya.Color.from_hex(0x3584E4FF))


with app.window():
    title_text = kaya.signal("color: none")
    glaze_text = kaya.signal("alpha: none")
    row_text = kaya.signal("row: none")
    title_value = kaya.signal(kaya.Color.from_hex(0x336699FF))
    swatches = kaya.collection(Swatch)
    with kaya.column():
        kaya.label(bind=title_text)
        kaya.label(bind=glaze_text)
        kaya.label(bind=row_text)
        kaya.color_picker(title_value, on_color=on_title) \
            .a11y_label("Title colour").a11y_id("title")
        kaya.color_picker(kaya.Color.from_hex(0x26A269FF), alpha=True,
                          on_color=on_glaze).a11y_label("Glaze")
        kaya.button("reset", on_click=on_reset)
        for swatch in swatches:
            kaya.label(bind=swatch.name)
            kaya.color_picker(swatch.fill,
                              on_color=on_row_fill).a11y_id("fill")
    swatches.insert("a", Swatch(name="a", fill=kaya.Color.from_hex(0xE66100FF)))
    swatches.insert("b", Swatch(name="b", fill=kaya.Color.from_hex(0xF6D32DFF)))

sys.exit(app.run())
