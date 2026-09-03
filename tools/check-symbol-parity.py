#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# ONE SYMBOL VOCABULARY, SIX FILES. `wire::SYMBOLS`
# (crates/kaya/src/wire.rs) owns the (value, semantic name) set; it is
# not in the spec hash, and adding a concept regenerates nothing, so the
# other five sites are a matched set nobody is reminded of:
#
#   crates/kaya/src/capi.rs       KAYA_SYMBOL_* — the C floor's copies
#   crates/kaya/src/gtk.rs        SYMBOL_ICONS, keyed on wire::SYMBOL_*
#   crates/kaya/src/winui/mod.rs  the two S::* match arms
#   swift/KayaSwiftUI.swift       private let symbol* + kayaSymbolTable
#   android/…/KayaCompose.kt      const val SYMBOL_* + the Triple table
#
# GTK and WinUI NAME the wire constants, so the compiler holds their
# values and this gate holds their COVERAGE; Swift, Compose and the C
# floor copy the NUMBERS by hand (check-file-modes' trap, one surface
# over), so this gate holds value, name and coverage all three. A
# concept added to five of six files fails nowhere at build time and
# renders as a missing glyph on the sixth platform only.
#
# check-symbols.py (the OS-floor gate) is this gate's sibling: that one
# asks whether the Swift table's names EXIST at the floor, this one asks
# whether the six tables are THE SAME table.

import re

WIRE = "crates/kaya/src/wire.rs"
CAPI = "crates/kaya/src/capi.rs"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

gate = Gate("check-symbol-parity")


def camel(cname):
    parts = cname[len("SYMBOL_"):].lower().split("_")
    return "symbol" + "".join(p.capitalize() for p in parts)


def check(texts):
    """texts: {site-name: text} for the six files.
    ('refused', msg) | ('bad', lines) | ('ok', sentence)."""
    wire, capi, gtk, winui, swiftui, compose = (
        WIRE, CAPI, GTK, WINUI, SWIFTUI, COMPOSE)
    bad = []

    # --- The root: wire::SYMBOLS, (value, name) in wire order. -------
    wt = texts[wire]
    consts = dict(re.findall(r"pub(?:\(crate\))? const (SYMBOL_[A-Z0-9_]+): u32 = (\d+);",
                             wt))
    m = re.search(r"pub(?:\(crate\))? const SYMBOLS:[^=]*=\s*&\[(.*?)\];", wt, re.S)
    if not m:
        return "refused", (f"{wire}: no SYMBOLS table — the vocabulary "
                           f"moved and this gate went vacuous")
    root = []
    for cname, name in re.findall(
            r"\(\s*(SYMBOL_[A-Z0-9_]+)\s*,\s*\"([a-z0-9_]+)\"\s*\)",
            m.group(1)):
        if cname not in consts:
            bad.append(f"{wire}: SYMBOLS names {cname}, which has no const")
            continue
        root.append((cname, int(consts[cname]), name))
    if len(root) < 10:
        return "refused", (
            f"{wire}: read only {len(root)} SYMBOLS rows — a census that "
            f"reads almost nothing agrees with everything; REFUSING A "
            f"VERDICT")
    root_by_cname = {c: (v, n) for c, v, n in root}

    def held(site, found, what):
        """found: {cname: detail}. Coverage both ways against the root."""
        for c in (c for c in root_by_cname if c not in found):
            bad.append(f"{site}: {what} has no row for {c} — the concept "
                       f"renders as a missing glyph on this platform alone")
        for c in (c for c in found if c not in root_by_cname):
            bad.append(f"{site}: {what} carries {c}, which the root "
                       f"vocabulary does not have")

    # --- The C floor: KAYA_SYMBOL_* copies value AND name. -----------
    ct = texts[capi]
    cfloor = {"SYMBOL_" + c[len("KAYA_SYMBOL_"):]: int(v)
              for c, v in re.findall(
                  r"pub(?:\(crate\))? const (KAYA_SYMBOL_[A-Z0-9_]+): u32 = (\d+);", ct)}
    held(capi, cfloor, "the KAYA_SYMBOL_* block")
    for c, v in cfloor.items():
        if c in root_by_cname and v != root_by_cname[c][0]:
            bad.append(f"{capi}: KAYA_{c} = {v}, but wire::{c} = "
                       f"{root_by_cname[c][0]} — the C floor's copy drifted")

    # --- GTK: SYMBOL_ICONS keys the wire constants; coverage + glyph. -
    gt = texts[gtk]
    m = re.search(r"const SYMBOL_ICONS:[^=]*=\s*&\[(.*?)\];", gt, re.S)
    if not m:
        return "refused", f"{gtk}: no SYMBOL_ICONS table — this gate went " \
                          f"vacuous"
    gtk_rows = re.findall(
        r"\(\s*crate::wire::(SYMBOL_[A-Z0-9_]+)\s*,\s*\"([^\"]+)\"\s*\)",
        m.group(1))
    held(gtk, dict(gtk_rows), "SYMBOL_ICONS")
    for c, g in gtk_rows:
        if not g.endswith("-symbolic"):
            bad.append(f'{gtk}: {c} maps to "{g}", which lacks the '
                       f"-symbolic suffix — GTK then takes the fullcolor "
                       f"legacy path")

    # --- WinUI: both S::* match arms cover the vocabulary. -----------
    wt2 = texts[winui]
    wire_arms = dict(re.findall(
        r"S::(\w+)\s*=>\s*crate::wire::(SYMBOL_[A-Z0-9_]+)", wt2))
    held(winui, {c: s for s, c in wire_arms.items()},
         "the S -> wire::SYMBOL_* arm")
    glyph_variants = set(re.findall(r"S::(\w+)\s*=>\s*FluentIcon", wt2))
    for s in wire_arms:
        if s not in glyph_variants:
            bad.append(f"{winui}: S::{s} has a wire arm but no FluentIcon "
                       f"arm — the concept exists and draws nothing")
    for s in glyph_variants:
        if s not in wire_arms:
            bad.append(f"{winui}: S::{s} has a FluentIcon arm but no wire "
                       f"arm — a glyph no wire value can reach")

    # --- SwiftUI: private value copies + the four-column table. ------
    st = texts[swiftui]
    sw_consts = {c: int(v) for c, v in re.findall(
        r"private let (symbol\w+): Int64 = (\d+)", st)}
    sw_by_root = {c: sw_consts[camel(c)] for c in root_by_cname
                  if camel(c) in sw_consts}
    held(swiftui, sw_by_root, "the private symbol* constants")
    for c, v in sw_by_root.items():
        if v != root_by_cname[c][0]:
            bad.append(f"{swiftui}: {camel(c)} = {v}, but wire::{c} = "
                       f"{root_by_cname[c][0]} — the private copy drifted")
    sw_rows = dict(re.findall(
        r"\(\s*(symbol\w+),\s*\"([^\"]+)\",\s*\"[^\"]+\",\s*"
        r"(?:nil|\"[^\"]*\")\s*\)", st))
    sw_table = {c: sw_rows[camel(c)] for c in root_by_cname
                if camel(c) in sw_rows}
    held(swiftui, sw_table, "kayaSymbolTable")
    for c, n in sw_table.items():
        if n != root_by_cname[c][1]:
            bad.append(f'{swiftui}: kayaSymbolTable names {camel(c)} '
                       f'"{n}", but the root calls it '
                       f'"{root_by_cname[c][1]}"')

    # --- Compose: value copies + the Triple table. -------------------
    kt = texts[compose]
    kt_consts = {c: int(v) for c, v in re.findall(
        r"const val (SYMBOL_[A-Z0-9_]+) = (\d+)L", kt)}
    held(compose, kt_consts, "the const val SYMBOL_* block")
    for c, v in kt_consts.items():
        if c in root_by_cname and v != root_by_cname[c][0]:
            bad.append(f"{compose}: {c} = {v}L, but wire::{c} = "
                       f"{root_by_cname[c][0]} — the private copy drifted")
    kt_rows = dict(re.findall(r"Triple\(\s*(SYMBOL_[A-Z0-9_]+),\s*"
                              r"\"([^\"]+)\"", kt))
    held(compose, kt_rows, "the Triple table")
    for c, n in kt_rows.items():
        if c in root_by_cname and n != root_by_cname[c][1]:
            bad.append(f'{compose}: the Triple table names {c} "{n}", but '
                       f'the root calls it "{root_by_cname[c][1]}"')

    if bad:
        return "bad", bad
    return "ok", f"{len(root)} concepts level across six files"


