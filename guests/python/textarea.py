"""The textarea conformance scene, Python port. See
guests/rust/textarea.rs and tools/scenes/textarea.steps."""

import sys

import kaya

app = kaya.App()


def count(text):
    return "0 lines" if not text else f"{len(text.splitlines())} lines"


def on_edit(text):
    lines.set(count(text))


def on_clear():
    editor.clear()
    editor.focus()


with app.window(title="textarea"):
    lines = kaya.signal("0 lines")
    with kaya.column():
        editor = kaya.textarea(on_change=on_edit)
        kaya.label(bind=lines)
        kaya.button("clear", on_click=on_clear)

sys.exit(app.run())
