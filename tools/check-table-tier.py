#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE TABLE TIER ROUTING (docs/tables-plan.md decision 5, revised
# 2026-08-21; docs/traps.md, "An observable with no discriminator
# cannot be asserted onto a device").
#
# A table's two tiers present IDENTICAL BYTES to every harness verb —
# the size class came out of expect_columns on purpose — so no scene,
# on any device, can name the tier that drew it. Before this gate the
# only proof was a one-arm perturbation with the other device's leg
# watched staying green, redone by hand whenever the routing moved. The
# routing is a pure function now, and this is where it is held:
#
#   A  STATIC, any host: KayaTableSurface is the ONLY caller of the
#      native/synthesized split — both tier views are constructed
#      inside its body and nowhere else — and that body decides by
#      calling kayaTableTier, which reads its parameters and nothing
#      else (no environment, no #if; the mac probe below could not
#      drive the iOS arms of a rule compiled per platform). The
#      environment reaches the rule down ONE path, `widthClass`, whose
#      two one-line arms are both read here — the iOS arm most of all,
#      since it is the line no host running this gate executes.
#   B  RUNTIME, macOS only — tools/checks/swiftui-table-tier.swift
#      compiled INTO the interpreter's own module and run: the whole
#      truth table (four widths x both availabilities), the mapping
#      from the environment's own size-class type, this host's own
#      branch, and a REAL KayaTableSurface in an NSWindow with the
#      NSTableView the native tier is made of found in the view tree.
#      SKIPPED AND SAID SO on any other host.
#
# WHAT NEITHER CLAUSE HOLDS: which size class a PHYSICAL device
# reports. The simulator's answer is the only one this repo can read.

import os
import platform
import re
import subprocess

# Line-buffered stdout: the probes write to the same fd, and
# block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

g = Gate("check-table-tier")

SWIFTUI = "swift/KayaSwiftUI.swift"
PROBE = "tools/checks/swiftui-table-tier.swift"

T = g.scratch()


