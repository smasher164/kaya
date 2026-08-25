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


def harness_case(name, next_name):
    """Code between two adjacent harness cases, or None with a loud census red."""
    needle = f'case "{name}":'
    following = f'case "{next_name}":'
    count = raw.count(needle)
    print(f"check-table-tier: harness case {name} found {count} time(s)")
    if count != 1:
        bad.append(f"{path}: wanted exactly one `{needle}`, found {count}. The table "
                   "geometry clause has no trustworthy harness arm to inspect.")
        return None
    start = raw.index(needle)
    end = raw.find(following, start + len(needle))
    if end < 0:
        bad.append(f"{path}: `{needle}` is not followed by `{following}`. The table "
                   "geometry clause moved, so this reader would inspect the wrong arm.")
        return None
    return strip(raw[start:end])


edges_case = harness_case("expect_column_edges", "header_click")
if edges_case is not None:
    required = (
        "kayaCurrentTableGeometry(node)",
        "kayaCurrentTableTrackWidth(node)",
        "kayaTableColumnAlignment(columns)",
        "kayaTableColumnRepresentativesIncrease(representatives)",
        "kayaTableViewportMatchesTrack(viewport, track: track)",
        "kayaTableFramesFitHorizontally(frames, inside: viewport)",
    )
    if any(item not in edges_case for item in required):
        bad.append(f"{path}: expect_column_edges must read current cell geometry, compare "
                   "the recorded table-track WIDTH, and contain the cells in the global "
                   "viewport. One of those three calls is absent from its own harness arm.")

track_match = braced(text, r"func kayaTableViewportMatchesTrack\s*\(")
if track_match is None:
    bad.append(f"{path}: no `func kayaTableViewportMatchesTrack(` — the table-track "
               "comparison is not a pure predicate the runtime probe can drive.")
elif "abs(Double(viewport.width) - track) <= tolerance" not in text[track_match[0]:track_match[1]]:
    bad.append(f"{path}: kayaTableViewportMatchesTrack must reject BOTH a viewport "
               "narrower than its assigned track and one wider than it. A one-sided "
               "comparison accepts the horizontally clipped native-table shape.")

generation_match = braced(text, r"func kayaTableGeometryGeneration\s*\(")
if generation_match is None:
    bad.append(f"{path}: no `func kayaTableGeometryGeneration(` — current geometry "
               "has no generation wall this gate can inspect.")
else:
    generation = text[generation_match[0]:generation_match[1]]
    if "table.tableGeometryEpoch" not in generation:
        bad.append(f"{path}: kayaTableGeometryGeneration must READ tableGeometryEpoch and "
                   "return it. A generation derived from the model accepts a coherent old "
                   "viewport after a layout-only change and after a sibling-only "
                   "transaction, neither of which touches the table's own subtree.")
    # …and it must be that READ, not a walk that happens to include it. The
    # walk this replaces was 41% of the mac main thread at 100k rows
    # (docs/measurements/choke-macos-2026-08-24.txt note 2) and it is a
    # SwiftUI body, so it ran per evaluation.
    for hazard in ("Hasher", "for ", "func ", "while ", "map(", "reduce("):
        if hazard in generation:
            bad.append(f"{path}: kayaTableGeometryGeneration's body contains `{hazard}`. "
                       "The generation is a STORED epoch read, never a walk: this runs "
                       "inside every table body evaluation, and the recursive subtree "
                       "hash it replaces hashed ~500k nodes per evaluation.")

user_write = braced(text, r"func kayaUserWrite\s*\(")
if user_write is None:
    bad.append(f"{path}: no `func kayaUserWrite(` — the user route's model writes have "
               "no funnel, so a checkbox flip or a keystroke leaves the previous table "
               "viewport, cells and track mutually consistent and readable.")
else:
    funnel = text[user_write[0]:user_write[1]]
    invalidation_call = "kayaInvalidateTableGeometry()"
    write_call = "write()"
    if (invalidation_call not in funnel or write_call not in funnel
            or funnel.index(invalidation_call) > funnel.index(write_call)):
        bad.append(f"{path}: kayaUserWrite must invalidate table geometry BEFORE running "
                   "the write, exactly as kayaApply and kayaSetWindowContentSize do. A "
                   "model change nobody staled is a coherent old snapshot the next "
                   "expect can pass against.")

