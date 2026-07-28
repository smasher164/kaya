#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# A HANDLER IS A TRANSACTION — and a guest must never open one itself.
#
# THE DEFECT THIS EXISTS FOR (found 2026-07-27, by a documentation
# audit rather than by any gate). Python's dispatch loop wrapped widget
# and menu handlers in an ambient transaction but called the six
# LIFECYCLE handlers bare — close_requested, window_closed,
# entry_popped, section_selected, back_requested, alert_result. So
# `kaya.destroy_window()` inside an on_close_requested raised "no
# ambient transaction", and DESIGN's ratified rule ("a handler is a
# transaction ... atomic without any effort from the author") was false
# in Python alone.
#
# WHY NO GATE SAW IT, which is the part worth keeping: the scenes
# PASSED. Five guests each opened a transaction by hand —
# `with app.build():` at the top of the handler — so the lane was green
# while the binding was wrong. The workaround WAS the camouflage.
#
# So this gate does not test the binding. It removes the ability to
# HIDE a regression: with no guest able to compensate, the existing
# scenes become the test, and a binding that stops supplying the
# transaction fails them loudly on every lane.
#
# WHY PYTHON ONLY. The defect needs an AMBIENT transaction — one the
# handler cannot see. Go, Java, Swift and C# hand the handler its
# transaction as a parameter (`tx2 -> tx2.write(...)`), so a missing one
# is not expressible. Haskell opens one explicitly in EVERY handler,
# widget and lifecycle alike; that is the config-list idiom, uniform,
# and not a workaround. OCaml is ambient like Python and was already
# correct — but it has no reliable textual discriminator (its
# scene-declaring `build app` is itself indented, inside `let () =`, and
# in menus.ml appears twice at two different depths, both legitimate).
# A rule that misfires gets disabled, which is worse than a narrower
# rule that is always right; OCaml's guard, if it is ever wanted, is a
# behavioural check in the check-abort family, not a grep.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# INDENTATION IS THE DISCRIMINATOR, and in Python it is exact. At module
# scope `with app.build():` is the blessed spelling for mutations
# OUTSIDE any handler — guests/python/menus.py seeds its collections
# that way after mount, and that is correct. Indented, it is inside a
# def, which is inside a handler, which already has a transaction.
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

# The guard guards itself, both directions: a handler-scoped build must
# be caught, and the module-scope one must NOT be.
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
