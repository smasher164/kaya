#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# An SF Symbols 6 rename (`doc.on.doc` -> `document.on.document`) needs
# macOS 15 / iOS 18 and renders BLANK below that, with no build error and
# nothing a scene can see (measured 2026-08-16; CLAUDE.md's gate list).
# The only thing that can answer is Apple's own availability data, which
# ships on every mac: every SF name in kaya's table must carry a year
# whose macOS release is <= 13.0 and whose iOS release is <= 16.0, since
# one Swift file serves both platforms.

import plistlib
import re

SWIFT = "swift/KayaSwiftUI.swift"
PLIST = ("/System/Library/CoreServices/CoreGlyphs.bundle/Contents/"
         "Resources/name_availability.plist")

# kaya's declared floor. One file serves mac AND iOS, so both halves
# bind.
FLOOR_MAC, FLOOR_IOS = (13, 0), (16, 0)

gate = Gate("check-symbols")


def ver(s):
    parts = [int(p) for p in re.findall(r"\d+", s)[:2]]
    while len(parts) < 2:
        parts.append(0)
    return tuple(parts)


def check(src, text):
    """('refused', msg) | ('bad', lines) | ('ok', row-count)."""
    try:
        with open(PLIST, "rb") as fh:
            cat = plistlib.load(fh)
    except OSError as exc:
        return "refused", (
            f"check-symbols: cannot read {PLIST} ({exc.strerror}) — this "
            f"gate reads Apple's own availability data and has nothing to "
            f"answer from")
    symbols = cat.get("symbols") or {}
    years = cat.get("year_to_release") or {}
    if not symbols or not years:
        return "refused", (
            "check-symbols: name_availability.plist has no "
            "symbols/year_to_release table — the catalog moved and this "
            "gate itself broke")

    bad = []
    # (constant, semantic name, sf name, rendered-or-nil). The fourth
    # column is the AX read-back a MODERN OS reports for the old spelling
    # — a measurement, not a request, so the floor does not bind it.
    rows = re.findall(
        r'\(\s*(symbol\w+),\s*"([^"]+)",\s*"([^"]+)",\s*(?:nil|"[^"]*")\s*\)',
        text)
    if not rows:
        bad.append(f"no symbol rows extracted from {src}: the gate itself "
                   f"broke")

    for _const, name, sf in rows:
        year = symbols.get(sf)
        if year is None:
            bad.append(f'{name} -> "{sf}": NOT IN Apple\'s catalog at all — '
                       f"it would render as a blank image on every OS")
            continue
        rel = years.get(year) or {}
        mac, ios = rel.get("macOS"), rel.get("iOS")
        if mac is None or ios is None:
            bad.append(f'{name} -> "{sf}": year {year} has no macOS/iOS '
                       f"release in year_to_release")
            continue
        if ver(mac) > FLOOR_MAC or ver(ios) > FLOOR_IOS:
            bad.append(f'{name} -> "{sf}": introduced macOS {mac} / iOS '
                       f"{ios} (SF Symbols year {year}), ABOVE kaya's floor "
                       f"of macOS {FLOOR_MAC[0]}.{FLOOR_MAC[1]} / iOS "
                       f"{FLOOR_IOS[0]}.{FLOOR_IOS[1]} — it resolves on a "
                       f"current machine and renders BLANK on the floor, "
                       f"which no scene can see")
    if bad:
        return "bad", bad
    return "ok", len(rows)


text = gate.read(SWIFT)
status = 0
verdict, payload = check(SWIFT, text)
if verdict == "refused":
    print(payload, file=sys.stderr)
    print(f"check-symbols: an SF Symbols name in {SWIFT} is not available "
          f"at kaya's floor:", file=sys.stderr)
    print("", file=sys.stderr)
    status = 1
elif verdict == "bad":
    print(f"check-symbols: an SF Symbols name in {SWIFT} is not available "
          f"at kaya's floor:", file=sys.stderr)
    print("\n".join(payload), file=sys.stderr)
    status = 1

# Perturbed out of the REAL file, so what is proven is that the rule
# matches the spelling this file actually carries.
drifted = gate.doctor("the doc.on.doc perturbation", text,
                      r'"doc\.on\.doc"', '"document.on.document"')
dverdict, dpayload = check("drifted.swift", drifted)
drift = "\n".join(dpayload) if dverdict == "bad" else str(dpayload)
if not ("document.on.document" in drift and "ABOVE kaya" in drift):
    print(f"check-symbols: SELF-TEST FAIL (the macOS-15 rename was not "
          f"refused): {drift}", file=sys.stderr)
    sys.exit(1)

# And the accept direction: a rule that refused everything would pass the
# refusal above. The count comes from the same code that enforced the
# rule, never a second pattern that could drift to zero on its own.
if status == 0:
    print(f"check-symbols: OK ({payload} names at or below macOS 13.0 / "
          f"iOS 16.0)")
sys.exit(status)