# EVERY model write is in one of three places. The interpreter's own
# mutable model state is `text`, `checked` and `value`; each assignment to
# one is inside the batch path, inside the user-route funnel, or named
# here with the reason it is neither.
EXEMPT = {
    "group.value =": "KayaMenuItemModel's radio mirror — a menu item is chrome, not a "
                     "widget, and carries no table geometry",
    "view.text =": "UITextView's own text — the platform control kaya pushes the model "
                   "INTO, the opposite direction",
}
apply_span = braced(text, r"private func kayaApply\s*\(")
funnels = []
for m in re.finditer(r"kayaUserWrite\s*\{", text):
    i = text.find("{", m.end() - 1)
    j = span(text, i) if i >= 0 else None
    if j is not None:
        funnels.append((i, j))
print(f"check-table-tier: kayaUserWrite call sites found {len(funnels)}")
writes = list(re.finditer(r"[\w\.\[\]\)]+\.(?:text|checked|value)\s*=(?!=)", text))
print(f"check-table-tier: model-write sites found {len(writes)}")
if len(writes) < 12:
    bad.append(f"{path}: only {len(writes)} model-write site(s) found. This census reads "
               "the assignments the interpreter makes to `text`, `checked` and `value`; a "
               "reader that finds almost none agrees with everything.")
exempt_hits = {key: 0 for key in EXEMPT}
for m in writes:
    inside_apply = apply_span is not None and apply_span[0] <= m.start() < apply_span[1]
    inside_funnel = any(lo <= m.start() < hi for lo, hi in funnels)
    if inside_apply or inside_funnel:
        continue
    exempt = next((key for key in EXEMPT if m.group(0).startswith(key.split()[0])), None)
    if exempt is not None:
        exempt_hits[exempt] += 1
        continue
    bad.append(f"{path}:{line_of(m.start())}: `{m.group(0)}` writes the model outside "
               "kayaApply and outside a kayaUserWrite block. A write nobody staled leaves "
               "the previous table viewport, cells and track mutually consistent, and the "
               "next expect passes against a snapshot of the state before the write.")
for key, hits in exempt_hits.items():
    print(f"check-table-tier: model-write exemption `{key}` matched {hits} time(s)")
    if hits == 0:
        bad.append(f"{path}: the model-write exemption `{key}` ({EXEMPT[key]}) matches "
                   "nothing any more. An exemption for a site that no longer exists is a "
                   "hole held open for whatever takes that name next.")

track_match = braced(text, r"func kayaCurrentTableTrackWidth\s*\(")
if track_match is None:
    bad.append(f"{path}: no `func kayaCurrentTableTrackWidth(` — expect_column_edges "
               "can only read the unversioned flex-track cache.")
else:
    current_track = text[track_match[0]:track_match[1]]
    required = (
        "kayaTableGeometryGeneration(table)",
        "observation.generation == generation",
        "observation.size.width > 0",
    )
    if any(item not in current_track for item in required):
        bad.append(f"{path}: kayaCurrentTableTrackWidth must accept only a positive track "
                   "tagged with the table's current geometry generation. An old track can "
                   "agree with a clipped viewport after a layout-only change.")

track_reader = braced(text, r"private struct KayaTrackReader\s*:\s*View\b")
if track_reader is None:
    bad.append(f"{path}: no `private struct KayaTrackReader: View` — the tagged table "
               "track and its same-size republish task moved outside this gate's view.")
else:
    reader = text[track_reader[0]:track_reader[1]]
    required = (
        "let tableGeneration: Int?",
        ".task(id: tableGeneration)",
        "generation: tableGeneration",
    )
    if any(item not in reader for item in required):
        bad.append(f"{path}: KayaTrackReader must tag table tracks and republish from a "
                   "task keyed by tableGeneration. A same-size invalidation changes no "
                   "frame, so onChange(of: geo.size) cannot refill the current track.")

track_handoff = (
    "tableGeneration: child.tableColumns.isEmpty\n"
    "                                        ? nil : kayaTableGeometryGeneration(child)"
)
track_handoff_count = raw.count(track_handoff)
print(f"check-table-tier: table-generation track handoff found {track_handoff_count} time(s)")
if track_handoff_count != 2:
    bad.append(f"{path}: wanted the table-generation handoff at both KayaTrackReader "
               f"construction sites, found {track_handoff_count}. The vertical and "
               "horizontal flex paths must tag the same observation.")

