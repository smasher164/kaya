#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# THE FAILURE THIS EXISTS FOR, MEASURED 2026-08-16. The semantic icon
# vocabulary (docs/styling-plan.md D6) maps each concept to an SF Symbols
# name in swift/KayaSwiftUI.swift. Apple renamed several families in SF
# Symbols 6 (2024): `doc.on.doc` -> `document.on.document` and kin. The
# OLD names still resolve everywhere. The NEW ones need macOS 15 / iOS 18
# and, below that, fail as a BLANK IMAGE — no build error, no runtime
# complaint.
#
# NO SCENE CAN CATCH THIS, measured rather than assumed: swapping
# `doc.on.doc` for `document.on.document` and running the menus scene on
# this machine PASSED, because the new name resolves perfectly well on a
# current OS. A resolution check only fails on a machine old enough to be
# the floor, and nobody has one. The only thing that CAN answer is
# Apple's own availability data, which ships on every mac:
#   /System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/
#     name_availability.plist   — name -> introduction year, plus a
#                                 year -> {macOS, iOS, ...} release table
#
# The rule: every SF name in kaya's table must exist in that plist with a
# year whose macOS release is <= kaya's floor (macOS 13.0 = SF Symbols 4)
# AND whose iOS release is <= 16.0, because one Swift file serves both
# platforms.
#
# Usage: check-symbols.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

SWIFT=swift/KayaSwiftUI.swift
PLIST=/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist

check() { # $1: the swift source, BY PATH
    #
    # BY PATH AND NEVER BY STDIN: this python body arrives ON stdin
    # (the heredoc), so a "-" convention would read the script itself
    # and report "no symbol rows" — which is exactly what the first cut
    # of the self-test below said, and it read as a broken RULE rather
    # than a broken HARNESS.
    python3 - "$1" "$PLIST" <<'PY'
import plistlib
import re
import sys

src, plist_path = sys.argv[1], sys.argv[2]
text = open(src).read()

# kaya's declared floor. One file serves mac AND iOS, so both halves
# bind.
FLOOR_MAC, FLOOR_IOS = (13, 0), (16, 0)

bad = []


def ver(s):
    parts = [int(p) for p in re.findall(r"\d+", s)[:2]]
    while len(parts) < 2:
        parts.append(0)
    return tuple(parts)


try:
    with open(plist_path, "rb") as fh:
        cat = plistlib.load(fh)
except OSError as exc:
    print(f"check-symbols: cannot read {plist_path} ({exc.strerror}) — this gate "
          f"reads Apple's own availability data and has nothing to answer from",
          file=sys.stderr)
    sys.exit(2)

symbols = cat.get("symbols") or {}
years = cat.get("year_to_release") or {}
if not symbols or not years:
    print("check-symbols: name_availability.plist has no symbols/year_to_release "
          "table — the catalog moved and this gate itself broke", file=sys.stderr)
    sys.exit(2)

# The table rows: (constant, semantic name, sf name, rendered-or-nil).
# The fourth column is the AX read-back name a MODERN OS reports for the
# old spelling — a measurement, not a request, so the floor does not
# bind it; only the sf column is what kaya asks the OS for.
rows = re.findall(
    r'\(\s*(symbol\w+),\s*"([^"]+)",\s*"([^"]+)",\s*(?:nil|"[^"]*")\s*\)',
    text)
if not rows:
    bad.append(f"no symbol rows extracted from {src}: the gate itself broke")

for _const, name, sf in rows:
    year = symbols.get(sf)
    if year is None:
        bad.append(f'{name} -> "{sf}": NOT IN Apple\'s catalog at all — it would '
                   f"render as a blank image on every OS")
        continue
    rel = years.get(year) or {}
    mac, ios = rel.get("macOS"), rel.get("iOS")
    if mac is None or ios is None:
        bad.append(f'{name} -> "{sf}": year {year} has no macOS/iOS release in '
                   f"year_to_release")
        continue
    if ver(mac) > FLOOR_MAC or ver(ios) > FLOOR_IOS:
        bad.append(f'{name} -> "{sf}": introduced macOS {mac} / iOS {ios} '
                   f"(SF Symbols year {year}), ABOVE kaya's floor of macOS "
                   f"{FLOOR_MAC[0]}.{FLOOR_MAC[1]} / iOS {FLOOR_IOS[0]}."
                   f"{FLOOR_IOS[1]} — it resolves on a current machine and "
                   f"renders BLANK on the floor, which no scene can see")

if bad:
    print("\n".join(bad))
    sys.exit(1)
print(len(rows))
sys.exit(0)
PY
}

status=0
count="$(check "$SWIFT")" || {
    echo "check-symbols: an SF Symbols name in $SWIFT is not available at kaya's floor:" >&2
    echo "$count" >&2
    status=1
}

# THE GUARD GUARDS ITSELF, perturbed out of the REAL file so what is
# proven is that the rule matches the spelling this file actually
# carries — and the substitution count is printed and checked, because a
# perturbation that did not apply proves nothing.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
hits="$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
drifted, n = re.subn(r"\"doc\.on\.doc\"", "\"document.on.document\"", text)
open(sys.argv[2], "w").write(drifted)
print(n)
' "$SWIFT" "$T/drifted.swift")"
if [ "$hits" != 1 ]; then
    echo "check-symbols: SELF-TEST FAIL (the doc.on.doc perturbation applied $hits times, want 1)" >&2
    exit 1
fi
drift="$(check "$T/drifted.swift")"
case "$drift" in
    *'document.on.document'*'ABOVE kaya'*) ;;
    *)
        echo "check-symbols: SELF-TEST FAIL (the macOS-15 rename was not refused): $drift" >&2
        exit 1
        ;;
esac

# And the accept direction: a rule that refused everything would pass the
# refusal above. The real check ran first; its verdict is $status, and
# the count it printed came from the same python that enforced the rule —
# never a second pattern that could drift to zero on its own.
[ "$status" = 0 ] && echo "check-symbols: OK ($count names at or below macOS 13.0 / iOS 16.0)"
exit "$status"
