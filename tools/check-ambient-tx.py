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
# PYTHON ONLY. The handle bindings pass the transaction in, so a missing
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
    """Offender lines, `path:lineno:stripped-line` — empty means clean."""
    bad = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if re.match(r"\s+with\s+app\.build\(\)\s*:", line):
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

status = 0
for f in sorted((ROOT / "guests/python").glob("*.py")):
    rel = f.relative_to(ROOT)
    bad = lint(str(rel), f.read_text(encoding="utf-8"))
    if bad:
        print(f"check-ambient-tx: {rel} opens a transaction INSIDE a handler.",
              file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        status = 1

if status != 0:
    print("check-ambient-tx: a handler ALREADY runs in a transaction — the "
          "binding opens it (App._dispatch). Opening another nests and "
          "raises. If it seemed necessary, the binding regressed: fix "
          "_dispatch, do not work around it here — that is exactly how the "
          "original defect stayed green for months.", file=sys.stderr)
    sys.exit(1)
print("check-ambient-tx: OK")