invalidation_match = braced(text, r"func kayaInvalidateTableGeometry\s*\(")
if invalidation_match is None:
    bad.append(f"{path}: no `func kayaInvalidateTableGeometry(` — layout-only changes "
               "cannot synchronously make the prior table observations stale.")
else:
    invalidation = text[invalidation_match[0]:invalidation_match[1]]
    if "kayaScene.columns" not in invalidation or "table.tableGeometryEpoch &+= 1" not in invalidation:
        bad.append(f"{path}: kayaInvalidateTableGeometry must bump every live declared "
                   "table's geometry epoch. Clearing frames without a new reporter task id "
                   "can leave them missing forever when the frame is unchanged.")

resize_helper = braced(text, r"func kayaSetWindowContentSize\s*\(")
if resize_helper is None:
    bad.append(f"{path}: no `func kayaSetWindowContentSize(` — native content-size "
               "changes can bypass the synchronous table-geometry invalidation.")
else:
    helper = text[resize_helper[0]:resize_helper[1]]
    invalidation_call = "kayaInvalidateTableGeometry()"
    native_call = "window.setContentSize(size)"
    if (invalidation_call not in helper or native_call not in helper
            or helper.index(invalidation_call) > helper.index(native_call)):
        bad.append(f"{path}: kayaSetWindowContentSize must invalidate table geometry "
                   "before NSWindow.setContentSize. A main-queue hop is not a completed "
                   "SwiftUI layout turn.")
direct_size_calls = text.count(".setContentSize(")
print(f"check-table-tier: native setContentSize callsites found {direct_size_calls} time(s)")
if direct_size_calls != 1:
    bad.append(f"{path}: wanted exactly one native setContentSize call inside the "
               f"invalidation helper, found {direct_size_calls}. Every direct call is a "
               "route that can retain a coherent old table snapshot.")

apply_match = braced(text, r"private func kayaApply\s*\(")
if apply_match is None:
    bad.append(f"{path}: no `private func kayaApply(` — the transaction-boundary "
               "geometry invalidation route moved outside this gate's view.")
else:
    apply_body = text[apply_match[0]:apply_match[1]]
    call = "kayaInvalidateTableGeometry()"
    boundary = "batch.withUnsafeBytes"
    if call not in apply_body or boundary not in apply_body or apply_body.index(call) > apply_body.index(boundary):
        bad.append(f"{path}: kayaApply must invalidate table geometry before reading the "
                   "batch. A sibling or ancestor can move a table without changing the "
                   "table subtree hashed by the model generation.")

resize_case = harness_case("resize_window", "expect_sections_presentation")
if resize_case is not None:
    if "kayaSetWindowContentSize(" not in resize_case:
        bad.append(f"{path}: resize_window must route through "
                   "kayaSetWindowContentSize. Otherwise the immediately following expect "
                   "can accept the old green viewport, cells, and track without yielding "
                   "for layout.")

