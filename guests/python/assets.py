"""The assets conformance scene (tools/scenes/assets.steps). THE MISS IS A
QUESTION, NOT A `try`, and LINE 1 ONLY: line 2 differs per host."""

import sys

import kaya

# Absent, and deliberately LEGAL, so the miss is the census sentence.
MISSING = "icons/nope.png"

MARK = "icons/kaya-mark.png"

# 111400 bytes: a reader that truncated into a fixed buffer shows here.
FONT = "fonts/sora-wght.ttf"

app = kaya.App()


def first_line(sentence):
    """The census half. Empty in, empty out."""
    return sentence.split("\n")[0]


with app.window(title="assets", width=480.0, height=360.0):
    with kaya.asset(MARK) as mark, kaya.asset(FONT) as font:
        census = first_line(kaya.asset_miss_sentence(MISSING))

        complaint = kaya.asset_miss_sentence(FONT)
        if complaint:
            # Shows the sentence: a failure must say what was measured.
            verdict = first_line(complaint)
        else:
            verdict = "no complaint"

        with kaya.column():
            kaya.label("assets")  # label#0
            # THE BYTES, not the blob handle.
            kaya.image(mark.bytes())  # image#0
            kaya.label(census)  # label#1
            # An int renders with no separator and no padding, everywhere.
            kaya.label(f"{FONT}: {len(font)} bytes, {verdict}")  # label#2

sys.exit(app.run())
