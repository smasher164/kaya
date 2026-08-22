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
# THE TABLE TIER ROUTING (docs/tables-plan.md decision 5, revised
# 2026-08-21; docs/traps.md, "An observable with no discriminator cannot
# be asserted onto a device").
#
# A table's two tiers present IDENTICAL BYTES to every harness verb — the
# size class came out of expect_columns on purpose — so no scene, on any
# device, can name the tier that drew it. Before this gate the only proof
# was a one-arm perturbation with the other device's leg watched staying
# green, redone by hand whenever the routing moved. The routing is a pure
# function now, and this is where it is held:
#
#   A  STATIC, any host: KayaTableSurface is the ONLY caller of the
#      native/synthesized split — both tier views are constructed inside
#      its body and nowhere else — and that body decides by calling
#      kayaTableTier, which reads its parameters and nothing else (no
#      environment, no #if; the mac probe below could not drive the iOS
#      arms of a rule compiled per platform). The environment reaches the
#      rule down ONE path, `widthClass`, whose two one-line arms are both
#      read here — the iOS arm most of all, since it is the line no host
#      running this gate executes.
#   B  RUNTIME, macOS only — tools/checks/swiftui-table-tier.swift
#      compiled INTO the interpreter's own module and run: the whole
#      truth table (four widths x both availabilities), the mapping from
#      the environment's own size-class type, this host's own branch, and
#      a REAL KayaTableSurface in an NSWindow with the NSTableView the
#      native tier is made of found in the view tree. SKIPPED AND SAID SO
#      on any other host.
#
# WHAT NEITHER CLAUSE HOLDS: which size class a PHYSICAL device reports.
# The simulator's answer is the only one this repo can read.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

SWIFTUI=swift/KayaSwiftUI.swift
PROBE=tools/checks/swiftui-table-tier.swift

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# --- Clause A, as one reader over the interpreter. -------------------
check() {
    # $1: KayaSwiftUI.swift (or a doctored copy). Offenders on stdout,
    # 1 on any.
    python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
raw = open(path, encoding="utf-8").read()
bad = []


def strip(text):
    """Code only: comments and string literals blanked, newlines kept so
    offsets AND line numbers still name the real file. A gate that reads
    prose fails on documentation (check-empty-child learned that one)."""
    out, i, n = [], 0, len(text)

    def blank(s):
        return "".join("\n" if c == "\n" else " " for c in s)

    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(blank(text[i:j]))
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i)
            j = n if j < 0 else j + 2
            out.append(blank(text[i:j]))
            i = j
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(blank(text[i:j]))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def span(text, i):
    """From the brace at `i` to its match. The text is already stripped,
    so no comment or literal can close it early."""
    depth, j, n = 0, i, len(text)
    while j < n:
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return None


def braced(text, pattern, start=0, end=None):
    """(open, close) of the braced block following the first match of
    `pattern` inside [start, end), or None — and None is a FAILURE at
    every callsite: a reader that stopped finding what it reads reports
    a clean bill about nothing."""
    m = re.compile(pattern).search(text, start, len(text) if end is None else end)
    if not m:
        return None
    i = text.find("{", m.end() - 1)
    if i < 0:
        return None
    j = span(text, i)
    return None if j is None else (i, j)


def line_of(off):
    return raw.count("\n", 0, off) + 1


text = strip(raw)

TIERS = ("KayaNativeTable", "KayaSynthesizedTable")

surface = braced(text, r"struct KayaTableSurface\s*:\s*View\b")
if surface is None:
    bad.append(f"{path}: no `struct KayaTableSurface: View` — the surface this gate "
               "reads was renamed or moved, and every clause below would be a "
               "verdict about nothing. Point the gate at the new name.")
    body = None
else:
    body = braced(text, r"var body\s*:\s*some View\b", surface[0], surface[1])
    if body is None:
        bad.append(f"{path}: KayaTableSurface has no `var body: some View` block this "
                   "gate can read — the routing moved out of the body and the "
                   "construction census below has nothing to hold it to.")