fills_case = harness_case("expect_fills", "expect_menus")
if fills_case is not None:
    required = (
        "kayaCurrentTableGeometry(container)",
        "kayaTableFramesFitVertically(rows, inside: viewport)",
        ".missingViewport",
        ".partialRow",
        ".unrealized",
    )
    if any(item not in fills_case for item in required):
        bad.append(f"{path}: expect_fills' table arm must refuse absent geometry, a "
                   "PARTIALLY recorded row and rows a tier owes but has not realized, and "
                   "contain live rows vertically in the recorded viewport; vertical slack "
                   "remains valid. One of those checks is absent from the arm.")

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
# Perturbations are applied to COPIES; the substitution count AND THE
# SITE are printed, and every negative NAMES the declaration it must land
# in. A count alone cannot tell two perturbations apart: the chained
# shadow's "stale cell generations" negative spent a milestone re-hitting
# kayaCurrentTableTrackWidth — the same line the standalone unversioned-
# track negative already perturbs — because its pattern had no trailing
# comma and re.subn(count=1) takes the first match. It printed "1", the
# honesty check passed, and the cell filter it was named for was never
# touched (the review of 01dd633).
perturb() {
    # <src> <python-regex> <replacement> <dest>; prints
    # "<count> <line> <enclosing declarations>".
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import re
import sys

src, pat, repl, dest = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
match = re.compile(pat).search(text)
out, n = re.subn(pat, repl.replace("\\", "\\\\"), text, count=1)
open(dest, "w", encoding="utf-8").write(out)

# Scope-introducing declarations only: a `let` binding two lines up names
# nothing a second perturbation could not also sit under.
DECLS = (
    re.compile(r"^(\s*)(?:@[\w.]+(?:\([^)]*\))?\s+)*"
               r"(?:(?:public|private|internal|fileprivate|open|static|final"
               r"|override|mutating|nonisolated|convenience|required)\s+)*"
               r"(func|struct|class|enum|extension|protocol|init|subscript)"
               r"\s+(`?\w+`?)"),
    re.compile(r"^(\s*)(?:(?:public|private|internal|fileprivate|static)\s+)*"
               r"(var|let)\s+(\w+)\s*:[^=]*\{\s*$"),
    re.compile(r'^(\s*)(case)\s+("[^"]*")\s*:'),
)


def named(raw):
    for decl in DECLS:
        m = decl.match(raw)
        if m:
            return f"{m.group(2)} {m.group(3)}"
    return None


def site(offset):
    before = text[:offset].split("\n")
    start = len(text[:offset]) - len(before[-1])
    here = text[start:text.find("\n", start)]
    # The INDENT OF THE LINE, not of the match: a pattern that carries its
    # own leading whitespace starts at column 0 and would otherwise close
    # the walk before it began.
    limit = len(here) - len(here.lstrip())
    chain = []
    if named(here):
        chain.append(named(here))
    for raw in reversed(before[:-1]):
        if not raw.strip():
            continue
        indent = len(raw) - len(raw.lstrip())
        if indent >= limit:
            continue
        name = named(raw)
        if name:
            chain.append(name)
            limit = indent
        if limit == 0:
            break
    return len(before), " > ".join(reversed(chain)) or "<file scope>"


line, where = site(match.start()) if match else (0, "<no match>")
print(n, line, where)
PY
}

applied() {
    # <perturb-output> <what> <declaration it must land in>: the count and
    # the site are both PRINTED, because "the negative passed", "it never
    # touched the file" and "it perturbed some other negative's site" look
    # identical otherwise.
    local count line where
    read -r count line where <<<"${1:-0 0 <nothing>}"
    echo "check-table-tier: self-test — $2 applied (${count:-0} substitution)" \
        "at line ${line:-?} in ${where:-<unknown>}"
    if [ "${count:-0}" -lt 1 ]; then
        echo "check-table-tier: SELF-TEST BROKEN — $2 changed nothing." \
            "The pattern no longer matches the file, so the red below would" \
            "have been a green about an unperturbed copy." >&2
        exit 1
    fi
    if [ -z "${3:-}" ]; then
        echo "check-table-tier: SELF-TEST BROKEN — $2 names no site. Every negative" \
            "names the declaration it must land in, or a count of 1 is all the" \
            "evidence there is that it landed anywhere in particular." >&2
        exit 1
    fi
    if [ "$where" != "$3" ]; then
        echo "check-table-tier: SELF-TEST BROKEN — $2 landed in '$where', not the" \
            "'$3' it names. A perturbation that lands somewhere else proves that" \
            "site twice over and its own not at all." >&2
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

GENERATION_BODY='func kayaTableGeometryGeneration\(_ table: KayaNode\) -> Int \{\n    table\.tableGeometryEpoch\n\}'

hits="$(perturb "$SWIFTUI" "$GENERATION_BODY" \
    'func kayaTableGeometryGeneration(_ table: KayaNode) -> Int {
    table.children.count
}' "$T/no-layout-epoch.swift")"
applied "$hits" "the geometry generation derived from the model instead of the epoch" \
    "func kayaTableGeometryGeneration"
refuses "$T/no-layout-epoch.swift" "must READ tableGeometryEpoch" \
    "a model-derived generation accepting a pre-layout snapshot"

hits="$(perturb "$SWIFTUI" "$GENERATION_BODY" \
    'func kayaTableGeometryGeneration(_ table: KayaNode) -> Int {
    var hasher = Hasher()
    hasher.combine(table.tableGeometryEpoch)
    for child in table.children { hasher.combine(child.text) }
    return hasher.finalize()
}' "$T/walked-generation.swift")"
applied "$hits" "the geometry generation walking the subtree again" \
    "func kayaTableGeometryGeneration"