REAL = {p: gate.read(p) for p in (WIRE, CAPI, GTK, WINUI, SWIFTUI, COMPOSE)}

status = 0
verdict, payload = check(REAL)
if verdict == "refused":
    print("check-symbol-parity: REFUSED A VERDICT:", file=sys.stderr)
    print(payload, file=sys.stderr)
    sys.exit(2)
if verdict == "bad":
    print("check-symbol-parity: the six symbol tables disagree:",
          file=sys.stderr)
    print("\n".join(payload), file=sys.stderr)
    status = 1


# THE GUARD GUARDS ITSELF: each perturbation is applied in memory to the
# real bytes (the prelude's doctor — count printed, an unapplied
# perturbation refused), and the red demanded — a census that reads
# nothing agrees with everything, and each clause here was watched
# failing through this block on the day it landed.
def selftest(label, site, pattern, repl, expect):
    doctored = gate.doctor(label, REAL[site], pattern, repl)
    v, p = check({**REAL, site: doctored})
    drift = "\n".join(p) if v == "bad" else str(p)
    if expect in drift:
        print(f"check-symbol-parity: self-test {label}, 1 substitution(s), "
              f"red as demanded")
    else:
        print(f'check-symbol-parity: SELF-TEST {label} FAIL — wanted '
              f'"{expect}" in: {drift}', file=sys.stderr)
        sys.exit(1)


# N1: a drifted NUMBER in a private copy (the file-modes shape).
selftest("N1", COMPOSE, r"const val SYMBOL_HOME = 20L",
         "const val SYMBOL_HOME = 21L", "the private copy drifted")
# N2: a row missing from a namer's table.
selftest("N2", GTK, r'\(crate::wire::SYMBOL_HOME, "go-home-symbolic"\),',
         "", "no row for SYMBOL_HOME")
# N3: a semantic name flipped in the Swift table.
selftest("N3", SWIFTUI, r'\(symbolHome, "home"', '(symbolHome, "hovel"',
         'the root calls it "home"')
# N4: a WinUI wire arm gone while its glyph arm stays.
selftest("N4", WINUI, r"S::Home => crate::wire::SYMBOL_HOME,", "",
         "no wire arm")
# N5: a drifted NUMBER in the C floor's copy — found unwatched during
# the 2026-08-31 python conversion (the clause existed in the shell body
# with no negative pointing at it; invariant 3 says a clause nobody has
# seen fire is a guess).
selftest("N5", CAPI, r"pub const KAYA_SYMBOL_HOME: u32 = 20;",
         "pub const KAYA_SYMBOL_HOME: u32 = 21;",
         "the C floor's copy drifted")

if status == 0:
    print(f"check-symbol-parity: OK ({payload})")
sys.exit(status)