# --- Clause A, as one reader over the interpreter. --------------------
def check(source_text, path=SWIFTUI):
    """(stdout lines, findings) for one interpreter text — a doctored
    copy in the self-tests, the real one at the end."""
    raw = source_text
    out = []
    bad = []

    def strip(text):
        """Code only: comments and string literals blanked, newlines
        kept so offsets AND line numbers still name the real file. A
        gate that reads prose fails on documentation
        (check-empty-child learned that one)."""
        pieces, i, n = [], 0, len(text)

        def blank(s):
            return "".join("\n" if c == "\n" else " " for c in s)

        while i < n:
            c = text[i]
            if c == "/" and i + 1 < n and text[i + 1] == "/":
                j = text.find("\n", i)
                j = n if j < 0 else j
                pieces.append(blank(text[i:j]))
                i = j
                continue
            if c == "/" and i + 1 < n and text[i + 1] == "*":
                j = text.find("*/", i)
                j = n if j < 0 else j + 2
                pieces.append(blank(text[i:j]))
                i = j
                continue
            if c == '"':
                j = i + 1
                while j < n and text[j] != '"':
                    j += 2 if text[j] == "\\" else 1
                j = min(j + 1, n)
                pieces.append(blank(text[i:j]))
                i = j
                continue
            pieces.append(c)
            i += 1
        return "".join(pieces)

    def span(text, i):
        """From the brace at `i` to its match. The text is already
        stripped, so no comment or literal can close it early."""
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
        """(open, close) of the braced block following the first match
        of `pattern` inside [start, end), or None — and None is a
        FAILURE at every callsite: a reader that stopped finding what
        it reads reports a clean bill about nothing."""
        m = re.compile(pattern).search(
            text, start, len(text) if end is None else end)
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
        """Code between two adjacent harness cases, or None with a
        loud census red."""
        needle = f'case "{name}":'
        following = f'case "{next_name}":'
        count = raw.count(needle)
        out.append(f"check-table-tier: harness case {name} found "
                   f"{count} time(s)")
        if count != 1:
            bad.append(f"{path}: wanted exactly one `{needle}`, found "
                       f"{count}. The table geometry clause has no "
                       f"trustworthy harness arm to inspect.")
            return None
        start = raw.index(needle)
        end = raw.find(following, start + len(needle))
        if end < 0:
            bad.append(f"{path}: `{needle}` is not followed by "
                       f"`{following}`. The table geometry clause "
                       f"moved, so this reader would inspect the wrong "
                       f"arm.")
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
            # The reach joined this call when tables learned to scroll
            # their columns (docs/tables-plan.md, ruled 2026-08-29):
            # cells past the viewport are a defect only if they cannot
            # be reached.
            "kayaTableFramesFitHorizontally(",
        )
        if any(item not in edges_case for item in required):
            bad.append(f"{path}: expect_column_edges must read current "
                       f"cell geometry, compare the recorded "
                       f"table-track WIDTH, and contain the cells in "
                       f"the global viewport. One of those three calls "
                       f"is absent from its own harness arm.")

    track_match = braced(text, r"func kayaTableViewportMatchesTrack\s*\(")
    if track_match is None:
        bad.append(f"{path}: no `func kayaTableViewportMatchesTrack(` "
                   f"— the table-track comparison is not a pure "
                   f"predicate the runtime probe can drive.")
    elif "abs(Double(viewport.width) - track) <= tolerance" not in \
            text[track_match[0]:track_match[1]]:
        bad.append(f"{path}: kayaTableViewportMatchesTrack must reject "
                   f"BOTH a viewport narrower than its assigned track "
                   f"and one wider than it. A one-sided comparison "
                   f"accepts the horizontally clipped native-table "
                   f"shape.")

    generation_match = braced(
        text, r"func kayaTableGeometryGeneration\s*\(")
    if generation_match is None:
        bad.append(f"{path}: no `func kayaTableGeometryGeneration(` — "
                   f"current geometry has no generation wall this gate "
                   f"can inspect.")
    else:
        generation = text[generation_match[0]:generation_match[1]]
        if "table.tableGeometryEpoch" not in generation:
            bad.append(f"{path}: kayaTableGeometryGeneration must READ "
                       f"tableGeometryEpoch and return it. A "
                       f"generation derived from the model accepts a "
                       f"coherent old viewport after a layout-only "
                       f"change and after a sibling-only transaction, "
                       f"neither of which touches the table's own "
                       f"subtree.")
        # …and it must be that READ, not a walk that happens to
        # include it. The walk this replaces was 41% of the mac main
        # thread at 100k rows
        # (docs/measurements/choke-macos-2026-08-24.txt note 2) and it
        # is a SwiftUI body, so it ran per evaluation.
        for hazard in ("Hasher", "for ", "func ", "while ", "map(",
                       "reduce("):
            if hazard in generation:
                bad.append(f"{path}: kayaTableGeometryGeneration's "
                           f"body contains `{hazard}`. The generation "
                           f"is a STORED epoch read, never a walk: "
                           f"this runs inside every table body "
                           f"evaluation, and the recursive subtree "
                           f"hash it replaces hashed ~500k nodes per "
                           f"evaluation.")

    user_write = braced(text, r"func kayaUserWrite\s*\(")
    if user_write is None:
        bad.append(f"{path}: no `func kayaUserWrite(` — the user "
                   f"route's model writes have no funnel, so a "
                   f"checkbox flip or a keystroke leaves the previous "
                   f"table viewport, cells and track mutually "
                   f"consistent and readable.")
    else:
        funnel = text[user_write[0]:user_write[1]]
        invalidation_call = "kayaInvalidateTableGeometry()"
        write_call = "write()"
        if (invalidation_call not in funnel or write_call not in funnel
                or funnel.index(invalidation_call)
                > funnel.index(write_call)):
            bad.append(f"{path}: kayaUserWrite must invalidate table "
                       f"geometry BEFORE running the write, exactly as "
                       f"kayaApply and kayaSetWindowContentSize do. A "
                       f"model change nobody staled is a coherent old "
                       f"snapshot the next expect can pass against.")

    # EVERY model write is in one of three places. The interpreter's
    # own mutable model state is `text`, `checked` and `value`; each
    # assignment to one is inside the batch path, inside the
    # user-route funnel, or named here with the reason it is neither.
    EXEMPT = {
        "group.value =": "KayaMenuItemModel's radio mirror — a menu "
                         "item is chrome, not a widget, and carries no "
                         "table geometry",
        "view.text =": "UITextView's own text — the platform control "
                       "kaya pushes the model INTO, the opposite "
                       "direction",
    }
    apply_span = braced(text, r"private func kayaApply\s*\(")
    funnels = []
    for m in re.finditer(r"kayaUserWrite\s*\{", text):
        i = text.find("{", m.end() - 1)
        j = span(text, i) if i >= 0 else None
        if j is not None:
            funnels.append((i, j))
    out.append(f"check-table-tier: kayaUserWrite call sites found "
               f"{len(funnels)}")
    writes = list(re.finditer(
        r"[\w\.\[\]\)]+\.(?:text|checked|value)\s*=(?!=)", text))
    out.append(f"check-table-tier: model-write sites found "
               f"{len(writes)}")
    if len(writes) < 12:
        bad.append(f"{path}: only {len(writes)} model-write site(s) "
                   f"found. This census reads the assignments the "
                   f"interpreter makes to `text`, `checked` and "
                   f"`value`; a reader that finds almost none agrees "
                   f"with everything.")
    exempt_hits = {key: 0 for key in EXEMPT}
    for m in writes:
        inside_apply = (apply_span is not None
                        and apply_span[0] <= m.start() < apply_span[1])
        inside_funnel = any(lo <= m.start() < hi for lo, hi in funnels)
        if inside_apply or inside_funnel:
            continue
        exempt = next((key for key in EXEMPT
                       if m.group(0).startswith(key.split()[0])), None)
        if exempt is not None:
            exempt_hits[exempt] += 1
            continue
        bad.append(f"{path}:{line_of(m.start())}: `{m.group(0)}` "
                   f"writes the model outside kayaApply and outside a "
                   f"kayaUserWrite block. A write nobody staled leaves "
                   f"the previous table viewport, cells and track "
                   f"mutually consistent, and the next expect passes "
                   f"against a snapshot of the state before the "
                   f"write.")
    for key, hits in exempt_hits.items():
        out.append(f"check-table-tier: model-write exemption `{key}` "
                   f"matched {hits} time(s)")
        if hits == 0:
            bad.append(f"{path}: the model-write exemption `{key}` "
                       f"({EXEMPT[key]}) matches nothing any more. An "
                       f"exemption for a site that no longer exists is "
                       f"a hole held open for whatever takes that name "
                       f"next.")

    track_match = braced(text, r"func kayaCurrentTableTrackWidth\s*\(")
    if track_match is None:
        bad.append(f"{path}: no `func kayaCurrentTableTrackWidth(` — "
                   f"expect_column_edges can only read the unversioned "
                   f"flex-track cache.")
    else:
        current_track = text[track_match[0]:track_match[1]]
        required = (
            "kayaTableGeometryGeneration(table)",
            "observation.generation == generation",
            "observation.size.width > 0",
        )
        if any(item not in current_track for item in required):
            bad.append(f"{path}: kayaCurrentTableTrackWidth must "
                       f"accept only a positive track tagged with the "
                       f"table's current geometry generation. An old "
                       f"track can agree with a clipped viewport after "
                       f"a layout-only change.")

    track_reader = braced(text,
                          r"private struct KayaTrackReader\s*:\s*View\b")
    if track_reader is None:
        bad.append(f"{path}: no `private struct KayaTrackReader: View` "
                   f"— the tagged table track and its same-size "
                   f"republish task moved outside this gate's view.")
    else:
        reader = text[track_reader[0]:track_reader[1]]
        required = (
            "let tableGeneration: Int?",
            ".task(id: tableGeneration)",
            "generation: tableGeneration",
        )
        if any(item not in reader for item in required):
            bad.append(f"{path}: KayaTrackReader must tag table tracks "
                       f"and republish from a task keyed by "
                       f"tableGeneration. A same-size invalidation "
                       f"changes no frame, so onChange(of: geo.size) "
                       f"cannot refill the current track.")

    track_handoff = (
        "tableGeneration: child.tableColumns.isEmpty\n"
        "                                        "
        "? nil : kayaTableGeometryGeneration(child)")
    track_handoff_count = raw.count(track_handoff)
    out.append(f"check-table-tier: table-generation track handoff "
               f"found {track_handoff_count} time(s)")
    # ONE site since the axis unification (docs/adaptive-layout-plan.md
    # D1): the vertical and horizontal flex paths are one body
    # parameterized by the axis, so both orientations tag the same
    # observation BY CONSTRUCTION — the property the two-site count
    # used to hold.
    if track_handoff_count != 1:
        bad.append(f"{path}: wanted the table-generation handoff at "
                   f"the unified KayaTrackReader construction site, "
                   f"found {track_handoff_count}. Both flex "
                   f"orientations must tag the same observation.")

    # THE OBSERVATION FUNNEL, and the reason it is a clause: the mac
    # native tier reports NSTableView's own frames while the
    # synthesized one reports SwiftUI's, so the displaced-cells
    # negative below can only move BOTH with one perturbation while
    # both go through one recorder. A second writer would leave that
    # negative proving one tier and reporting the other.
    for field, writer in (
        ("tableCellFrames", "kayaRecordTableCell"),
        ("tableViewport", "kayaRecordTableViewport"),
    ):
        recorder = braced(text, r"func " + writer + r"\s*\(")
        if recorder is None:
            bad.append(f"{path}: no `func {writer}(` — the one writer "
                       f"of `{field}` is gone or renamed, so this "
                       f"gate's displacement negative would perturb a "
                       f"path only one tier reads.")
            continue
        field_writes = list(re.finditer(
            rf"\.{field}(?:\[[^\]]*\])?\s*=(?!=)", text))
        out.append(f"check-table-tier: {field} write sites found "
                   f"{len(field_writes)}")
        if not field_writes:
            bad.append(f"{path}: no write to `{field}` at all — this "
                       f"census is reading a name the interpreter no "
                       f"longer uses, so it agrees with anything.")
        for m in field_writes:
            if recorder[0] <= m.start() < recorder[1]:
                continue
            bad.append(f"{path}:{line_of(m.start())}: `{field}` is "
                       f"written outside {writer}. Both tiers record "
                       f"through ONE writer so that one displacement "
                       f"moves both; a second one is a tier whose "
                       f"geometry no negative here can perturb.")

    # THE WINDOW LOOP IS WIRED (docs/virtualization-plan.md §3-§4).
    # The mac native tier drives three links and only ONE of them has
    # a scene observable. MEASURED 2026-08-25, each removed in turn
    # with the probe scene watched: without the RANGE report the band
    # never narrows and expect_window reddens ("windows \"0 3 3\",
    # wanted \"1 2 3\"); without the HEIGHT report the core's
    # arithmetic is simply empty — extent 0.0, corrected 0 — and every
    # scene stays green, because a height moves the arithmetic and
    # never the band; without the row-height READ every row draws at
    # the tier's floor and the taller ones clip, which is pixels and
    # no assertion. So the two silent links are held here, statically,
    # the way check-native-undo holds the pair no scene can fail.
    loop = braced(text, r"final class KayaTableDriver\s*:")
    if loop is None:
        bad.append(f"{path}: no `final class KayaTableDriver:` — the "
                   f"mac tier's window loop was renamed or moved, and "
                   f"the two links no scene can see are unheld.")
    else:
        driver = text[loop[0]:loop[1]]
        height_arm = braced(
            text, r"func tableView\(\s*_ tableView: NSTableView, "
                  r"heightOfRow row: Int\)", loop[0], loop[1])
        for call, where, why in (
            ("KayaHost.windowMoved(", driver,
             "the visible range is never reported, so the core's band "
             "can never narrow"),
            ("KayaHost.rowsMeasured(", driver,
             "the extents this tier laid out are never reported, so "
             "the core presumes forever: measured extent 0.0 and "
             "corrected 0, with every scene green"),
            ("KayaHost.rowExtent(",
             text[height_arm[0]:height_arm[1]] if height_arm else None,
             "the row-height delegate stops asking the core, so every "
             "row draws at the tier's floor and a taller one clips — "
             "the second estimator §2 exists to remove"),
        ):
            if where is None:
                bad.append(f"{path}: no `heightOfRow` arm inside "
                           f"KayaTableDriver — the row-height delegate "
                           f"this gate reads is gone.")
                continue
            out.append(f"check-table-tier: window-loop link `{call}` "
                       f"found {where.count(call)} time(s)")
            if call not in where:
                bad.append(f"{path}: KayaTableDriver never calls "
                           f"`{call}` — {why}.")

    # THE SYNTHESIZED TIER'S WINDOW, held the same way and for a
    # STRONGER reason: here not ONE of the links has a scene
    # observable. MEASURED 2026-08-25 on the iOS-compact tier with
    # windowed.steps watched — take the RANGE report away and the band
    # never narrows, every row of the collection stays realized, and
    # the scene stays GREEN, because expect_window reads the viewport
    # and a viewport scrolling over a fully realized list answers
    # exactly what a windowed one does. The difference is memory, and
    # no verb reads memory. Take the HEIGHT report away and the core's
    # arithmetic stays empty (offset 0, extent 0) with the scene still
    # green. Compute the spacers HERE instead of reading the core's,
    # and the rows land in the same places until the two arithmetics
    # disagree, which is the divergence §2 exists to make impossible.
    band = braced(text,
                  r"@Observable final class KayaSynthesizedWindow\s*\{")
    if band is None:
        bad.append(f"{path}: no `@Observable final class "
                   f"KayaSynthesizedWindow {{` — the synthesized "
                   f"tier's window loop was renamed or moved, and not "
                   f"one of its links has a scene that could see it "
                   f"go.")
    else:
        report_arm = braced(text,
                            r"private func report\(_ node: KayaNode\)",
                            band[0], band[1])
        measure_arm = braced(text,
                             r"private func measure\(_ node: KayaNode",
                             band[0], band[1])
        if report_arm is None or measure_arm is None:
            bad.append(f"{path}: KayaSynthesizedWindow has no "
                       f"`report(_ node:)` / `measure(_ node:)` pair — "
                       f"the loop this gate reads is gone.")
        else:
            report_body = text[report_arm[0]:report_arm[1]]
            measure_body = text[measure_arm[0]:measure_arm[1]]
            for call, where, arm, why in (
                ("KayaHost.windowMoved(", report_body, "report",
                 "the visible range is never reported, so the core's "
                 "band can never narrow — every row stays realized "
                 "and every scene stays green"),
                ("KayaHost.rowsMeasured(", measure_body, "measure",
                 "the extents this tier laid out are never reported, "
                 "so the core presumes forever and its offset and "
                 "extent stay 0"),
                ("KayaHost.rowExtent(", report_body, "report",
                 "the band's own height stops being the core's "
                 "arithmetic — the second estimator §2 exists to "
                 "remove"),
                ("top: geometry.offset", report_body, "report",
                 "the top spacer stops being the core's band offset "
                 "and becomes a number this tier derived"),
                ("geometry.extent - geometry.offset - spanned",
                 report_body, "report",
                 "the bottom spacer stops being what the core says is "
                 "left below the band and becomes a number this tier "
                 "derived"),
            ):
                out.append(f"check-table-tier: synthesized window "
                           f"link `{call}` found {where.count(call)} "
                           f"time(s) in {arm}")
                if call not in where:
                    bad.append(f"{path}: KayaSynthesizedWindow's "
                               f"{arm} never names `{call}` — {why}.")

    tier = braced(text,
                  r"private struct KayaSynthesizedTable\s*:\s*View\s*\{")
    if tier is None:
        bad.append(f"{path}: no `private struct KayaSynthesizedTable: "
                   f"View {{` — the tier whose spacer geometry this "
                   f"gate holds is gone.")
    else:
        tier_body = text[tier[0]:tier[1]]
        for name, why in (
            ("window.top", "the top spacer never reaches the layout"),
            ("window.bottom",
             "the bottom spacer never reaches the layout"),
            ("window.placement",
             "the layout's own placement never reaches the report, so "
             "the range this tier reports is a guess about geometry "
             "nobody read"),
        ):
            if name not in tier_body:
                bad.append(f"{path}: KayaSynthesizedTable never hands "
                           f"`{name}` to its layout — {why}.")

    spacers = braced(text,
                     r"private struct KayaTableLayout\s*:\s*Layout\s*\{")
    if spacers is None:
        bad.append(f"{path}: no `private struct KayaTableLayout: "
                   f"Layout {{` — the layout that draws the band "
                   f"between its two spacers is gone.")
    else:
        for arm, wanted, why in (
            (r"func placeSubviews\(", "+ top",
             "the band is placed at the content's top whatever the "
             "core said, so every realized row draws one whole spacer "
             "out of place"),
            (r"func sizeThatFits\(", "+ bottom",
             "the content stops being as tall as the collection, so "
             "the scroll bar and every seek past the band are about a "
             "shorter list than there is"),
        ):
            found = braced(text, arm, spacers[0], spacers[1])
            if found is None:
                bad.append(f"{path}: KayaTableLayout has no `{arm}` — "
                           f"this gate cannot read where the spacers "
                           f"land.")
            elif wanted not in text[found[0]:found[1]]:
                bad.append(f"{path}: KayaTableLayout's {arm} never "
                           f"adds `{wanted}` — {why}.")

    invalidation_match = braced(
        text, r"func kayaInvalidateTableGeometry\s*\(")
    if invalidation_match is None:
        bad.append(f"{path}: no `func kayaInvalidateTableGeometry(` — "
                   f"layout-only changes cannot synchronously make the "
                   f"prior table observations stale.")
    else:
        invalidation = text[invalidation_match[0]:
                            invalidation_match[1]]
        if "kayaScene.columns" not in invalidation \
                or "table.tableGeometryEpoch &+= 1" not in invalidation:
            bad.append(f"{path}: kayaInvalidateTableGeometry must bump "
                       f"every live declared table's geometry epoch. "
                       f"Clearing frames without a new reporter task "
                       f"id can leave them missing forever when the "
                       f"frame is unchanged.")

    resize_helper = braced(text, r"func kayaSetWindowContentSize\s*\(")
    if resize_helper is None:
        bad.append(f"{path}: no `func kayaSetWindowContentSize(` — "
                   f"native content-size changes can bypass the "
                   f"synchronous table-geometry invalidation.")
    else:
        helper = text[resize_helper[0]:resize_helper[1]]
        invalidation_call = "kayaInvalidateTableGeometry()"
        native_call = "window.setContentSize(size)"
        if (invalidation_call not in helper
                or native_call not in helper
                or helper.index(invalidation_call)
                > helper.index(native_call)):
            bad.append(f"{path}: kayaSetWindowContentSize must "
                       f"invalidate table geometry before "
                       f"NSWindow.setContentSize. A main-queue hop is "
                       f"not a completed SwiftUI layout turn.")
    direct_size_calls = text.count(".setContentSize(")
    out.append(f"check-table-tier: native setContentSize callsites "
               f"found {direct_size_calls} time(s)")
    if direct_size_calls != 1:
        bad.append(f"{path}: wanted exactly one native setContentSize "
                   f"call inside the invalidation helper, found "
                   f"{direct_size_calls}. Every direct call is a route "
                   f"that can retain a coherent old table snapshot.")

    apply_match = braced(text, r"private func kayaApply\s*\(")
    if apply_match is None:
        bad.append(f"{path}: no `private func kayaApply(` — the "
                   f"transaction-boundary geometry invalidation route "
                   f"moved outside this gate's view.")
    else:
        apply_body = text[apply_match[0]:apply_match[1]]
        call = "kayaInvalidateTableGeometry()"
        boundary = "batch.withUnsafeBytes"
        if call not in apply_body or boundary not in apply_body \
                or apply_body.index(call) > apply_body.index(boundary):
            bad.append(f"{path}: kayaApply must invalidate table "
                       f"geometry before reading the batch. A sibling "
                       f"or ancestor can move a table without changing "
                       f"the table subtree hashed by the model "
                       f"generation.")

    resize_case = harness_case("resize_window",
                               "expect_sections_presentation")
    if resize_case is not None:
        if "kayaSetWindowContentSize(" not in resize_case:
            bad.append(f"{path}: resize_window must route through "
                       f"kayaSetWindowContentSize. Otherwise the "
                       f"immediately following expect can accept the "
                       f"old green viewport, cells, and track without "
                       f"yielding for layout.")

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
            bad.append(f"{path}: expect_fills' table arm must refuse "
                       f"absent geometry, a PARTIALLY recorded row and "
                       f"rows a tier owes but has not realized, and "
                       f"contain live rows vertically in the recorded "
                       f"viewport; vertical slack remains valid. One "
                       f"of those checks is absent from the arm.")

    TIERS = ("KayaNativeTable", "KayaSynthesizedTable")

    surface = braced(text, r"struct KayaTableSurface\s*:\s*View\b")
    if surface is None:
        bad.append(f"{path}: no `struct KayaTableSurface: View` — the "
                   f"surface this gate reads was renamed or moved, and "
                   f"every clause below would be a verdict about "
                   f"nothing. Point the gate at the new name.")
        body = None
    else:
        body = braced(text, r"var body\s*:\s*some View\b", surface[0],
                      surface[1])
        if body is None:
            bad.append(f"{path}: KayaTableSurface has no `var body: "
                       f"some View` block this gate can read — the "
                       f"routing moved out of the body and the "
                       f"construction census below has nothing to "
                       f"hold it to.")

    # A1 — the two tier views are constructed inside that body and
    # nowhere else. The counts are printed: a census that found none
    # would agree with everything.
    if body is not None:
        for tier_name in TIERS:
            sites = [m.start() for m in
                     re.finditer(re.escape(tier_name) + r"\s*\(",
                                 text)]
            outside = [s_ for s_ in sites
                       if not (body[0] <= s_ < body[1])]
            out.append(f"check-table-tier: {tier_name} constructed "
                       f"{len(sites)} time(s), "
                       f"{len(sites) - len(outside)} inside the "
                       f"routing")
            if not sites:
                bad.append(f"{path}: {tier_name} is never constructed "
                           f"— this census is reading a name the "
                           f"interpreter no longer uses, so it agrees "
                           f"with anything.")
            for off in outside:
                # WHERE it escaped to is the difference between two
                # fixes, so the sentence says which one this is.
                where = ("inside KayaTableSurface but outside its "
                         "`body`" if surface[0] <= off < surface[1]
                         else "outside KayaTableSurface altogether")
                bad.append(f"{path}:{line_of(off)}: {tier_name} is "
                           f"constructed {where}. The tier split has "
                           f"ONE caller by design — the switch on "
                           f"kayaTableTier in that body — because a "
                           f"second one takes a tier nothing tested "
                           f"and no scene can see (docs/traps.md: "
                           f"both tiers present identical bytes).")

    # A2 — and that body decides by calling the rule, rather than
    # re-deriving it. A body that stops consulting kayaTableTier
    # leaves clause B testing a function nothing calls.
    if body is not None:
        inside = text[body[0]:body[1]]
        if "kayaTableTier(" not in inside:
            bad.append(f"{path}: KayaTableSurface's body never calls "
                       f"`kayaTableTier` — the tier is decided "
                       f"somewhere this gate's runtime clause does not "
                       f"reach, so the truth table it drives would be "
                       f"about dead code.")
        floor = braced(text,
                       r"if #available\(macOS 14\.4, iOS 17\.4, \*\)",
                       body[0], body[1])
        if floor is None:
            bad.append(f"{path}: KayaTableSurface's body has no "
                       f"`if #available(macOS 14.4, iOS 17.4, *)` — "
                       f"TableColumnForEach's floor is what "
                       f"`dynamicColumns` MEANS, and the gate cannot "
                       f"see which branch is the below-floor one "
                       f"without it.")
        else:
            rest = braced(text, r"\belse\b", floor[1], body[1])
            if rest is None:
                bad.append(f"{path}: the availability check in "
                           f"KayaTableSurface's body has no `else` "
                           f"branch. Below TableColumnForEach's floor "
                           f"the tier is forced, and that branch must "
                           f"still draw a table.")
            else:
                low = text[rest[0]:rest[1]]
                if "KayaSynthesizedTable(" not in low \
                        or "KayaNativeTable(" in low:
                    bad.append(f"{path}: the below-floor branch of "
                               f"KayaTableSurface's body must "
                               f"construct KayaSynthesizedTable and "
                               f"only that — it is the "
                               f"`dynamicColumns: false` half of "
                               f"kayaTableTier's truth table, and the "
                               f"two must say the same thing.")

    # A3 — the rule reads its parameters and nothing else. A rule
    # compiled per platform, or one that reaches into the environment,
    # cannot be driven off-device at all, which is the whole point of
    # the split.
    rule = braced(text, r"func kayaTableTier\s*\(")
    if rule is None:
        bad.append(f"{path}: no `func kayaTableTier(` — the pure tier "
                   f"rule is gone or renamed. The routing is testable "
                   f"only while it is a function of its arguments "
                   f"(docs/traps.md).")
    else:
        inner = text[rule[0]:rule[1]]
        for hazard in ("#if", "horizontalSizeClass", "Environment",
                       "os(macOS)"):
            if hazard in inner:
                bad.append(f"{path}: kayaTableTier's body contains "
                           f"`{hazard}`. The rule must be one function "
                           f"on both platforms and read only its "
                           f"parameters — the mac probe cannot drive "
                           f"an iOS arm that is compiled away, and a "
                           f"rule that reads the environment cannot be "
                           f"driven at all.")
        before = text[:rule[0]]
        if before.count("#if") != before.count("#endif"):
            bad.append(f"{path}: kayaTableTier is declared inside a "
                       f"conditional-compilation block — on the other "
                       f"platform the rule this gate drives does not "
                       f"exist.")

    # A4 — the environment reaches the rule down ONE path: widthClass,
    # whose two arms are each a single line. The mac arm the runtime
    # clause reads for real; the iOS arm is the one no host here can
    # execute, and it is exactly where the traps entry's failure lives
    # — a phone routed to the native tier presents the same bytes as
    # one routed to kaya's header, so no leg on any device would say a
    # word.
    MAC_ARM = "return .noSizeClass"
    IOS_ARM = "return kayaTableWidth(sizeClass: horizontalSizeClass)"
    prop = None
    if surface is not None:
        prop = braced(text, r"var widthClass\s*:\s*KayaTableWidth\b",
                      surface[0], surface[1])
        if prop is None:
            bad.append(f"{path}: KayaTableSurface has no `var "
                       f"widthClass: KayaTableWidth` block — the size "
                       f"class enters the rule somewhere else now, and "
                       f"the arm this gate cannot execute is unread.")
        else:
            arms_text = text[prop[0] + 1:prop[1] - 1]
            i = arms_text.find("#if os(macOS)")
            j = arms_text.find("#else", i + 1)
            k = arms_text.find("#endif", j + 1)
            if min(i, j, k) < 0:
                bad.append(f"{path}: widthClass is not `#if os(macOS)` "
                           f"/ `#else` / `#endif` with one arm each. "
                           f"The gate reads the two arms separately "
                           f"because only one of them runs on the host "
                           f"that runs this gate.")
            else:
                arms = {
                    "macOS arm": (
                        " ".join(arms_text[i + len("#if os(macOS)"):j]
                                 .split()), MAC_ARM),
                    "non-macOS arm": (
                        " ".join(arms_text[j + len("#else"):k]
                                 .split()), IOS_ARM),
                }
                for which, (got, want) in arms.items():
                    if got != want:
                        bad.append(
                            f"{path}: the {which} of `widthClass` "
                            f"reads {got!r}, wanted exactly {want!r}. "
                            f"The size class enters the tier rule "
                            f"through kayaTableWidth and nowhere else "
                            f"— that mapping is what the runtime "
                            f"clause drives, and an arm that derives a "
                            f"width for itself is a second rule no "
                            f"device could ever contradict "
                            f"(docs/traps.md: both tiers present "
                            f"identical bytes).")
        # …and it is read there ONCE. A second reading anywhere in the
        # surface is a second rule, and the compact phone is the leg
        # that cannot see it.
        for m in re.finditer(r"horizontalSizeClass",
                             text[surface[0]:surface[1]]):
            off = surface[0] + m.start()
            if prop is not None and prop[0] <= off < prop[1]:
                continue
            if "@Environment" in text[text.rfind("\n", 0, off) + 1:off]:
                continue
            bad.append(f"{path}:{line_of(off)}: KayaTableSurface reads "
                       f"`horizontalSizeClass` outside `widthClass`. "
                       f"The environment has one reading, mapped by "
                       f"kayaTableWidth; a second one decides a tier "
                       f"the gate's truth table never saw.")

    # A5 — CONTENT IS THE FLOOR, the pairing half (ruled 2026-08-26).
    # The runtime clauses below drive the two halves the ruling names —
    # the measured minimum and the width handed upward — but the THIRD
    # edit they forced has no observable at all: a column that widens
    # must re-present its cells, because AppKit resizes the cell view
    # while the SwiftUI content inside it keeps the truncation it
    # chose at the old width, and that difference is INK. Nothing the
    # interpreter exposes tells a stale cell from a fresh one
    # (contentWidth reads the same either way), so this is the
    # native-undo shape: a static pairing is the only wall available.
    columns_block = braced(text, r"private func layoutColumns\s*\(")
    if columns_block is None:
        bad.append(f"{path}: no `private func layoutColumns(` block — "
                   f"the mac tier's column sizing moved, and the floor "
                   f"clauses below read nothing.")
    else:
        cb = text[columns_block[0]:columns_block[1]]
        for needle, why in (
            ("column.minWidth = floors[",
             "the measured content floor must be the column's MINIMUM. "
             "With a hard-coded minimum AppKit compresses the columns "
             "to whatever track it was handed, and every cell "
             "ellipsizes while this function has assigned exactly the "
             "right widths (measured 2026-08-26)."),
            ("publishContentWidth(",
             "the measured content total must be published UPWARD, "
             "the way the synthesized tier's columnWidths total is — "
             "without it the columns hold their floors and the table "
             "is cut off at its container."),
            ("represent(visible)",
             "a widened column must RE-PRESENT its cells. AppKit "
             "resizes the cell view; the SwiftUI content already "
             "hosted inside it keeps the ellipsis it chose at the old "
             "width (measured 2026-08-26: a 92.5pt cell asking 76.5 "
             "still drawing \"2026-08...\"). This clause is static "
             "because that staleness is ink and no observable can see "
             "it."),
        ):
            if needle not in cb:
                bad.append(f"{path}: layoutColumns does not call "
                           f"`{needle}` — {why}")

    return out, bad


