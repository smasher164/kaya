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
# check-symbols.sh (the OS-floor gate) is this gate's sibling: that one
# asks whether the Swift table's names EXIST at the floor, this one asks
# whether the six tables are THE SAME table.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

WIRE=crates/kaya/src/wire.rs
CAPI=crates/kaya/src/capi.rs
GTK=crates/kaya/src/gtk.rs
WINUI=crates/kaya/src/winui/mod.rs
SWIFTUI=swift/KayaSwiftUI.swift
COMPOSE=android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt

check() { # $1..$6: wire capi gtk winui swiftui compose, BY PATH
    python3 - "$@" <<'PY'
import re
import sys

wire, capi, gtk, winui, swiftui, compose = sys.argv[1:7]
read = lambda p: open(p, encoding="utf-8").read()
bad = []

# --- The root: wire::SYMBOLS, (value, name) in wire order. -----------
wt = read(wire)
consts = dict(re.findall(r"pub const (SYMBOL_[A-Z0-9_]+): u32 = (\d+);", wt))
m = re.search(r"pub const SYMBOLS:[^=]*=\s*&\[(.*?)\];", wt, re.S)
if not m:
    print(f"{wire}: no SYMBOLS table — the vocabulary moved and this gate went vacuous")
    sys.exit(2)
root = []
for cname, name in re.findall(r"\(\s*(SYMBOL_[A-Z0-9_]+)\s*,\s*\"([a-z0-9_]+)\"\s*\)", m.group(1)):
    if cname not in consts:
        bad.append(f"{wire}: SYMBOLS names {cname}, which has no const")
        continue
    root.append((cname, int(consts[cname]), name))
if len(root) < 10:
    print(f"{wire}: read only {len(root)} SYMBOLS rows — a census that reads "
          f"almost nothing agrees with everything; REFUSING A VERDICT")
    sys.exit(2)
root_by_cname = {c: (v, n) for c, v, n in root}


def held(site, found, what):
    """found: {cname: detail}. Coverage both ways against the root."""
    missing = [c for c in root_by_cname if c not in found]
    extra = [c for c in found if c not in root_by_cname]
    for c in missing:
        bad.append(f"{site}: {what} has no row for {c} — the concept renders "
                   f"as a missing glyph on this platform alone")
    for c in extra:
        bad.append(f"{site}: {what} carries {c}, which the root vocabulary "
                   f"does not have")


# --- The C floor: KAYA_SYMBOL_* copies value AND name. ---------------
ct = read(capi)
cfloor = {"SYMBOL_" + c[len("KAYA_SYMBOL_"):]: int(v)
          for c, v in re.findall(r"pub const (KAYA_SYMBOL_[A-Z0-9_]+): u32 = (\d+);", ct)}
held(capi, cfloor, "the KAYA_SYMBOL_* block")
for c, v in cfloor.items():
    if c in root_by_cname and v != root_by_cname[c][0]:
        bad.append(f"{capi}: KAYA_{c} = {v}, but wire::{c} = {root_by_cname[c][0]} "
                   f"— the C floor's copy drifted")

# --- GTK: SYMBOL_ICONS keys the wire constants; coverage + a glyph. --
gt = read(gtk)
m = re.search(r"const SYMBOL_ICONS:[^=]*=\s*&\[(.*?)\];", gt, re.S)
if not m:
    print(f"{gtk}: no SYMBOL_ICONS table — this gate went vacuous")
    sys.exit(2)
gtk_rows = re.findall(r"\(\s*crate::wire::(SYMBOL_[A-Z0-9_]+)\s*,\s*\"([^\"]+)\"\s*\)", m.group(1))
held(gtk, {c: g for c, g in gtk_rows}, "SYMBOL_ICONS")
for c, g in gtk_rows:
    if not g.endswith("-symbolic"):
        bad.append(f"{gtk}: {c} maps to \"{g}\", which lacks the -symbolic "
                   f"suffix — GTK then takes the fullcolor legacy path")

# --- WinUI: both S::* match arms cover the vocabulary. ---------------
wt2 = read(winui)
wire_arms = dict(re.findall(r"S::(\w+)\s*=>\s*crate::wire::(SYMBOL_[A-Z0-9_]+)", wt2))
held(winui, {c: s for s, c in wire_arms.items()}, "the S -> wire::SYMBOL_* arm")
glyph_variants = set(re.findall(r"S::(\w+)\s*=>\s*FluentIcon", wt2))
for s in wire_arms:
    if s not in glyph_variants:
        bad.append(f"{winui}: S::{s} has a wire arm but no FluentIcon arm — "
                   f"the concept exists and draws nothing")
for s in glyph_variants:
    if s not in wire_arms:
        bad.append(f"{winui}: S::{s} has a FluentIcon arm but no wire arm — "
                   f"a glyph no wire value can reach")

# --- SwiftUI: private value copies + the four-column table. ----------
st = read(swiftui)
def camel(cname):
    parts = cname[len("SYMBOL_"):].lower().split("_")
    return "symbol" + "".join(p.capitalize() for p in parts)
sw_consts = {c: int(v) for c, v in
             re.findall(r"private let (symbol\w+): Int64 = (\d+)", st)}
sw_by_root = {}
for c, (v, n) in root_by_cname.items():
    sc = camel(c)
    if sc not in sw_consts:
        continue
    sw_by_root[c] = sw_consts[sc]
held(swiftui, sw_by_root, "the private symbol* constants")
for c, v in sw_by_root.items():
    if v != root_by_cname[c][0]:
        bad.append(f"{swiftui}: {camel(c)} = {v}, but wire::{c} = "
                   f"{root_by_cname[c][0]} — the private copy drifted")
sw_rows = dict(re.findall(r"\(\s*(symbol\w+),\s*\"([^\"]+)\",\s*\"[^\"]+\",\s*(?:nil|\"[^\"]*\")\s*\)", st))
sw_table = {c: sw_rows.get(camel(c)) for c in root_by_cname if camel(c) in sw_rows}
held(swiftui, sw_table, "kayaSymbolTable")
for c, n in sw_table.items():
    if n != root_by_cname[c][1]:
        bad.append(f"{swiftui}: kayaSymbolTable names {camel(c)} \"{n}\", but "
                   f"the root calls it \"{root_by_cname[c][1]}\"")

# --- Compose: value copies + the Triple table. -----------------------
kt = read(compose)
kt_consts = {c: int(v) for c, v in
             re.findall(r"const val (SYMBOL_[A-Z0-9_]+) = (\d+)L", kt)}
held(compose, kt_consts, "the const val SYMBOL_* block")
for c, v in kt_consts.items():
    if c in root_by_cname and v != root_by_cname[c][0]:
        bad.append(f"{compose}: {c} = {v}L, but wire::{c} = {root_by_cname[c][0]} "
                   f"— the private copy drifted")
kt_rows = dict(re.findall(r"Triple\(\s*(SYMBOL_[A-Z0-9_]+),\s*\"([^\"]+)\"", kt))
held(compose, kt_rows, "the Triple table")
for c, n in kt_rows.items():
    if c in root_by_cname and n != root_by_cname[c][1]:
        bad.append(f"{compose}: the Triple table names {c} \"{n}\", but the "
                   f"root calls it \"{root_by_cname[c][1]}\"")

if bad:
    print("\n".join(bad))
    sys.exit(1)
print(f"{len(root)} concepts level across six files")
sys.exit(0)
PY
}

