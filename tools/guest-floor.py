#!/usr/bin/env python3
"""No sugar guest may build a widget at the widget-kind FLOOR.

Invariant 5: all example scenes use each language's construction sugar;
only the C guests keep the fully explicit floor, deliberately, as the
floor's documentation. Before 2026-08-10 that invariant was enforced for
exactly two scenes — check-sugar-surface's scene tier reads only the
`entry` and `milestone2` guests, the two carve-out scenes — so a guest
outside that table could teach the floor indefinitely, and several did:

  - the undo scene built its per-row text field with `widget(KIND_ENTRY)`
    in SEVEN languages, for five milestones;
  - kaya's own text editor shipped its find bar the same way;
  - guests/haskell/textarea.hs and guests/ocaml/textarea.ml built their
    ENTIRE scenes at the floor while every constructor they needed sat
    unused in the binding.

The first two had an excuse — the TEMPLATE zone had no constructor for
those kinds, which is the hole the sugar pass closed. The last two never
did. Now that both construction zones have a constructor for every kind
in every binding, the rule is one sentence with no exceptions to
remember: a sugar guest does not name a widget kind.

WHY THIS IS NOT A CLAUSE IN THE SCENE TIER. That machinery is
scene-scoped: each guest must first prove it IS the scene it is filed
under (by carrying that scene script's expected string), and each floor
rule is watched firing against a doctored copy. It is the right shape
for a per-scene carve-out and the wrong shape for a rule that holds
everywhere — a table with one row per scene per language is a table
someone forgets to add to, which is exactly how this got missed.

COMMENTS ARE STRIPPED FIRST, and that is not fastidiousness: the guests
that were just converted all EXPLAIN the old floor spelling in a comment
above the new sugar call, so a sweep that reads comments reports every
file it just fixed. Caught while writing this — a first pass counted 14
floor calls where there were 13.

Exit 0 when no sugar guest names a widget kind; 1 listing each that does.
"""

import os
import re
import sys

# Per extension: the floor spelling, and how that language starts a
# line comment. OCaml's (* ... *) nests and spans lines, so it gets its
# own stripper below.
FLOOR = {
    ".rs": (r"\.widget\((?:kaya::)?WidgetKind::(\w+)\)", "//"),
    ".go": (r"\.Widget\((?:kaya\.)?Kind(\w+)\)", "//"),
    ".cs": (r"\.Widget\(KayaWire\.Kind(\w+)\)", "//"),
    ".java": (r"\.widget\(KayaWire\.KIND_(\w+)\)", "//"),
    ".swift": (r"\.widget\(UInt32\(KAYA_KIND_(\w+)\)\)", "//"),
    ".ml": (r"(?<![A-Za-z_])widget kind_(\w+)", None),
    ".hs": (r"(?<![A-Za-z])widget kind([A-Z]\w+)", "--"),
    ".py": (r"_widget\(wire\.KIND_(\w+)\)", "#"),
}

# EXEMPT, EACH WITH ITS REASON — the gates.sh EXCLUDED pattern. An
# exemption is a claim on the record, not an absence, so a line that
# stops being exempt fails here rather than sitting unread.
#
# All three want the SAME missing thing: a source for THE SCALAR ELEMENT
# ITSELF. These build a template label over a one-field collection and
# bind it with `bind_text_element` — field 0 of the row, the row's whole
# value. Every binding's template `label` takes a source whose element
# arm is a FIELD, and a field is addressed by index off a record; only
# Go has a name for the scalar case (`Row.Value() Field[string]`).
# Spelling it in the other seven is new vocabulary in eight languages,
# which is a uniformity decision and not a guest fix — so these stay at
# the floor, named, until that decision is made (docs/deferred.md).
EXEMPT = {
    "guests/haskell/menus.hs": "the scalar-element source has no name in 7 of 8 bindings",
    "guests/ocaml/menus.ml": "the scalar-element source has no name in 7 of 8 bindings",
    "guests/swift/menus.swift": "the scalar-element source has no name in 7 of 8 bindings",
}


def strip_comments(lines, marker, ocaml):
    """Yield (lineno, code) with comments removed."""
    depth = 0
    for i, line in enumerate(lines, 1):
        code = line
        if ocaml:
            out = []
            j = 0
            while j < len(code):
                if code.startswith("(*", j):
                    depth += 1
                    j += 2
                elif code.startswith("*)", j) and depth:
                    depth -= 1
                    j += 2
                elif depth == 0:
                    out.append(code[j])
                    j += 1
                else:
                    j += 1
            code = "".join(out)
        elif marker and marker in code:
            code = code.split(marker, 1)[0]
        yield i, code


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    guests = os.path.join(root, "guests")
    hits, scanned, exempted = [], 0, 0

    for base, _, files in os.walk(guests):
        rel_base = os.path.relpath(base, root)
        # The C guests ARE the floor, on purpose: they are its
        # documentation and the tier every other language sugars over.
        if rel_base == "guests/c" or rel_base.startswith("guests/c" + os.sep):
            continue
        for fn in sorted(files):
            ext = os.path.splitext(fn)[1]
            if ext not in FLOOR:
                continue
            path = os.path.join(base, fn)
            rel = os.path.relpath(path, root)
            pattern, marker = FLOOR[ext]
            try:
                lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
            except OSError:
                continue
            scanned += 1
            for lineno, code in strip_comments(lines, marker, ext == ".ml"):
                for m in re.finditer(pattern, code):
                    if rel in EXEMPT:
                        exempted += 1
                        continue
                    hits.append((rel, lineno, m.group(1), lines[lineno - 1].strip()))

    # ANTI-VACUITY, both halves. A sweep that reads no files agrees with
    # everything, and an exemption table whose paths have moved is a
    # table that exempts nothing and would never be noticed — it would
    # simply stop being consulted while the gate went on passing.
    if scanned < 40:
        print(
            f"guest-floor: scanned only {scanned} guest files — this sweep has "
            "stopped finding the guests it exists to read and can no longer fail."
        )
        return 1
    if exempted == 0 and EXEMPT:
        print(
            "guest-floor: the exemption table has "
            f"{len(EXEMPT)} entries and matched nothing. Either those files were "
            "fixed (delete the entries, and the reason with them) or they moved "
            "and the table is now dead weight that exempts nothing."
        )
        return 1

    for rel, lineno, kind, src in hits:
        print(
            f"guest-floor: {rel}:{lineno} builds a {kind.lower()} at the "
            f"widget-kind floor — `{src}`. Both construction zones now have a "
            "constructor for every kind in every binding, so a sugar guest has "
            "no reason to name one: invariant 5 keeps the explicit floor in the "
            "C guests, where it is the documentation, and out of every other "
            "example. Use the sugar-tier constructor, or add the file to EXEMPT "
            "in tools/guest-floor.py WITH THE REASON."
        )
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