# --- The self-test: every clause above WATCHED GOING RED. -------------
# Perturbations are applied to COPIES; the substitution count AND THE
# SITE are printed, and every negative NAMES the declaration it must
# land in. A count alone cannot tell two perturbations apart: the
# chained shadow's "stale cell generations" negative spent a milestone
# re-hitting kayaCurrentTableTrackWidth — the same line the standalone
# unversioned-track negative already perturbs — because its pattern had
# no trailing comma and re.subn(count=1) takes the first match. It
# printed "1", the honesty check passed, and the cell filter it was
# named for was never touched (the review of 01dd633).
#
# FIRST-MATCH-ONLY BY CONSTRUCTION: the replacement splices the first
# match literally, which is what the shell's count=1 subn did — and
# what makes the site check meaningful.
DECLS = (
    re.compile(r"^(\s*)(?:@[\w.]+(?:\([^)]*\))?\s+)*"
               r"(?:(?:public|private|internal|fileprivate|open|static"
               r"|final|override|mutating|nonisolated|convenience"
               r"|required)\s+)*"
               r"(func|struct|class|enum|extension|protocol|init"
               r"|subscript)\s+(`?\w+`?)"),
    re.compile(r"^(\s*)(?:@[\w.]+(?:\([^)]*\))?\s+)*"
               r"(?:(?:public|private|internal|fileprivate|static)\s+)*"
               r"(var|let)\s+(\w+)\s*:[^=]*\{\s*$"),
    re.compile(r'^(\s*)(case)\s+("[^"]*")\s*:'),
)


