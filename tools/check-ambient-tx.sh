#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
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
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# INDENTATION IS THE DISCRIMINATOR: at module scope `with app.build():`
# is the blessed spelling for mutations OUTSIDE any handler; indented,
# it is inside a def, which is inside a handler.
lint() {
    # $1: a python guest (or - for stdin). Prints offenders, returns 1 on any.
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []
for lineno, line in enumerate(text.splitlines(), 1):
    if re.match(r"\s+with\s+app\.build\(\)\s*:", line):
        bad.append(f"{path}:{lineno}:{line.strip()}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# Self-test, both directions: handler-scoped caught, module-scope not.
if printf 'def popped():\n    with app.build():\n        s.set("x")\n' \
    | lint - >/dev/null; then
    echo "check-ambient-tx: SELF-TEST FAIL (handler-scoped build passed)" >&2
    exit 1
fi
if ! printf 'with app.build():\n    groups.insert("g2", "Home")\n' \
    | lint - >/dev/null; then
    echo "check-ambient-tx: SELF-TEST FAIL (module-scope build rejected)" >&2
    exit 1
fi

status=0
for f in guests/python/*.py; do
    out="$(lint "$f")" || {
        echo "check-ambient-tx: $f opens a transaction INSIDE a handler." >&2
        echo "$out" >&2
        status=1
    }
done

if [ "$status" != 0 ]; then
    echo "check-ambient-tx: a handler ALREADY runs in a transaction — the" \
        "binding opens it (App._dispatch). Opening another nests and" \
        "raises. If it seemed necessary, the binding regressed: fix" \
        "_dispatch, do not work around it here — that is exactly how the" \
        "original defect stayed green for months." >&2
    exit 1
fi
echo "check-ambient-tx: OK"