refuses "$T/walked-generation.swift" "is a STORED epoch read, never a walk" \
    "a generation re-hashing the subtree on every body evaluation"

hits="$(perturb "$SWIFTUI" \
    'func kayaUserWrite\(_ write: \(\) -> Void\) \{\n    kayaInvalidateTableGeometry\(\)\n' \
    'func kayaUserWrite(_ write: () -> Void) {
' "$T/unstaled-user-write.swift")"
applied "$hits" "the user-route funnel's invalidation removed" \
    "func kayaUserWrite"
refuses "$T/unstaled-user-write.swift" "kayaUserWrite must invalidate table geometry BEFORE" \
    "a user-route model write that stales nothing"

hits="$(perturb "$SWIFTUI" 'kayaUserWrite \{ node\.checked = newValue \}' \
    'node.checked = newValue' "$T/unfunnelled-write.swift")"
applied "$hits" "a user-route model write moved out of the funnel" \
    "struct KayaRender > var body"
refuses "$T/unfunnelled-write.swift" "writes the model outside" \
    "a model write no path staled"

hits="$(perturb "$SWIFTUI" '        table\.tableGeometryEpoch &\+= 1\n' \
    '' "$T/no-layout-invalidation.swift")"
applied "$hits" "the live-table layout invalidation removed" \
    "func kayaInvalidateTableGeometry"
refuses "$T/no-layout-invalidation.swift" "must bump every live declared" \
    "an invalidator that changes no reporter task id"

hits="$(perturb "$SWIFTUI" \
    'private func kayaApply\(_ batch: Data, _ blobs: \[UInt64: Data\]\) \{\n    kayaInvalidateTableGeometry\(\)' \
    'private func kayaApply(_ batch: Data, _ blobs: [UInt64: Data]) {' \
    "$T/no-apply-invalidation.swift")"
applied "$hits" "the transaction-boundary layout invalidation removed" \
    "func kayaApply"
refuses "$T/no-apply-invalidation.swift" "kayaApply must invalidate table geometry" \
    "a sibling mutation retaining old table geometry"

hits="$(perturb "$SWIFTUI" \
    'func kayaSetWindowContentSize\(_ window: NSWindow, _ size: NSSize\) \{\n    kayaInvalidateTableGeometry\(\)' \
    'func kayaSetWindowContentSize(_ window: NSWindow, _ size: NSSize) {' \
    "$T/no-resize-helper-invalidation.swift")"
applied "$hits" "the native resize helper invalidation removed" \
    "func kayaSetWindowContentSize"
refuses "$T/no-resize-helper-invalidation.swift" \
    "kayaSetWindowContentSize must invalidate table geometry" \
    "a native content-size change retaining the previous snapshot"

hits="$(perturb "$SWIFTUI" \
    'kayaSetWindowContentSize\(\n                                window, NSSize\(width: rw, height: rh\)\)' \
    'window.setContentSize(NSSize(width: rw, height: rh))' \
    "$T/no-resize-invalidation.swift")"
applied "$hits" "the resize harness bypassed the invalidating helper" \
    "func kayaRunScript > case \"resize_window\""
refuses "$T/no-resize-invalidation.swift" "resize_window must route through" \
    "resize_window accepting the previous green snapshot"

hits="$(perturb "$SWIFTUI" 'observation\.generation == generation,' \
    'true,' "$T/unversioned-table-track.swift")"
applied "$hits" "the table-track generation check bypassed" \
    "func kayaCurrentTableTrackWidth"
refuses "$T/unversioned-table-track.swift" "must accept only a positive track" \
    "an old assigned track accepted as current"

hits="$(perturb "$SWIFTUI" '\.task\(id: tableGeneration\)' \
    '.task(id: 0)' "$T/unkeyed-table-track-task.swift")"
applied "$hits" "the table-track republish task keyed to a constant" \
    "struct KayaTrackReader > var body"
refuses "$T/unkeyed-table-track-task.swift" "must tag table tracks and republish" \
    "a same-size invalidation unable to refresh its track"

hits="$(perturb "$SWIFTUI" \
    'tableGeneration: child\.tableColumns\.isEmpty\n                                        \? nil : kayaTableGeometryGeneration\(child\)' \
    'tableGeneration: nil' "$T/untagged-flex-track.swift")"