def _named(raw_line):
    for decl in DECLS:
        m = decl.match(raw_line)
        if m:
            return f"{m.group(2)} {m.group(3)}"
    return None


def _site(text, offset):
    before = text[:offset].split("\n")
    start = len(text[:offset]) - len(before[-1])
    here = text[start:text.find("\n", start)]
    # The INDENT OF THE LINE, not of the match: a pattern that carries
    # its own leading whitespace starts at column 0 and would
    # otherwise close the walk before it began.
    limit = len(here) - len(here.lstrip())
    chain = []
    if _named(here):
        chain.append(_named(here))
    for raw_line in reversed(before[:-1]):
        if not raw_line.strip():
            continue
        indent = len(raw_line) - len(raw_line.lstrip())
        if indent >= limit:
            continue
        name = _named(raw_line)
        if name:
            chain.append(name)
            limit = indent
        if limit == 0:
            break
    return len(before), " > ".join(reversed(chain)) or "<file scope>"


def perturb(source_text, pattern, repl, what, must_land_in):
    """The first match spliced with the literal `repl`; the count and
    the site are both PRINTED, because "the negative passed", "it
    never touched the file" and "it perturbed some other negative's
    site" look identical otherwise."""
    m = re.compile(pattern).search(source_text)
    count = 1 if m else 0
    line, where = (_site(source_text, m.start()) if m
                   else (0, "<no match>"))
    print(f"check-table-tier: self-test — {what} applied ({count} "
          f"substitution) at line {line} in {where}")
    if count < 1:
        print(f"check-table-tier: SELF-TEST BROKEN — {what} changed "
              f"nothing. The pattern no longer matches the file, so "
              f"the red below would have been a green about an "
              f"unperturbed copy.", file=sys.stderr)
        raise SystemExit(1)
    if where != must_land_in:
        print(f"check-table-tier: SELF-TEST BROKEN — {what} landed in "
              f"'{where}', not the '{must_land_in}' it names. A "
              f"perturbation that lands somewhere else proves that "
              f"site twice over and its own not at all.",
              file=sys.stderr)
        raise SystemExit(1)
    return source_text[:m.start()] + repl + source_text[m.end():]