# A1 — the two tier views are constructed inside that body and nowhere
# else. The counts are printed: a census that found none would agree
# with everything.
if body is not None:
    for tier in TIERS:
        sites = [m.start() for m in re.finditer(re.escape(tier) + r"\s*\(", text)]
        outside = [s for s in sites if not (body[0] <= s < body[1])]
        print(f"check-table-tier: {tier} constructed {len(sites)} time(s), "
              f"{len(sites) - len(outside)} inside the routing")
        if not sites:
            bad.append(f"{path}: {tier} is never constructed — this census is reading "
                       "a name the interpreter no longer uses, so it agrees with "
                       "anything.")
        for off in outside:
            # WHERE it escaped to is the difference between two fixes, so
            # the sentence says which one this is.
            where = ("inside KayaTableSurface but outside its `body`"
                     if surface[0] <= off < surface[1]
                     else "outside KayaTableSurface altogether")
            bad.append(f"{path}:{line_of(off)}: {tier} is constructed {where}. The "
                       "tier split has ONE caller by design — the switch on "
                       "kayaTableTier in that body — because a second one takes a "
                       "tier nothing tested and no scene can see (docs/traps.md: "
                       "both tiers present identical bytes).")

# A2 — and that body decides by calling the rule, rather than re-deriving
# it. A body that stops consulting kayaTableTier leaves clause B testing
# a function nothing calls.
if body is not None:
    inside = text[body[0]:body[1]]
    if "kayaTableTier(" not in inside:
        bad.append(f"{path}: KayaTableSurface's body never calls `kayaTableTier` — the "
                   "tier is decided somewhere this gate's runtime clause does not "
                   "reach, so the truth table it drives would be about dead code.")
    floor = braced(text, r"if #available\(macOS 14\.4, iOS 17\.4, \*\)",
                   body[0], body[1])
    if floor is None:
        bad.append(f"{path}: KayaTableSurface's body has no "
                   "`if #available(macOS 14.4, iOS 17.4, *)` — TableColumnForEach's "
                   "floor is what `dynamicColumns` MEANS, and the gate cannot see "
                   "which branch is the below-floor one without it.")
    else:
        rest = braced(text, r"\belse\b", floor[1], body[1])
        if rest is None:
            bad.append(f"{path}: the availability check in KayaTableSurface's body has "
                       "no `else` branch. Below TableColumnForEach's floor the tier is "
                       "forced, and that branch must still draw a table.")
        else:
            low = text[rest[0]:rest[1]]
            if "KayaSynthesizedTable(" not in low or "KayaNativeTable(" in low:
                bad.append(f"{path}: the below-floor branch of KayaTableSurface's body "
                           "must construct KayaSynthesizedTable and only that — it is "
                           "the `dynamicColumns: false` half of kayaTableTier's truth "
                           "table, and the two must say the same thing.")

# A3 — the rule reads its parameters and nothing else. A rule compiled
# per platform, or one that reaches into the environment, cannot be
# driven off-device at all, which is the whole point of the split.
rule = braced(text, r"func kayaTableTier\s*\(")
if rule is None:
    bad.append(f"{path}: no `func kayaTableTier(` — the pure tier rule is gone or "
               "renamed. The routing is testable only while it is a function of its "
               "arguments (docs/traps.md).")
else:
    inner = text[rule[0]:rule[1]]
    for hazard in ("#if", "horizontalSizeClass", "Environment", "os(macOS)"):
        if hazard in inner:
            bad.append(f"{path}: kayaTableTier's body contains `{hazard}`. The rule "
                       "must be one function on both platforms and read only its "
                       "parameters — the mac probe cannot drive an iOS arm that is "
                       "compiled away, and a rule that reads the environment cannot "
                       "be driven at all.")
    before = text[:rule[0]]
    if before.count("#if") != before.count("#endif"):
        bad.append(f"{path}: kayaTableTier is declared inside a conditional-"
                   "compilation block — on the other platform the rule this gate "
                   "drives does not exist.")

