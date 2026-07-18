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

sys.exit(app.run())