def refuses(doctored_text, fragment, what):
    out, bad = check(doctored_text)
    if not bad:
        print(f"check-table-tier: SELF-TEST FAILED — {what} was "
              f"ACCEPTED.", file=sys.stderr)
        raise SystemExit(1)
    if not any(fragment in b for b in out + bad):
        print(f"check-table-tier: SELF-TEST FAILED — {what} was "
              f"refused, but not for the stated reason. Wanted a "
              f"sentence containing:", file=sys.stderr)
        print(f"  {fragment}", file=sys.stderr)
        print("got:", file=sys.stderr)
        print("\n".join(out + bad), file=sys.stderr)
        raise SystemExit(1)
    print(f"check-table-tier: self-test — {what} refused, as demanded")


REAL = (ROOT / SWIFTUI).read_text(encoding="utf-8")

GENERATION_BODY = (r"func kayaTableGeometryGeneration\(_ table: "
                   r"KayaNode\) -> Int \{\n"
                   r"    table\.tableGeometryEpoch\n\}")

# Doctored texts kept by name: clause B compiles several of them.
doctored = {}


def static_negative(name, pattern, repl, applied_label, site, fragment,
                    refused_label, base=None):
    src = REAL if base is None else doctored[base]
    doctored[name] = perturb(src, pattern, repl, applied_label, site)
    refuses(doctored[name], fragment, refused_label)


static_negative(
    "no-layout-epoch", GENERATION_BODY,
    "func kayaTableGeometryGeneration(_ table: KayaNode) -> Int {\n"
    "    table.children.count\n}",
    "the geometry generation derived from the model instead of the "
    "epoch", "func kayaTableGeometryGeneration",
    "must READ tableGeometryEpoch",
    "a model-derived generation accepting a pre-layout snapshot")

static_negative(
    "walked-generation", GENERATION_BODY,
    "func kayaTableGeometryGeneration(_ table: KayaNode) -> Int {\n"
    "    var hasher = Hasher()\n"
    "    hasher.combine(table.tableGeometryEpoch)\n"
    "    for child in table.children { hasher.combine(child.text) }\n"
    "    return hasher.finalize()\n}",
    "the geometry generation walking the subtree again",
    "func kayaTableGeometryGeneration",
    "is a STORED epoch read, never a walk",
    "a generation re-hashing the subtree on every body evaluation")

