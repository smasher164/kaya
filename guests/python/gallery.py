"""The gallery scene: the conformance pass for the widget vocabulary as
it grows — a row with a checkbox and its status label, and a row with a
slider and its volume label. Both controls own their state and report
each change; the app answers by writing the paired signal — the entry's
uncontrolled contract, with a bool and a float.

The backend selftest (KAYA_SELFTEST=gallery) clicks the checkbox, sets
the slider to 0.75 through the control's own event path, and expects
the labels to read exactly "urgent: true" and "volume: 75%".

Build the library first (cargo build), then:
    KAYA_SELFTEST=gallery python3 crates/kaya/examples/gallery.py
"""

import sys

import kaya

app = kaya.App()

# A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the first
# binary asset, embedded as source per the include_str! doctrine —
# scenes carry their inputs, no runtime file I/O.
TEST_PNG = bytes([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68,
                  82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154,
                  115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207,
                  192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11,
                  217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96,
                  130])


def on_toggle(checked):
    status.set(f"urgent: {'true' if checked else 'false'}")


def on_volume(value):
    # Integer percent, so every language's formatting agrees.
    volume.set(f"volume: {round(value * 100)}%")


with app.window():
    status = kaya.signal("urgent: false")
    volume = kaya.signal("volume: 50%")

    with kaya.column():
        with kaya.row():
            kaya.checkbox("urgent", on_toggle=on_toggle)
            kaya.label(bind=status)
        with kaya.row():
            kaya.slider(value=0.5, min=0.0, max=1.0, on_change=on_volume)
            kaya.label(bind=volume)
        with kaya.row():
            # The content-buffer row: a valid 2x2 PNG decodes and
            # reports its size, and deliberately invalid bytes read 0x0
            # — decode failure is the placeholder class, never a crash,
            # on every backend.
            kaya.image(TEST_PNG)
            kaya.image(b"not an image")

sys.exit(app.run())