applied "$hits" "one flex path stopped handing table generations to its track reader" \
    "struct KayaRender > var body"
refuses "$T/untagged-flex-track.swift" "wanted the table-generation handoff" \
    "one flex orientation recording untagged table tracks"

hits="$(perturb "$SWIFTUI" 'struct KayaFlex: Layout \{' \
    'let kayaEscapedTier = KayaNativeTable(node: node)
struct KayaFlex: Layout {' "$T/escaped-tier.swift")"
applied "$hits" "a tier view constructed outside the routing" \
    "struct KayaFlex"
refuses "$T/escaped-tier.swift" "is constructed outside" \
    "a second construction site for the native tier"

hits="$(perturb "$SWIFTUI" 'kayaCurrentTableTrackWidth\(node\)' \
    'kayaMainExtents[node.id]' "$T/edge-main-axis.swift")"
applied "$hits" "the table width replaced by its parent main-axis extent" \
    "func kayaRunScript > case \"expect_column_edges\""
refuses "$T/edge-main-axis.swift" "expect_column_edges must read current cell geometry" \
    "column-edge containment reading height as width"

hits="$(perturb "$SWIFTUI" 'abs\(Double\(viewport\.width\) - track\) <= tolerance' \
    'Double(viewport.width) >= track - tolerance' "$T/one-sided-track.swift")"
applied "$hits" "the table-track comparison made one-sided" \
    "func kayaTableViewportMatchesTrack"
refuses "$T/one-sided-track.swift" "must reject BOTH a viewport" \
    "an oversized native table accepted inside a narrower assigned track"

hits="$(perturb "$SWIFTUI" 'kayaTableFramesFitVertically\(rows, inside: viewport\)' \
    'kayaTableFramesFitHorizontally(rows, inside: viewport)' "$T/fills-horizontal.swift")"
applied "$hits" "expect_fills checking rows on the horizontal axis" \
    "func kayaRunScript > case \"expect_fills\""
refuses "$T/fills-horizontal.swift" "expect_fills' table arm must refuse" \
    "table fill accepting vertical row overflow"

hits="$(perturb "$SWIFTUI" '    var widthClass: KayaTableWidth \{' \
    '    var escapedTier: some View { KayaNativeTable(node: node) }
    var widthClass: KayaTableWidth {' "$T/escaped-in-surface.swift")"
applied "$hits" "a tier view constructed in the surface but outside its body" \
    "struct KayaTableSurface > var widthClass"
refuses "$T/escaped-in-surface.swift" "but outside its \`body\`" \
    "a second construction site beside the routing"

hits="$(perturb "$SWIFTUI" 'switch kayaTableTier\(width: widthClass, dynamicColumns: true\)' \
    'switch KayaTableTier.native' "$T/unconsulted.swift")"
applied "$hits" "the body deciding without the rule" \
    "struct KayaTableSurface > var body"
refuses "$T/unconsulted.swift" "never calls \`kayaTableTier\`" \
    "a body that routes without consulting the rule"

hits="$(perturb "$SWIFTUI" 'case \.native: KayaNativeTable\(node: node\)' \
    'case .native:
                if horizontalSizeClass == .compact {
                    KayaSynthesizedTable(node: node)
                } else {
                    KayaNativeTable(node: node)
                }' "$T/rederived.swift")"
applied "$hits" "a second size-class reading in the body" \
    "struct KayaTableSurface > var body"
refuses "$T/rederived.swift" "outside \`widthClass\`" \
    "a body that re-derives the tier from the environment"

hits="$(perturb "$SWIFTUI" 'return kayaTableWidth\(sizeClass: horizontalSizeClass\)' \
    'return .regular' "$T/ios-arm.swift")"
applied "$hits" "the iOS arm of widthClass deriving a width of its own" \
    "struct KayaTableSurface > var widthClass"
refuses "$T/ios-arm.swift" "the non-macOS arm of \`widthClass\`" \
    "the one arm no host here executes, answering something else"

hits="$(perturb "$SWIFTUI" '    var widthClass: KayaTableWidth \{' \
    '    var isCompactPhone: Bool { horizontalSizeClass == .compact }
    var widthClass: KayaTableWidth {' "$T/second-reading.swift")"
applied "$hits" "a second reading of the size class in the surface" \
    "struct KayaTableSurface > var widthClass"
refuses "$T/second-reading.swift" "outside \`widthClass\`" \
    "a second reading of the environment beside the mapped one"

hits="$(perturb "$SWIFTUI" 'does not compile\.\n            KayaSynthesizedTable\(node: node\)' \
    'does not compile.
            KayaNativeTable(node: node)' "$T/below-floor-native.swift")"
applied "$hits" "the below-floor branch taking the native tier" \
    "struct KayaTableSurface > var body"
refuses "$T/below-floor-native.swift" "the below-floor branch of KayaTableSurface's body" \
    "a below-floor branch that disagrees with the rule"

hits="$(perturb "$SWIFTUI" 'if #available\(macOS 14\.4, iOS 17\.4, \*\) \{
            switch kayaTableTier' \
    'if true {
            switch kayaTableTier' "$T/no-floor.swift")"
applied "$hits" "the availability check removed from the routing" \
    "struct KayaTableSurface > var body"
refuses "$T/no-floor.swift" "body has no \`if #available" \
    "a routing whose availability floor this gate can no longer see"

hits="$(perturb "$SWIFTUI" 'guard dynamicColumns else \{ return \.synthesized \}' \
    '#if os(macOS)
        return .native
    #endif
    guard dynamicColumns else { return .synthesized }' "$T/per-platform.swift")"
applied "$hits" "a per-platform arm inside the rule" \
    "func kayaTableTier"
refuses "$T/per-platform.swift" "must be one function on both platforms" \
    "a rule the mac probe could not drive"

hits="$(perturb "$SWIFTUI" 'struct KayaTableSurface: View \{' \
    'struct KayaTableSurfaceRenamed: View {' "$T/renamed.swift")"
applied "$hits" "the surface renamed out from under the gate" \
    "struct KayaTableSurface"
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

runtime_refuses() {
    # <doctored-source> <binary-name> <diagnostic> <what>
    local source binary diagnostic what rc
    source="$1"
    binary="$2"
    diagnostic="$3"
    what="$4"
    if ! build_probe "$source" "$T/$binary"; then
        echo "check-table-tier: SELF-TEST BROKEN — $what did not compile" >&2
        exit 1
    fi
    DYLD_LIBRARY_PATH="$ROOT/target/debug" "$T/$binary" > "$T/$binary.out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "check-table-tier: SELF-TEST FAILED — $what was accepted" >&2
        cat "$T/$binary.out" >&2
        exit 1
    fi
    if ! grep -qF "$diagnostic" "$T/$binary.out"; then
        echo "check-table-tier: SELF-TEST FAILED — $what reddened without naming" \
            "'$diagnostic'. Got:" >&2
        cat "$T/$binary.out" >&2
        exit 1
    fi
    echo "check-table-tier: self-test — $what reds the real-window probe (exit $rc)"
}

runtime_refuses "$T/no-layout-epoch.swift" "no-layout-epoch" \
    "a layout invalidation rejects the previous generation" \
    "a model-derived table geometry generation"
runtime_refuses "$T/unstaled-user-write.swift" "unstaled-user-write" \
    "a user-route model write immediately refuses the previous generation" \
    "a user-route model write that stales nothing"
runtime_refuses "$T/no-resize-helper-invalidation.swift" "no-resize-helper-invalidation" \
    "a resize never accepts the previous generation" \
    "a resize helper that does not invalidate table geometry"
runtime_refuses "$T/unversioned-table-track.swift" "unversioned-table-track" \
    "a layout invalidation rejects the previous track" \
    "an unversioned assigned table track"
runtime_refuses "$T/unkeyed-table-track-task.swift" "unkeyed-table-track-task" \
    "a same-size layout invalidation republishes geometry and track" \
    "a table-track task that cannot republish at the same size"

# Geometry guards share this watched shadow; every perturbation's count
# is printed before the one doctored interpreter is compiled.
hits="$(perturb "$SWIFTUI" 'abs\(Double\(viewport\.width\) - track\) <= tolerance' \
    'Double(viewport.width) >= track - tolerance' "$T/overflowing-track.swift")"
applied "$hits" "an oversized table viewport accepted against its track" \
    "func kayaTableViewportMatchesTrack"
hits="$(perturb "$T/overflowing-track.swift" 'edge - representative <= tolerance' \
    'edge - representative <= tolerance * 2' "$T/chained-clusters.swift")"
applied "$hits" "representative edge clustering replaced by a drift chain" \
    "func kayaTableEdgeClusters"
hits="$(perturb "$T/chained-clusters.swift" 'guard clusters\.count == 1 else \{' \
    'guard !clusters.isEmpty else {' "$T/unkeyed-columns.swift")"
applied "$hits" "a column borrowing another column's cluster accepted" \
    "func kayaTableColumnAlignment"
hits="$(perturb "$T/unkeyed-columns.swift" \
    'if next - previous <= tolerance \{ return false \}' \
    'if next == previous { return false }' "$T/unordered-columns.swift")"
applied "$hits" "descending column representatives accepted" \
    "func kayaTableColumnRepresentativesIncrease"
hits="$(perturb "$T/unordered-columns.swift" 'let frame = geo\.frame\(in: \.global\)' \
    'let frame = geo.frame(in: .global).offsetBy(dx: 1000, dy: 1000)' \
    "$T/displaced-cells.swift")"
applied "$hits" "live cell geometry displaced outside its viewport" \
    "struct KayaEdgeReporter > var body"
# The ROW-CELL filter, anchored on the lookup above it: the bare
# `observation.generation == generation` matches the TRACK filter first,
# which the standalone unversioned-table-track negative already owns.
hits="$(perturb "$T/displaced-cells.swift" \
    'if let observation = table\.tableCellFrames\[key\],\n                observation\.generation == generation\n' \
    'if let observation = table.tableCellFrames[key],
                observation.generation == generation || true
' "$T/stale-cells.swift")"
applied "$hits" "stale cell generations accepted as current" \
    "func kayaCurrentTableGeometry"
hits="$(perturb "$T/stale-cells.swift" 'viewport\.generation == generation,' \
    'viewport.generation == generation || true,' "$T/stale-viewport.swift")"
applied "$hits" "a stale viewport generation accepted as current" \
    "func kayaCurrentTableGeometry"
hits="$(perturb "$T/stale-viewport.swift" \
    'if realized\.isEmpty, !table\.children\.isEmpty \{' \
    'if false {' "$T/incomplete-geometry.swift")"
applied "$hits" "a table with no realized row accepted as current" \
    "func kayaCurrentTableGeometry"
if ! build_probe "$T/incomplete-geometry.swift" "$T/table-geometry-doctored"; then
    echo "check-table-tier: SELF-TEST BROKEN — the doctored geometry probe did not" \
        "compile, so the runtime negative proved nothing" >&2
    exit 1
fi
DYLD_LIBRARY_PATH="$ROOT/target/debug" "$T/table-geometry-doctored" \
    > "$T/geometry-doctored.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "check-table-tier: SELF-TEST FAILED — chained clusters and displaced cells" \
        "were accepted by the real-window probe." >&2
    cat "$T/geometry-doctored.out" >&2
    exit 1
fi
for diagnostic in \
    "table track overflow is rejected" \
    "edge clustering is anchored to its representative" \
    "column identity rejects frames borrowed from an existing cluster" \
    "column representatives must remain distinct and increasing" \
    "missing current row-cell geometry is rejected" \
    "stale row-cell geometry is rejected" \
    "a user-route model write immediately refuses the previous generation" \
    "a layout invalidation rejects the previous generation" \
    "live native cells stay inside the recorded viewport horizontally" \
    "live native rows stay inside the recorded viewport vertically"
do
    if ! grep -qF "$diagnostic" "$T/geometry-doctored.out"; then
        echo "check-table-tier: SELF-TEST FAILED — the geometry shadow reddened," \
            "but did not name '$diagnostic'. Got:" >&2
        cat "$T/geometry-doctored.out" >&2
        exit 1
    fi
done
echo "check-table-tier: self-test — identity, generation, and containment guards all red (exit $rc)"

# The runtime clause guards itself: the compact arm flipped on a COPY
# must red the probe, and the perturbation must be PROVEN applied. This
# is the arm no device can assert and the one the traps entry is about.
hits="$(perturb "$SWIFTUI" 'case \.compact, \.unknown: return \.synthesized' \
    'case .compact, .unknown: return .native' "$T/compact-native.swift")"
applied "$hits" "the compact arm flipped to the native tier" \
    "func kayaTableTier"
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
