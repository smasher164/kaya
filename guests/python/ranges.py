"""The text-ranges scene (tools/scenes/ranges.steps). THE OFFSETS ARE UTF-8
BYTE OFFSETS, which is why the search runs over `doc.encode()`."""

import sys

import kaya

app = kaya.App()

# BYTE-IDENTICAL to guests/rust/ranges.rs's DOC: the frozen offsets are of
# THESE bytes, and the last match must sit below the viewport.
DOC = """line 00: 日本語 preface
line 01: gamma kappa
line 02: alpha beta gamma
line 03: epsilon theta
line 04: zeta nu
line 05: eta zeta
line 06: theta lambda
line 07: iota delta
line 08: kappa iota
line 09: alpha eta theta
line 10: mu eta
line 11: nu mu
line 12: beta epsilon
line 13: gamma kappa
line 14: delta gamma
line 15: epsilon theta
line 16: zeta nu
line 17: eta zeta
line 18: theta lambda
line 19: iota delta
line 20: kappa iota
line 21: lambda beta
line 22: mu eta
line 23: nu mu
line 24: beta epsilon
line 25: gamma kappa
line 26: delta gamma
line 27: epsilon theta
line 28: zeta nu
line 29: eta zeta
line 30: theta lambda
line 31: iota delta
line 32: kappa iota
line 33: lambda beta
line 34: mu eta
line 35: nu mu
line 36: beta epsilon
line 37: alpha iota kappa
line 38: delta gamma
line 39: the last line"""

NEEDLE = "alpha"

# The ONLY authority on what the offsets mean; it advances on every edit.
doc = DOC


def find_all(text, needle):
    """The whole search: literal, forward, non-overlapping, over the
    UTF-8 BYTES, so what it yields is already kaya's unit."""
    data, hit = text.encode(), needle.encode()
    hits, at = [], data.find(hit)
    while at >= 0:
        hits.append(range(at, at + len(hit)))
        at = data.find(hit, at + len(hit))
    return hits


def on_edit(text):
    # kaya has ALREADY dropped the decorations on this edit.
    global doc
    doc = text
    status.set("0 matches")


def on_find():
    hits = find_all(doc, NEEDLE)
    editor.highlight_ranges(hits)
    # The SECOND match, so a leg can tell it from the first.
    if len(hits) > 1:
        editor.select_range(hits[1])
    status.set(f"{len(hits)} matches")


def on_reveal_last():
    hits = find_all(doc, NEEDLE)
    if hits:
        editor.reveal_range(hits[-1])


def on_focus_editor():
    editor.focus()


def on_select_first():
    hits = find_all(doc, NEEDLE)
    if hits:
        editor.select_range(hits[0])


with app.window(title="ranges"):
    status = kaya.signal("0 matches")
    with kaya.column():
        # Every range assertion finds this control by its authored id.
        editor = kaya.textarea(on_change=on_edit)          # textarea#0
        editor.a11y_id("doc").a11y_label("Document").set_text(DOC)
        kaya.label(bind=status)                            # label#0
        with kaya.row():
            kaya.button("find", on_click=on_find)                  # button#0
            kaya.button("reveal last", on_click=on_reveal_last)    # button#1
            kaya.button("focus editor", on_click=on_focus_editor)  # button#2
            kaya.button("select first", on_click=on_select_first)  # button#3

sys.exit(app.run())