static_negative(
    "unstaled-user-write",
    r"func kayaUserWrite\(_ write: \(\) -> Void\) \{\n"
    r"    kayaInvalidateTableGeometry\(\)\n",
    "func kayaUserWrite(_ write: () -> Void) {\n",
    "the user-route funnel's invalidation removed",
    "func kayaUserWrite",
    "kayaUserWrite must invalidate table geometry BEFORE",
    "a user-route model write that stales nothing")

static_negative(
    "unfunnelled-write",
    r"kayaUserWrite \{ node\.checked = newValue \}",
    "node.checked = newValue",
    "a user-route model write moved out of the funnel",
    "struct KayaRender > var widget",
    "writes the model outside", "a model write no path staled")

static_negative(
    "no-layout-invalidation",
    r"        table\.tableGeometryEpoch &\+= 1\n", "",
    "the live-table layout invalidation removed",
    "func kayaInvalidateTableGeometry",
    "must bump every live declared",
    "an invalidator that changes no reporter task id")

static_negative(
    "no-apply-invalidation",
    r"private func kayaApply\(_ batch: Data, _ blobs: "
    r"\[UInt64: Data\]\) \{\n    kayaInvalidateTableGeometry\(\)",
    "private func kayaApply(_ batch: Data, _ blobs: [UInt64: Data]) {",
    "the transaction-boundary layout invalidation removed",
    "func kayaApply", "kayaApply must invalidate table geometry",
    "a sibling mutation retaining old table geometry")

static_negative(
    "no-resize-helper-invalidation",
    r"func kayaSetWindowContentSize\(_ window: NSWindow, _ size: "
    r"NSSize\) \{\n    kayaInvalidateTableGeometry\(\)",
    "func kayaSetWindowContentSize(_ window: NSWindow, _ size: "
    "NSSize) {",
    "the native resize helper invalidation removed",
    "func kayaSetWindowContentSize",
    "kayaSetWindowContentSize must invalidate table geometry",
    "a native content-size change retaining the previous snapshot")

static_negative(
    "no-resize-invalidation",
    r"kayaSetWindowContentSize\(\n                                "
    r"window, NSSize\(width: rw, height: rh\)\)",
    "window.setContentSize(NSSize(width: rw, height: rh))",
    "the resize harness bypassed the invalidating helper",
    'func kayaRunScript > case "resize_window"',
    "resize_window must route through",
    "resize_window accepting the previous green snapshot")

static_negative(
    "unversioned-table-track",
    r"observation\.generation == generation,", "true,",
    "the table-track generation check bypassed",
    "func kayaCurrentTableTrackWidth",
    "must accept only a positive track",
    "an old assigned track accepted as current")

static_negative(
    "unkeyed-table-track-task", r"\.task\(id: tableGeneration\)",
    ".task(id: 0)", "the table-track republish task keyed to a "
                    "constant",
    "struct KayaTrackReader > var body",
    "must tag table tracks and republish",
    "a same-size invalidation unable to refresh its track")

static_negative(
    "untagged-flex-track",
    r"tableGeneration: child\.tableColumns\.isEmpty\n"
    r"                                        "
    r"\? nil : kayaTableGeometryGeneration\(child\)",
    "tableGeneration: nil",
    "one flex path stopped handing table generations to its track "
    "reader", "struct KayaRender > var widget",
    "wanted the table-generation handoff",
    "one flex orientation recording untagged table tracks")

static_negative(
    "no-range-report",
    r"                KayaHost\.windowMoved\(node\.id, "
    r"visible\.location, visible\.length\)\n", "",
    "the visible-range report removed",
    "struct KayaNativeTable > class KayaTableDriver > func report",
    "never calls `KayaHost.windowMoved(`",
    "a tier whose band can never narrow")

static_negative(
    "no-height-report",
    r"            KayaHost\.rowsMeasured\(node\.id, "
    r"visible\.location, heights\)\n", "",
    "the measured-extent report removed",
    "struct KayaNativeTable > class KayaTableDriver > "
    "func measureRows",
    "never calls `KayaHost.rowsMeasured(`",
    "a tier that leaves the core presuming forever")

static_negative(
    "unasked-row-height",
    r"            let extent = KayaHost\.rowExtent\(node\.id, row\)\n"
    r"            return extent > 0 \? CGFloat\(extent\) : "
    r"kayaNativeRowHeight",
    "            return kayaNativeRowHeight",
    "the row-height delegate ignoring the core",
    "struct KayaNativeTable > class KayaTableDriver > func tableView",
    "never calls `KayaHost.rowExtent(`",
    "a second estimator beside the core's")

# The synthesized tier's five, one per link. None of them has a scene
# that can see it go: windowed.steps was watched staying GREEN with the
# range report removed, because expect_window reads the viewport and a
# viewport over a fully realized list reads the same.
static_negative(
    "synth-no-range-report",
    r"            KayaHost\.windowMoved\(node\.id, claim\.first, "
    r"claim\.count\)\n", "",
    "the synthesized tier's visible-range report removed",
    "class KayaSynthesizedWindow > func report",
    "report never names `KayaHost.windowMoved(`",
    "a synthesized tier whose band can never narrow")

static_negative(
    "synth-no-height-report",
    r"        KayaHost\.rowsMeasured\(node\.id, first, heights\)\n",
    "", "the synthesized tier's measured-extent report removed",
    "class KayaSynthesizedWindow > func measure",
    "measure never names `KayaHost.rowsMeasured(`",
    "a synthesized tier that leaves the core presuming forever")

static_negative(
    "synth-second-estimator",
    r"        for index in band \{ spanned \+= "
    r"KayaHost\.rowExtent\(node\.id, index\) \}",
    "        for _ in band { spanned += Double(pitches.first ?? 0) }",
    "the band's height taken from the tier instead of the core",
    "class KayaSynthesizedWindow > func report",
    "report never names `KayaHost.rowExtent(`",
    "a second estimator beside the core's, one tier over")

static_negative(
    "synth-derived-spacer",
    r"            windowed: true, top: geometry\.offset,",
    "            windowed: true, top: Double(geometry.first) * "
    "(pitches.first.map(Double.init) ?? 0),",
    "the top spacer derived here instead of read from the core",
    "class KayaSynthesizedWindow > func report",
    "report never names `top: geometry.offset`",
    "a tier that draws its band where its own arithmetic says")

static_negative(
    "synth-unspaced-band",
    r"        var y = dividerY \+ dividerH \+ rowGap \+ top",
    "        var y = dividerY + dividerH + rowGap",
    "the band placed at the content's top, ignoring the core's "
    "offset", "struct KayaTableLayout > func placeSubviews",
    "never adds `+ top`", "a band drawn one whole spacer out of place")

static_negative(
    "synth-unwired-spacers",
    r"            windowed: window\.windowed, top: window\.top, "
    r"bottom: window\.bottom,",
    "            windowed: false, top: 0, bottom: 0,",
    "the window's spacers never handed to the layout",
    "struct KayaSynthesizedTable > func rows",
    "never hands `window.top`",
    "a tier whose layout cannot know where its band starts")

static_negative(
    "second-cell-writer",
    r"kayaRecordTableCell\(\n                        node, "
    r"kayaTableCellKey\(stamped, column, cell\), generation, frame\)",
    "node.tableCellFrames[kayaTableCellKey(stamped, column, cell)] =\n"
    "                        KayaTableCellObservation(generation: "
    "generation, frame: frame)",
    "the native tier writing cell geometry past the recorder",
    "struct KayaNativeTable > class KayaTableDriver > "
    "func recordGeometry",
    "is written outside kayaRecordTableCell",
    "a tier recording its cells where no displacement negative can "
    "reach them")

static_negative(
    "escaped-tier", r"struct KayaFlex: Layout \{",
    "let kayaEscapedTier = KayaNativeTable(node: node)\n"
    "struct KayaFlex: Layout {",
    "a tier view constructed outside the routing", "struct KayaFlex",
    "is constructed outside",
    "a second construction site for the native tier")

static_negative(
    "edge-main-axis", r"kayaCurrentTableTrackWidth\(node\)",
    "kayaMainExtents[node.id]",
    "the table width replaced by its parent main-axis extent",
    'func kayaRunScript > case "expect_column_edges"',
    "expect_column_edges must read current cell geometry",
    "column-edge containment reading height as width")

