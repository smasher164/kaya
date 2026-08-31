#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# THE WINDOWS ACCENT NEAR-NO-OP HAS A WALL. Fluent control styles never
# read `SystemAccentColor` for a fill — they read the six derived stops
# (`SystemAccentColorDark1..3`, `...Light1..3`), theme-crossed — so an
# app that writes the bare key changes the text-selection highlight and
# NOTHING ELSE, silently (microsoft-ui-xaml#6394; the measurement and
# the crossed-stops table live on crates/kaya/src/winui/mod.rs's
# brand_dictionary). The styling scene deliberately reads no pixels for
# this, so no lane can catch the mistake — the ledger filed "this wants
# a gate, not a comment" and this is that gate.
#
# THE DISCRIMINATOR IS THE ELEMENT MARKER: prose says SystemAccentColor
# bare all the time, and the module's own unit test holds the bare key
# as a forbidden NEEDLE (`"x:Key=\"SystemAccentColor\""` in a list) —
# only EMITTED XAML spells `<Color x:Key="SystemAccentColor...`. Every
# such element must carry one of the six derived suffixes, all six
# present exactly once. That unit test is this wall's RENDERED-output
# sibling on the windows guest's unit phase; this one runs in the fast
# sweep on every host.

import re

WINUI = "crates/kaya/src/winui/mod.rs"
WANT = {"Dark1", "Dark2", "Dark3", "Light1", "Light2", "Light3"}

gate = Gate("check-accent")


def check(text):
    """(verdict, lines): 'refused' | 'bad' | 'ok'. Sentences verbatim
    from the shell body this replaced."""
    hits = re.findall(r'<Color x:Key=\\?"SystemAccentColor([A-Za-z0-9]*)\\?"',
                      text)
    if not hits:
        return "refused", [
            'no <Color x:Key="SystemAccentColor..." markup in the file at '
            "all — either the brand dictionary moved (and this gate is "
            "blind) or the accent override is gone entirely"]
    bad = []
    seen = {}
    for suffix in hits:
        if suffix == "":
            bad.append('x:Key="SystemAccentColor" BARE: the documented '
                       "near-no-op — it moves the text-selection highlight "
                       "and nothing else, and no scene or lane can see the "
                       "difference")
        elif suffix not in WANT:
            bad.append(f'x:Key="SystemAccentColor{suffix}": not one of the '
                       f"six derived stops Fluent actually reads")
        else:
            seen[suffix] = seen.get(suffix, 0) + 1
    for stop in sorted(WANT):
        n = seen.get(stop, 0)
        if n != 1:
            bad.append(f"SystemAccentColor{stop} appears {n} times in "
                       f"emitted markup, want exactly 1 — a missing stop is "
                       f"a fill that silently stays the platform's")
    if bad:
        return "bad", bad
    return "ok", [f"{len(hits)} accent stops, all six derived, no bare key"]


text = gate.read(WINUI)
verdict, out = check(text)
if verdict == "refused":
    print("check-accent: REFUSED A VERDICT:", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    sys.exit(2)
status = 0
if verdict == "bad":
    print("check-accent: the WinUI accent markup is wrong:", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1

# THE GUARD GUARDS ITSELF, perturbed out of the real file, counts
# printed (the prelude's doctor), the red demanded — both failure
# directions.
bare = gate.doctor(
    "N1 (bare key)", text,
    r'<Color x:Key=(\\?")SystemAccentColorDark1(\\?")',
    r"<Color x:Key=\1SystemAccentColor\2")
drift = "\n".join(check(bare)[1])
if "BARE" in drift:
    print("check-accent: self-test N1 (bare key), 1 substitution(s), "
          "red as demanded")
else:
    print(f"check-accent: SELF-TEST N1 FAIL — a bare SystemAccentColor was "
          f"not refused: {drift}", file=sys.stderr)
    sys.exit(1)

missing = gate.doctor(
    "N2 (missing stop)", text,
    r'<Color x:Key=(\\?")SystemAccentColorLight2(\\?")',
    r"<Color x:Key=\1KayaGoneStop\2")
drift = "\n".join(check(missing)[1])
if "appears 0 times" in drift:
    print("check-accent: self-test N2 (missing stop), 1 substitution(s), "
          "red as demanded")
else:
    print(f"check-accent: SELF-TEST N2 FAIL — a missing derived stop was "
          f"not refused: {drift}", file=sys.stderr)
    sys.exit(1)

if status == 0:
    print(f"check-accent: OK ({out[0]})")
sys.exit(status)