# A4 — the environment reaches the rule down ONE path: widthClass, whose
# two arms are each a single line. The mac arm the runtime clause reads
# for real; the iOS arm is the one no host here can execute, and it is
# exactly where the traps entry's failure lives — a phone routed to the
# native tier presents the same bytes as one routed to kaya's header, so
# no leg on any device would say a word.
MAC_ARM = "return .noSizeClass"
IOS_ARM = "return kayaTableWidth(sizeClass: horizontalSizeClass)"
if surface is not None:
    prop = braced(text, r"var widthClass\s*:\s*KayaTableWidth\b", surface[0], surface[1])
    if prop is None:
        bad.append(f"{path}: KayaTableSurface has no `var widthClass: KayaTableWidth` "
                   "block — the size class enters the rule somewhere else now, and "
                   "the arm this gate cannot execute is unread.")
    else:
        arms_text = text[prop[0] + 1:prop[1] - 1]
        i = arms_text.find("#if os(macOS)")
        j = arms_text.find("#else", i + 1)
        k = arms_text.find("#endif", j + 1)
        if min(i, j, k) < 0:
            bad.append(f"{path}: widthClass is not `#if os(macOS)` / `#else` / "
                       "`#endif` with one arm each. The gate reads the two arms "
                       "separately because only one of them runs on the host that "
                       "runs this gate.")
        else:
            arms = {
                "macOS arm": (
                    " ".join(arms_text[i + len("#if os(macOS)"):j].split()), MAC_ARM),
                "non-macOS arm": (
                    " ".join(arms_text[j + len("#else"):k].split()), IOS_ARM),
            }
            for which, (got, want) in arms.items():
                if got != want:
                    bad.append(f"{path}: the {which} of `widthClass` reads {got!r}, "
                               f"wanted exactly {want!r}. The size class enters the "
                               "tier rule through kayaTableWidth and nowhere else — "
                               "that mapping is what the runtime clause drives, and "
                               "an arm that derives a width for itself is a second "
                               "rule no device could ever contradict (docs/traps.md: "
                               "both tiers present identical bytes).")
    # …and it is read there ONCE. A second reading anywhere in the surface
    # is a second rule, and the compact phone is the leg that cannot see it.
    for m in re.finditer(r"horizontalSizeClass", text[surface[0]:surface[1]]):
        off = surface[0] + m.start()
        if prop is not None and prop[0] <= off < prop[1]:
            continue
        if "@Environment" in text[text.rfind("\n", 0, off) + 1:off]:
            continue
        bad.append(f"{path}:{line_of(off)}: KayaTableSurface reads "
                   "`horizontalSizeClass` outside `widthClass`. The environment has "
                   "one reading, mapped by kayaTableWidth; a second one decides a "
                   "tier the gate's truth table never saw.")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY
}

# --- The self-test: every clause above WATCHED GOING RED. ------------
# Perturbations are applied to COPIES; the substitution count is printed
# and an unchanged copy is a FAILED self-test.
perturb() {
    # <src> <python-regex> <replacement> <dest>; prints the count.
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import re
import sys
src, pat, repl, dest = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
out, n = re.subn(pat, repl.replace("\\", "\\\\"), text, count=1)
open(dest, "w", encoding="utf-8").write(out)
print(n)
PY
}

applied() {
    # <count> <what>: the count is PRINTED, because "the negative passed"
    # and "it never touched the file" look identical otherwise.
    echo "check-table-tier: self-test — $2 applied (${1:-0} substitution)"
    if [ "${1:-0}" -lt 1 ]; then
        echo "check-table-tier: SELF-TEST BROKEN — $2 changed nothing." \
            "The pattern no longer matches the file, so the red below would" \
            "have been a green about an unperturbed copy." >&2
        exit 1
    fi
}