static_negative(
    "one-sided-track",
    r"abs\(Double\(viewport\.width\) - track\) <= tolerance",
    "Double(viewport.width) >= track - tolerance",
    "the table-track comparison made one-sided",
    "func kayaTableViewportMatchesTrack",
    "must reject BOTH a viewport",
    "an oversized native table accepted inside a narrower assigned "
    "track")

static_negative(
    "fills-horizontal",
    r"kayaTableFramesFitVertically\(rows, inside: viewport\)",
    "kayaTableFramesFitHorizontally(rows, inside: viewport)",
    "expect_fills checking rows on the horizontal axis",
    'func kayaRunScript > case "expect_fills"',
    "expect_fills' table arm must refuse",
    "table fill accepting vertical row overflow")

static_negative(
    "escaped-in-surface", r"    var widthClass: KayaTableWidth \{",
    "    var escapedTier: some View { KayaNativeTable(node: node) }\n"
    "    var widthClass: KayaTableWidth {",
    "a tier view constructed in the surface but outside its body",
    "struct KayaTableSurface > var widthClass",
    "but outside its `body`",
    "a second construction site beside the routing")

static_negative(
    "unconsulted",
    r"switch kayaTableTier\(\n *width: widthClass, dynamicColumns: "
    r"true,\n *folded: !node.foldedChildren.isEmpty\)",
    "switch KayaTableTier.native",
    "the body deciding without the rule",
    "struct KayaTableSurface > var body",
    "never calls `kayaTableTier`",
    "a body that routes without consulting the rule")

static_negative(
    "rederived", r"case \.native: KayaNativeTable\(node: node\)",
    "case .native:\n"
    "                if horizontalSizeClass == .compact {\n"
    "                    KayaSynthesizedTable(node: node)\n"
    "                } else {\n"
    "                    KayaNativeTable(node: node)\n"
    "                }",
    "a second size-class reading in the body",
    "struct KayaTableSurface > var body", "outside `widthClass`",
    "a body that re-derives the tier from the environment")

static_negative(
    "ios-arm",
    r"return kayaTableWidth\(sizeClass: horizontalSizeClass\)",
    "return .regular",
    "the iOS arm of widthClass deriving a width of its own",
    "struct KayaTableSurface > var widthClass",
    "the non-macOS arm of `widthClass`",
    "the one arm no host here executes, answering something else")

static_negative(
    "second-reading", r"    var widthClass: KayaTableWidth \{",
    "    var isCompactPhone: Bool { horizontalSizeClass == "
    ".compact }\n    var widthClass: KayaTableWidth {",
    "a second reading of the size class in the surface",
    "struct KayaTableSurface > var widthClass", "outside `widthClass`",
    "a second reading of the environment beside the mapped one")

static_negative(
    "below-floor-native",
    r"does not compile\.\n            "
    r"KayaSynthesizedTable\(node: node\)",
    "does not compile.\n            KayaNativeTable(node: node)",
    "the below-floor branch taking the native tier",
    "struct KayaTableSurface > var body",
    "the below-floor branch of KayaTableSurface's body",
    "a below-floor branch that disagrees with the rule")

static_negative(
    "no-floor",
    r"if #available\(macOS 14\.4, iOS 17\.4, \*\) \{\n"
    r"            switch kayaTableTier",
    "if true {\n            switch kayaTableTier",
    "the availability check removed from the routing",
    "struct KayaTableSurface > var body", "body has no `if #available",
    "a routing whose availability floor this gate can no longer see")

static_negative(
    "per-platform",
    r"guard dynamicColumns else \{ return \.synthesized \}",
    "#if os(macOS)\n        return .native\n    #endif\n"
    "    guard dynamicColumns else { return .synthesized }",
    "a per-platform arm inside the rule", "func kayaTableTier",
    "must be one function on both platforms",
    "a rule the mac probe could not drive")

static_negative(
    "renamed", r"struct KayaTableSurface: View \{",
    "struct KayaTableSurfaceRenamed: View {",
    "the surface renamed out from under the gate",
    "struct KayaTableSurface", "no `struct KayaTableSurface: View`",
    "a surface this gate can no longer find")

# --- Clause A on the real file. ---------------------------------------
out, bad = check(REAL)
if bad:
    print("\n".join(out + bad))
    print("check-table-tier: FAIL — the routing is not where this "
          "gate holds it.", file=sys.stderr)
    raise SystemExit(1)
print("\n".join(out))

# --- Clause B: the rule driven for real, where a GUI toolkit exists. --
if platform.system() != "Darwin":
    print("check-table-tier: OK (static clause; the truth table needs "
          "macOS and was SKIPPED)")
    raise SystemExit(g.status)

if not (ROOT / "target" / "debug" / "libkaya.dylib").is_file():
    print("check-table-tier: target/debug/libkaya.dylib is not built "
          "— the probe links against it. Run tools/gates.py, which "
          "builds what its gates read.", file=sys.stderr)
    raise SystemExit(1)


def write_doctored(name):
    p = T / f"{name}.swift"
    p.write_text(doctored[name], encoding="utf-8")
    return p


def build_probe(source, out_bin):
    """The probe compiles the interpreter's OWN source, so there is no
    interpreter artifact in this path to go stale."""
    return subprocess.run(
        ["bash", "-c",
         'source "$1/tools/lib/swift-toolchain.sh" && cd "$1" && '
         'shift && kaya_swiftc "$@"',
         "swift-toolchain", str(ROOT),
         "-import-objc-header", "crates/kaya/include/kaya.h",
         str(source), PROBE,
         "-L", "target/debug", "-lkaya",
         "-framework", "AppKit", "-framework", "Foundation",
         "-o", str(out_bin)], check=False).returncode == 0


DYLD = dict(os.environ,
            DYLD_LIBRARY_PATH=str(ROOT / "target" / "debug"))

if not build_probe(ROOT / SWIFTUI, T / "table-tier"):
    print("check-table-tier: the tier probe did not compile",
          file=sys.stderr)
    raise SystemExit(1)
live = subprocess.run([str(T / "table-tier")], env=DYLD, check=False)
if live.returncode != 0:
    print(f"check-table-tier: FAIL — the tier probe exited "
          f"{live.returncode} (its own output names", file=sys.stderr)
    print("  the cell that disagreed).", file=sys.stderr)
    raise SystemExit(1)


def runtime_refuses(name, diagnostic, what):
    source = write_doctored(name)
    binary = T / name
    if not build_probe(source, binary):
        print(f"check-table-tier: SELF-TEST BROKEN — {what} did not "
              f"compile", file=sys.stderr)
        raise SystemExit(1)
    r = subprocess.run([str(binary)], env=DYLD, capture_output=True,
                       text=True, check=False)
    log = r.stdout + r.stderr
    if r.returncode == 0:
        print(f"check-table-tier: SELF-TEST FAILED — {what} was "
              f"accepted", file=sys.stderr)
        print(log, file=sys.stderr)
        raise SystemExit(1)
    if diagnostic not in log:
        print(f"check-table-tier: SELF-TEST FAILED — {what} reddened "
              f"without naming '{diagnostic}'. Got:", file=sys.stderr)
        print(log, file=sys.stderr)
        raise SystemExit(1)
    print(f"check-table-tier: self-test — {what} reds the real-window "
          f"probe (exit {r.returncode})")


runtime_refuses("no-layout-epoch",
                "a layout invalidation rejects the previous generation",
                "a model-derived table geometry generation")
runtime_refuses("unstaled-user-write",
                "a user-route model write immediately refuses the "
                "previous generation",
                "a user-route model write that stales nothing")
runtime_refuses("no-resize-helper-invalidation",
                "a resize never accepts the previous generation",
                "a resize helper that does not invalidate table "
                "geometry")
runtime_refuses("unversioned-table-track",
                "a layout invalidation rejects the previous track",
                "an unversioned assigned table track")
runtime_refuses("unkeyed-table-track-task",
                "a same-size layout invalidation republishes geometry "
                "and track",
                "a table-track task that cannot republish at the same "
                "size")

# The window-contract clause (ruled 2026-08-25: expect_window says
# first-visible and total; the band width is the core's tests' to
# hold). Its negative: a firstVisible that echoes the BAND's first
# would be indistinguishable from the verb reading
# realized-everything, and the probe's scroll step must catch exactly
# that — it has no static red, so it goes straight to the probe.
def chained(name, pattern, repl, applied_label, site, base):
    doctored[name] = perturb(doctored[base], pattern, repl,
                             applied_label, site)


