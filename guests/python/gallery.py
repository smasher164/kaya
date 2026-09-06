"""The gallery scene, a bool and a float (tools/scenes/gallery.steps).

    KAYA_SELFTEST=gallery python3 guests/python/gallery.py
"""

import sys

import kaya

app = kaya.App()

# A 2x2 RGB PNG, 75 bytes, embedded as source.
TEST_PNG = bytes([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68,
                  82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154,
                  115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207,
                  192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11,
                  217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96,
                  130])


def on_toggle(checked):
    status.set(f"urgent: {'true' if checked else 'false'}")


def on_volume(value):
    # Integer percent, so every language's formatting agrees byte for byte.
    volume.set(f"volume: {round(value * 100)}%")


def on_quarter():
    # A programmatic write must NOT echo an on_volume occurrence.
    pos.set(0.25)


with app.window():
    status = kaya.signal("urgent: false")
    volume = kaya.signal("volume: 50%")
    pos = kaya.signal(0.5)

    with kaya.column():
        with kaya.row():
            kaya.checkbox("urgent", on_toggle=on_toggle)
            kaya.label(bind=status)
        with kaya.row():
            kaya.slider(value=pos, min=0.0, max=1.0, on_change=on_volume)
            kaya.label(bind=volume)
            kaya.button("quarter", on_click=on_quarter)
        with kaya.row():
            # A decode failure is the placeholder class, never a crash.
            kaya.image(TEST_PNG)
            kaya.image(b"not an image")
        # The labelled row: the control's accessibility name IS the
        # label's text, with no a11y_label of its own.
        with kaya.labeled("Level"):
            kaya.slider(value=0.5, min=0.0, max=1.0).a11y_id("level")

sys.exit(app.run())