refuses() {
    # <doctored-swift> <expected-substring> <what>
    local out
    if out="$(check "$1")"; then
        echo "check-table-tier: SELF-TEST FAILED — $3 was ACCEPTED." >&2
        exit 1
    fi
    if ! grep -qF "$2" <<<"$out"; then
        echo "check-table-tier: SELF-TEST FAILED — $3 was refused, but not for the" \
            "stated reason. Wanted a sentence containing:" >&2
        echo "  $2" >&2
        echo "got:" >&2
        echo "$out" >&2
        exit 1
    fi
    echo "check-table-tier: self-test — $3 refused, as demanded"
}

hits="$(perturb "$SWIFTUI" 'struct KayaFlex: Layout \{' \
    'let kayaEscapedTier = KayaNativeTable(node: node)
struct KayaFlex: Layout {' "$T/escaped-tier.swift")"
applied "$hits" "a tier view constructed outside the routing"
refuses "$T/escaped-tier.swift" "is constructed outside" \
    "a second construction site for the native tier"

hits="$(perturb "$SWIFTUI" '    var widthClass: KayaTableWidth \{' \
    '    var escapedTier: some View { KayaNativeTable(node: node) }
    var widthClass: KayaTableWidth {' "$T/escaped-in-surface.swift")"
applied "$hits" "a tier view constructed in the surface but outside its body"
refuses "$T/escaped-in-surface.swift" "but outside its \`body\`" \
    "a second construction site beside the routing"

hits="$(perturb "$SWIFTUI" 'switch kayaTableTier\(width: widthClass, dynamicColumns: true\)' \
    'switch KayaTableTier.native' "$T/unconsulted.swift")"
applied "$hits" "the body deciding without the rule"
refuses "$T/unconsulted.swift" "never calls \`kayaTableTier\`" \
    "a body that routes without consulting the rule"

hits="$(perturb "$SWIFTUI" 'case \.native: KayaNativeTable\(node: node\)' \
    'case .native:
                if horizontalSizeClass == .compact {
                    KayaSynthesizedTable(node: node)
                } else {
                    KayaNativeTable(node: node)
                }' "$T/rederived.swift")"
applied "$hits" "a second size-class reading in the body"
refuses "$T/rederived.swift" "outside \`widthClass\`" \
    "a body that re-derives the tier from the environment"

hits="$(perturb "$SWIFTUI" 'return kayaTableWidth\(sizeClass: horizontalSizeClass\)' \
    'return .regular' "$T/ios-arm.swift")"
applied "$hits" "the iOS arm of widthClass deriving a width of its own"
refuses "$T/ios-arm.swift" "the non-macOS arm of \`widthClass\`" \
    "the one arm no host here executes, answering something else"

hits="$(perturb "$SWIFTUI" '    var widthClass: KayaTableWidth \{' \
    '    var isCompactPhone: Bool { horizontalSizeClass == .compact }
    var widthClass: KayaTableWidth {' "$T/second-reading.swift")"
applied "$hits" "a second reading of the size class in the surface"
refuses "$T/second-reading.swift" "outside \`widthClass\`" \
    "a second reading of the environment beside the mapped one"

hits="$(perturb "$SWIFTUI" 'does not compile\.\n            KayaSynthesizedTable\(node: node\)' \
    'does not compile.
            KayaNativeTable(node: node)' "$T/below-floor-native.swift")"
applied "$hits" "the below-floor branch taking the native tier"
refuses "$T/below-floor-native.swift" "the below-floor branch of KayaTableSurface's body" \
    "a below-floor branch that disagrees with the rule"

hits="$(perturb "$SWIFTUI" 'if #available\(macOS 14\.4, iOS 17\.4, \*\) \{
            switch kayaTableTier' \
    'if true {
            switch kayaTableTier' "$T/no-floor.swift")"
applied "$hits" "the availability check removed from the routing"
refuses "$T/no-floor.swift" "body has no \`if #available" \
    "a routing whose availability floor this gate can no longer see"

hits="$(perturb "$SWIFTUI" 'guard dynamicColumns else \{ return \.synthesized \}' \
    '#if os(macOS)
        return .native
    #endif
    guard dynamicColumns else { return .synthesized }' "$T/per-platform.swift")"
applied "$hits" "a per-platform arm inside the rule"
refuses "$T/per-platform.swift" "must be one function on both platforms" \
    "a rule the mac probe could not drive"

hits="$(perturb "$SWIFTUI" 'struct KayaTableSurface: View \{' \
    'struct KayaTableSurfaceRenamed: View {' "$T/renamed.swift")"
applied "$hits" "the surface renamed out from under the gate"
refuses "$T/renamed.swift" "no \`struct KayaTableSurface: View\`" \
    "a surface this gate can no longer find"

# --- Clause A on the real file. --------------------------------------
if ! offenders="$(check "$SWIFTUI")"; then
    echo "$offenders"
    echo "check-table-tier: FAIL — the routing is not where this gate holds it." >&2
    exit 1
fi
echo "$offenders"

# --- Clause B: the rule driven for real, where a GUI toolkit exists. --
if [ "$(uname -s)" != "Darwin" ]; then
    echo "check-table-tier: OK (static clause; the truth table needs macOS and was SKIPPED)"
    exit 0
fi

# shellcheck source=tools/lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"
if [ ! -f target/debug/libkaya.dylib ]; then
    echo "check-table-tier: target/debug/libkaya.dylib is not built — the probe" \
        "links against it. Run tools/gates.sh, which builds what its gates read." >&2
    exit 1
fi

build_probe() {
    # <interpreter-source> <out>. The probe compiles the interpreter's
    # OWN source, so there is no interpreter artifact in this path to go
    # stale.
    kaya_swiftc \
        -import-objc-header crates/kaya/include/kaya.h \
        "$1" "$PROBE" \
        -L target/debug -lkaya \
        -framework AppKit -framework Foundation \
        -o "$2"
}

if ! build_probe "$SWIFTUI" "$T/table-tier"; then
    echo "check-table-tier: the tier probe did not compile" >&2
    exit 1
fi
DYLD_LIBRARY_PATH="$ROOT/target/debug" "$T/table-tier"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "check-table-tier: FAIL — the tier probe exited $rc (its own output names" >&2
    echo "  the cell that disagreed)." >&2
    exit 1
fi

# The runtime clause guards itself: the compact arm flipped on a COPY
# must red the probe, and the perturbation must be PROVEN applied. This
# is the arm no device can assert and the one the traps entry is about.
hits="$(perturb "$SWIFTUI" 'case \.compact, \.unknown: return \.synthesized' \
    'case .compact, .unknown: return .native' "$T/compact-native.swift")"
applied "$hits" "the compact arm flipped to the native tier"
if ! build_probe "$T/compact-native.swift" "$T/table-tier-doctored"; then
    echo "check-table-tier: SELF-TEST BROKEN — the doctored interpreter did not" \
        "compile, so the runtime negative proved nothing" >&2
    exit 1
fi
DYLD_LIBRARY_PATH="$ROOT/target/debug" "$T/table-tier-doctored" > "$T/doctored.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "check-table-tier: SELF-TEST FAILED — a compact iOS host routed to the" \
        "NATIVE tier and the probe still passed. The truth table is not being" \
        "driven; nothing above is a measurement." >&2
    cat "$T/doctored.out" >&2
    exit 1
fi
if ! grep -qF "iOS compact at/above the floor" "$T/doctored.out"; then
    echo "check-table-tier: SELF-TEST FAILED — the doctored rule was refused, but" \
        "not by the compact cell. Wanted a line naming 'iOS compact at/above the" \
        "floor'; got:" >&2
    cat "$T/doctored.out" >&2
    exit 1
fi
echo "check-table-tier: self-test — the flipped compact arm reds the probe (exit $rc)"

echo "check-table-tier: OK"