doctored["band-echoing-first-visible"] = perturb(
    REAL,
    r"return \(visible\.length > 0 \? visible\.location : 0, "
    r"declared\)",
    "return (first, declared)",
    "firstVisible echoing the band's first instead of the viewport's",
    "struct KayaNativeTable > class KayaTableDriver > "
    "func firstVisible")
runtime_refuses("band-echoing-first-visible",
                "the verb's number must be the viewport's, not the "
                "band's",
                "a firstVisible read that echoes the band")

# Geometry guards share this watched shadow; every perturbation's
# count is printed before the one doctored interpreter is compiled.
doctored["overflowing-track"] = perturb(
    REAL, r"abs\(Double\(viewport\.width\) - track\) <= tolerance",
    "Double(viewport.width) >= track - tolerance",
    "an oversized table viewport accepted against its track",
    "func kayaTableViewportMatchesTrack")
chained("chained-clusters", r"edge - representative <= tolerance",
        "edge - representative <= tolerance * 2",
        "representative edge clustering replaced by a drift chain",
        "func kayaTableEdgeClusters", "overflowing-track")
chained("unkeyed-columns", r"guard clusters\.count == 1 else \{",
        "guard !clusters.isEmpty else {",
        "a column borrowing another column's cluster accepted",
        "func kayaTableColumnAlignment", "chained-clusters")
chained("unordered-columns",
        r"if next - previous <= tolerance \{ return false \}",
        "if next == previous { return false }",
        "descending column representatives accepted",
        "func kayaTableColumnRepresentativesIncrease",
        "unkeyed-columns")
# THE RECORDER, not either tier's reader: the mac native tier reports
# NSTableView's own cell rects and the synthesized one SwiftUI's
# frames, so a perturbation inside KayaEdgeReporter — where this one
# used to sit — displaces the synthesized tier alone and leaves the
# probe's live NATIVE clauses green about an unperturbed path
# (measured 2026-08-25, when the mac tier stopped being a SwiftUI
# Table).
chained("displaced-cells",
        r"node\.tableCellFrames\[key\] = KayaTableCellObservation\(\n"
        r"        generation: generation, frame: frame\)",
        "node.tableCellFrames[key] = KayaTableCellObservation(\n"
        "        generation: generation, frame: frame.offsetBy(dx: "
        "1000, dy: 1000))",
        "live cell geometry displaced outside its viewport",
        "func kayaRecordTableCell", "unordered-columns")
# The ROW-CELL filter, anchored on the lookup above it: the bare
# `observation.generation == generation` matches the TRACK filter
# first, which the standalone unversioned-table-track negative already
# owns.
chained("stale-cells",
        r"if let observation = table\.tableCellFrames\[key\],\n"
        r"                observation\.generation == generation\n",
        "if let observation = table.tableCellFrames[key],\n"
        "                observation.generation == generation || "
        "true\n",
        "stale cell generations accepted as current",
        "func kayaCurrentTableGeometry", "displaced-cells")
chained("stale-viewport", r"viewport\.generation == generation,",
        "viewport.generation == generation || true,",
        "a stale viewport generation accepted as current",
        "func kayaCurrentTableGeometry", "stale-cells")
chained("incomplete-geometry",
        r"if realized\.isEmpty, !table\.children\.isEmpty \{",
        "if false {",
        "a table with no realized row accepted as current",
        "func kayaCurrentTableGeometry", "stale-viewport")
geometry_src = write_doctored("incomplete-geometry")
if not build_probe(geometry_src, T / "table-geometry-doctored"):
    print("check-table-tier: SELF-TEST BROKEN — the doctored geometry "
          "probe did not compile, so the runtime negative proved "
          "nothing", file=sys.stderr)
    raise SystemExit(1)
r = subprocess.run([str(T / "table-geometry-doctored")], env=DYLD,
                   capture_output=True, text=True, check=False)
geometry_log = r.stdout + r.stderr
if r.returncode == 0:
    print("check-table-tier: SELF-TEST FAILED — chained clusters and "
          "displaced cells were accepted by the real-window probe.",
          file=sys.stderr)
    print(geometry_log, file=sys.stderr)
    raise SystemExit(1)
for diagnostic in (
    "table track overflow is rejected",
    "edge clustering is anchored to its representative",
    "column identity rejects frames borrowed from an existing cluster",
    "column representatives must remain distinct and increasing",
    "missing current row-cell geometry is rejected",
    "stale row-cell geometry is rejected",
    "a user-route model write immediately refuses the previous "
    "generation",
    "a layout invalidation rejects the previous generation",
    "live native cells stay inside the recorded viewport horizontally",
    "live native rows stay inside the recorded viewport vertically",
):
    if diagnostic not in geometry_log:
        print(f"check-table-tier: SELF-TEST FAILED — the geometry "
              f"shadow reddened, but did not name '{diagnostic}'. "
              f"Got:", file=sys.stderr)
        print(geometry_log, file=sys.stderr)
        raise SystemExit(1)
print(f"check-table-tier: self-test — identity, generation, and "
      f"containment guards all red (exit {r.returncode})")

# The runtime clause guards itself: the compact arm flipped on a COPY
# must red the probe, and the perturbation must be PROVEN applied.
# This is the arm no device can assert and the one the traps entry is
# about.
doctored["compact-native"] = perturb(
    REAL, r"case \.compact, \.unknown: return \.synthesized",
    "case .compact, .unknown: return .native",
    "the compact arm flipped to the native tier", "func kayaTableTier")
compact_src = write_doctored("compact-native")
if not build_probe(compact_src, T / "table-tier-doctored"):
    print("check-table-tier: SELF-TEST BROKEN — the doctored "
          "interpreter did not compile, so the runtime negative proved "
          "nothing", file=sys.stderr)
    raise SystemExit(1)
r = subprocess.run([str(T / "table-tier-doctored")], env=DYLD,
                   capture_output=True, text=True, check=False)
compact_log = r.stdout + r.stderr
if r.returncode == 0:
    print("check-table-tier: SELF-TEST FAILED — a compact iOS host "
          "routed to the NATIVE tier and the probe still passed. The "
          "truth table is not being driven; nothing above is a "
          "measurement.", file=sys.stderr)
    print(compact_log, file=sys.stderr)
    raise SystemExit(1)
if "iOS compact at/above the floor" not in compact_log:
    print("check-table-tier: SELF-TEST FAILED — the doctored rule was "
          "refused, but not by the compact cell. Wanted a line naming "
          "'iOS compact at/above the floor'; got:", file=sys.stderr)
    print(compact_log, file=sys.stderr)
    raise SystemExit(1)
print(f"check-table-tier: self-test — the flipped compact arm reds "
      f"the probe (exit {r.returncode})")

# CONTENT IS THE FLOOR (ruled 2026-08-26), both halves watched going
# red on the real-window probe, and the third — the re-present —
# watched reddening the static pairing clause, since ink is all that
# can see it.
doctored["unfloored-minimum"] = perturb(
    REAL, r"column\.minWidth = floors\[index\]",
    "column.minWidth = 24",
    "the measured column minimum replaced by a hard-coded 24",
    "struct KayaNativeTable > class KayaTableDriver > "
    "func layoutColumns")
runtime_refuses("unfloored-minimum",
                "no native column declares a minimum below its "
                "measured content",
                "a native column whose minimum is below its content")

doctored["unpublished-content-width"] = perturb(
    REAL,
    r"publishContentWidth\(floors\.reduce\(0, \+\) \+ 2 \* inset\)",
    "publishContentWidth(0)",
    "the measured content width published as zero",
    "struct KayaNativeTable > class KayaTableDriver > "
    "func layoutColumns")
runtime_refuses("unpublished-content-width",
                "a hugging container widens to the native table's "
                "content",
                "a native tier that reports no content width upward")

doctored["unrepresented-widening"] = perturb(
    REAL, r"if widened \{ represent\(visible\) \}",
    "if widened { _ = visible }",
    "the re-present after a widened column removed",
    "struct KayaNativeTable > class KayaTableDriver > "
    "func layoutColumns")
refuses(doctored["unrepresented-widening"],
        "does not call `represent(visible)`",
        "a widened column that never re-presents its cells")

g.verdict()
