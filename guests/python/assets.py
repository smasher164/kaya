"""The assets conformance scene, Python port (docs/assets-plan.md,
ratified 2026-08-18). The byte-frozen contract is
tools/scenes/assets.steps.

THIS ONE PROVES THE BYTES. `asset(name)` has two redemptions and the
typeface scene already covers the other: a font whose bytes go from the
core's read straight to the platform and never touch Python. Here the
guest IS the consumer — it copies the mark out with `bytes()` and hands
them to an Image, and the platform's own decoder answers 64x64 off the
real view.

THE MISS IS A QUESTION, NOT A `try`. `asset_miss_sentence` answers the
same sentence a miss would raise, without raising, and that is the only
shape nine languages share: Swift's raise is `fatalError`, which traps
rather than unwinding, so a Swift sibling could not catch its own miss.

LINE 1 ONLY. The sentence's second line names the place the core
resolved and the route that chose it, which a bundle, a device
directory and a repo checkout spell three different ways; the first
line is the same everywhere, so it is the one a scene can freeze.
"""

import sys

import kaya

# The asset that is deliberately not there. A LEGAL name — relative,
# `/`-spelled, one component deep — so what comes back is the census
# sentence and not a name-fault one.
MISSING = "icons/nope.png"

# The one the mark is under, and the one the census must list.
MARK = "icons/kaya-mark.png"

# The large asset: 111400 bytes, so a reader that truncated into a fixed
# buffer shows up here rather than passing quietly.
FONT = "fonts/sora-wght.ttf"

app = kaya.App()


def first_line(sentence):
    """The census half. Empty in, empty out."""
    return sentence.split("\n")[0]


with app.window(title="assets", width=480.0, height=360.0):
    # Both handles live for the whole build and the `with` releases them
    # on the way out, exactly as the typeface scene releases its font.
    with kaya.asset(MARK) as mark, kaya.asset(FONT) as font:
        census = first_line(kaya.asset_miss_sentence(MISSING))

        complaint = kaya.asset_miss_sentence(FONT)
        if complaint:
            # Never reached on a healthy lane, and it shows the sentence
            # rather than a word about it: a failure here has to say
            # what was measured.
            verdict = first_line(complaint)
        else:
            verdict = "no complaint"

        with kaya.column():
            kaya.label("assets")  # label#0
            # THE BYTES, not the blob handle: this scene is the
            # consumer, so what reaches the decoder is what `bytes()`
            # handed back.
            kaya.image(mark.bytes())  # image#0
            kaya.label(census)  # label#1
            # `len(font)` is the core's byte count, and Python renders an
            # int with no separator and no padding anywhere.
            kaya.label(f"{FONT}: {len(font)} bytes, {verdict}")  # label#2

# Nothing to drive: every observation is a read of the first mount.
sys.exit(app.run())
