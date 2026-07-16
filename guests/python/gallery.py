"""The gallery scene: the conformance pass for the widget vocabulary as
it grows — today a row container laying a checkbox and the status label
side by side. The box owns its checked bit and reports each flip
through on_toggle; the app answers by writing the status signal — the
same uncontrolled contract as the entry, with a bool.

The backend selftest (KAYA_SELFTEST=gallery) clicks the checkbox and
expects the status label to read exactly "urgent: true".

Build the library first (cargo build), then:
    KAYA_SELFTEST=gallery python3 crates/kaya/examples/gallery.py
"""

import pathlib
import sys

_here = pathlib.Path(__file__).resolve().parent
for _base in [_here, *_here.parents]:
    if (_base / "bindings" / "python").is_dir():
        sys.path.insert(0, str(_base / "bindings" / "python"))
        break

import kaya_app as kaya

app = kaya.App()


def on_toggle(checked):
    status.set(f"urgent: {'true' if checked else 'false'}")


with app.window():
    status = kaya.signal("urgent: false")

    with kaya.column():
        with kaya.row():
            kaya.checkbox("urgent", on_toggle=on_toggle)
            kaya.label(bind=status)

sys.exit(app.run())