status=0
out="$(check "$WIRE" "$CAPI" "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE")"
rc=$?
if [ "$rc" = 2 ]; then
    echo "check-symbol-parity: REFUSED A VERDICT:" >&2
    echo "$out" >&2
    exit 2
elif [ "$rc" != 0 ]; then
    echo "check-symbol-parity: the six symbol tables disagree:" >&2
    echo "$out" >&2
    status=1
fi

# THE GUARD GUARDS ITSELF: each perturbation is applied to a COPY of the
# real bytes, count printed, and the red demanded — a census that reads
# nothing agrees with everything, and each clause here was watched
# failing through this block on the day it landed.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp "$CAPI" "$T/capi.rs"; cp "$GTK" "$T/gtk.rs"; cp "$WINUI" "$T/winui.rs"
cp "$SWIFTUI" "$T/swiftui.swift"; cp "$COMPOSE" "$T/compose.kt"

selftest() { # $1 label, $2 file-to-perturb (path in $T), $3 py-perturb, $4 expect-fragment
    local hits drift
    hits="$(python3 -c "
import re, sys
text = open(sys.argv[1]).read()
drifted, n = $3
open(sys.argv[1], 'w').write(drifted)
print(n)
" "$2")"
    if [ "$hits" != 1 ]; then
        echo "check-symbol-parity: SELF-TEST $1 applied $hits perturbation(s), want 1" >&2
        exit 1
    fi
    drift="$(check "${ARGS[@]}")"
    case "$drift" in
        *"$4"*) echo "check-symbol-parity: self-test $1, 1 substitution(s), red as demanded" ;;
        *)
            echo "check-symbol-parity: SELF-TEST $1 FAIL — wanted \"$4\" in: $drift" >&2
            exit 1
            ;;
    esac
    return 0
}

# N1: a drifted NUMBER in a private copy (the file-modes shape).
ARGS=("$WIRE" "$CAPI" "$GTK" "$WINUI" "$SWIFTUI" "$T/compose.kt")
selftest N1 "$T/compose.kt" "re.subn(r'const val SYMBOL_HOME = 20L', 'const val SYMBOL_HOME = 21L', text)" "the private copy drifted"
cp "$COMPOSE" "$T/compose.kt"

# N2: a row missing from a namer's table.
ARGS=("$WIRE" "$CAPI" "$T/gtk.rs" "$WINUI" "$SWIFTUI" "$COMPOSE")
selftest N2 "$T/gtk.rs" "re.subn(r'\(crate::wire::SYMBOL_HOME, \"go-home-symbolic\"\),', '', text)" "no row for SYMBOL_HOME"
cp "$GTK" "$T/gtk.rs"

# N3: a semantic name flipped in the Swift table.
ARGS=("$WIRE" "$CAPI" "$GTK" "$WINUI" "$T/swiftui.swift" "$COMPOSE")
selftest N3 "$T/swiftui.swift" "re.subn(r'\(symbolHome, \"home\"', '(symbolHome, \"hovel\"', text)" "the root calls it \"home\""
cp "$SWIFTUI" "$T/swiftui.swift"

# N4: a WinUI wire arm gone while its glyph arm stays.
ARGS=("$WIRE" "$CAPI" "$GTK" "$T/winui.rs" "$SWIFTUI" "$COMPOSE")
selftest N4 "$T/winui.rs" "re.subn(r'S::Home => crate::wire::SYMBOL_HOME,', '', text)" "no wire arm"

[ "$status" = 0 ] && echo "check-symbol-parity: OK ($(check "$WIRE" "$CAPI" "$GTK" "$WINUI" "$SWIFTUI" "$COMPOSE"))"
exit "$status"
