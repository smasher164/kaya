#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# A HANDLER IS A TRANSACTION — and a guest must never open one itself
# (CLAUDE.md's gate list for the Python defect it exists for). The gate
# does not test the binding; it removes the guests' ability to hide a
# regression, so the existing scenes become the test.
#
# PYTHON AND JS. The handle bindings pass the transaction in, so a missing
# one is not expressible. Haskell opens one in every handler by idiom.
# OCaml is ambient too but has no reliable textual discriminator (its
# `build app` is itself indented, and appears twice at two depths in
# menus.ml, both legitimate); its guard would be a behavioural check in
# the check-abort family, not a grep.

import re

# INDENTATION IS THE DISCRIMINATOR: at module scope `with app.build():`
# is the blessed spelling for mutations OUTSIDE any handler; indented,
# it is inside a def, which is inside a handler.


def lint(path, text):
    """Offender lines, `path:lineno:stripped-line` — empty means clean.
    Python's `with app.build():` and JS's `app.build(() =>` share the
    discriminator: indented, the call sits inside a handler."""
    bad = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if re.match(r"\s+with\s+app\.build\(\)\s*:", line) or \
                re.match(r"\s+app\.build\(\s*\(\)\s*=>", line):
            bad.append(f"{path}:{lineno}:{line.strip()}")
    return bad


# Self-test, both directions: handler-scoped caught, module-scope not.
if not lint("-", 'def popped():\n    with app.build():\n        s.set("x")\n'):
    print("check-ambient-tx: SELF-TEST FAIL (handler-scoped build passed)",
          file=sys.stderr)
    sys.exit(1)
if lint("-", 'with app.build():\n    groups.insert("g2", "Home")\n'):
    print("check-ambient-tx: SELF-TEST FAIL (module-scope build rejected)",
          file=sys.stderr)
    sys.exit(1)
if not lint("-", 'function popped() {\n  app.build(() => {\n    s.set("x");\n  });\n}\n'):
    print("check-ambient-tx: SELF-TEST FAIL (js handler-scoped build passed)",
          file=sys.stderr)
    sys.exit(1)
if lint("-", 'app.build(() => {\n  groups.insert("g2", "Home");\n});\n'):
    print("check-ambient-tx: SELF-TEST FAIL (js module-scope build rejected)",
          file=sys.stderr)
    sys.exit(1)

status = 0
guests = sorted((ROOT / "guests/python").glob("*.py"))
js_guests = sorted((ROOT / "guests/js").glob("*.ts"))
if len(js_guests) < 20:
    print(f"check-ambient-tx: only {len(js_guests)} js guests reached the "
          f"census (floor 20) — a census that reads nothing agrees with "
          f"everything", file=sys.stderr)
    sys.exit(1)
print(f"check-ambient-tx: {len(js_guests)} js guests in the census "
      f"(floor 20)", file=sys.stderr)
guests = guests + js_guests
# 45 python guests at the time of writing; a moved or renamed
# directory used to turn the shell's incidental red into a loop that
# reads nothing and agrees with everything (audit 2026-08-31).
if len(guests) < 20:
    print(f"check-ambient-tx: only {len(guests)} python guests reached "
          f"the census (floor 20) — a census that reads nothing agrees "
          f"with everything", file=sys.stderr)
    sys.exit(1)
print(f"check-ambient-tx: {len(guests)} python guests in the census "
      f"(floor 20)", file=sys.stderr)
for f in guests:
    rel = f.relative_to(ROOT)
    bad = lint(str(rel), f.read_text(encoding="utf-8"))
    if bad:
        print(f"check-ambient-tx: {rel} opens a transaction INSIDE a handler.",
              file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        status = 1

if status != 0:
    print("check-ambient-tx: a handler ALREADY runs in a transaction — the "
          "binding opens it (App._dispatch, both bindings). Opening another "
          "nests and raises. If it seemed necessary, the binding regressed: fix "
          "_dispatch, do not work around it here — that is exactly how the "
          "original defect stayed green for months.", file=sys.stderr)
    sys.exit(1)
print("check-ambient-tx: OK")
