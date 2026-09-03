#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# A handler is already a transaction and a guest must never open one
# itself (CLAUDE.md's gate list). PYTHON AND JS ONLY: the handle
# bindings pass the transaction in, Haskell opens one by idiom, and
# OCaml has no reliable textual discriminator (`build app` is itself
# indented and appears twice at two depths in menus.ml, both
# legitimate), so its guard would be behavioural rather than a grep.

import re


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
