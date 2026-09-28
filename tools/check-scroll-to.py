#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# THE SCROLL-TO RULES NO SCENE CAN SEE (docs/scroll-to-plan.md S4, S6, §3).
# tools/scenes/scrollto.steps asserts where a row LANDS, and its expects
# retry, so an arm that glides there over a second passes it as an
# instant one does (S6), and an arm that dropped the pre-layout hold would
# still pass on a backend that happens to lay out before the batch
# returns (S4). Beside them the one park both the harness verb and the
# app's command must share on the windowed tiers, so the two cannot drift
# apart by one correction cycle.

import re

SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

gate = Gate("check-scroll-to")


def block_after(text, anchor):
    at = text.find(anchor)
    if at < 0:
        return ""
    start = text.find("{", at)
    if start < 0:
        return ""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def strip_c(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return "\n".join(re.sub(r"//.*", "", ln) for ln in s.split("\n"))


def swift_findings(source):
    out = []
    src = strip_c(source)
    fn = block_after(src, "func kayaTryScrollRow(_ node: KayaNode)")
    if not fn:
        out.append(f"{SWIFT}: kayaTryScrollRow is gone — the one place a pending scroll lands")
        return out
    anchor = block_after(src, "func kayaScrollRowAnchor(_ node: KayaNode)")
    if ("proxy.scrollTo(request.copy, anchor: kayaScrollRowAnchor(scroll))" not in fn
            or "!kayaScrollHorizontal(node) ? .top :" not in anchor):
        out.append(f"{SWIFT}: the realized arm no longer scrolls the copy to the top through the "
                   f"proxy (S2), or to its leading edge on a sideways scroll "
                   f"(docs/hscroll-plan.md §2)")
    if "withAnimation" in fn:
        out.append(f"{SWIFT}: the scroll is wrapped in withAnimation — instant, never animated "
                   f"(S6)")
    # THE REALIZED ARM'S OWN HOLD, not the table branch's insert one guard up:
    # the first draft read the function for the insert by name and passed
    # with the realized hold cut out.
    if ("kayaNodeFrames[request.copy] != nil else {\n        kayaPendingRowScrolls.insert(node.id)"
            not in fn):
        out.append(f"{SWIFT}: a request the tier cannot apply yet is dropped rather than held — "
                   f"the chat's opening frame is a scroll before the first layout (S4)")
    proxy_site = src.find("kayaScrollProxies[node.id] = proxy")
    if proxy_site < 0 or "kayaDrainRowScrolls()" not in src[proxy_site:proxy_site + 200]:
        out.append(f"{SWIFT}: the scroll proxy's registration does not drain pending scrolls — a "
                   f"held request never lands (S4)")
    verb = block_after(src, "func kayaScrolledTo(_ node: KayaNode, _ key: String)")
    if "kayaNodeFrames[copy.id]" not in verb or "scrollRowRequest" in verb:
        out.append(f"{SWIFT}: expect_scrolled_to must read the copy's reported frame, never the "
                   f"request (S7)")
    return out


def gtk_findings(source):
    out = []
    src = strip_c(source)
    fn = block_after(
        src, "\nfn scroll_row(core: &mut CoreState, id: u64, copy: Option<WidgetId>, index: usize)")
    if not fn:
        out.append(f"{GTK}: scroll_row is gone — the command's one arm")
        return out
    if "park_table_row(core, id, index)" not in fn:
        out.append(f"{GTK}: the windowed arm does not take the harness's own park (§3)")
    harness = block_after(src, "fn scroll_to_row(&self, t: crate::harness::Target, key: &str)")
    if "park_table_row(core, id, index)" not in harness:
        out.append(f"{GTK}: the harness's scroll_to_row no longer shares park_table_row with the "
                   f"command — the two parks can drift by a correction cycle (§3)")
    if "adj.connect_changed(" not in fn:
        out.append(f"{GTK}: a request on content that has not laid out is dropped rather than "
                   f"held on the adjustment's `changed` (S4)")
    if "pending.get(&id) == Some(&copy.0)" not in fn:
        out.append(f"{GTK}: a held request lands whether or not it is still the container's "
                   f"latest — two holds releasing out of order put the older row on screen (S4)")
    top = block_after(src, "\nfn scroll_root_to_top(root: &gtk4::Widget)")
    if "adj.set_value(top)" not in top:
        out.append(f"{GTK}: the realized arm no longer sets the adjustment to the row's content "
                   f"top (S2)")
    verb = block_after(src, "fn scrolled_to(&self, t: crate::harness::Target, key: &str)")
    if "row_top_in_content(&root)" not in verb:
        out.append(f"{GTK}: expect_scrolled_to must read the row's bounds against the adjustment, "
                   f"never a model copy (S7)")
    return out


def winui_findings(source):
    out = []
    src = strip_c(source)
    fn = block_after(src, "\nfn scroll_row(\n    core: &mut CoreState,")
    if not fn:
        out.append(f"{WINUI}: scroll_row is gone — the command's one arm")
        return out
    if "park_table_row(core, id, index)" not in fn:
        out.append(f"{WINUI}: the windowed arm does not take the harness's own park (§3)")
    harness = block_after(src, "fn scroll_to_row(&self, t: crate::harness::Target, key: &str)")
    if "park_table_row(core, id, index)?" not in harness:
        out.append(f"{WINUI}: the harness's scroll_to_row no longer shares park_table_row with "
                   f"the command (§3)")
    if "fe.Loaded(&deferred)?" not in fn:
        out.append(f"{WINUI}: a request on an element not yet loaded is dropped rather than held "
                   f"on Loaded (S4)")
    defer = block_after(src, "\nfn defer_scroll(container: u64, copy: u64, element: UIElement)")
    if "pending.get(&container) == Some(&copy)" not in defer:
        out.append(f"{WINUI}: a held request lands whether or not it is still the container's "
                   f"latest — two holds releasing out of order put the older row on screen (S4)")
    top = block_after(src, "\nfn scroll_element_to_top(element: &UIElement)")
    along = block_after(src, "\nfn change_view_along(viewer: &ScrollViewer, sideways: bool,")
    free = re.findall(r"ChangeViewWithOptionalAnimation\([^;]*?, true\)", along)
    if "change_view_along(&viewer, sideways," not in top or len(free) != 2:
        out.append(f"{WINUI}: the realized arm's ChangeView is not the animation-free overload — "
                   f"instant, never animated (S6)")
    verb = block_after(src, "fn scrolled_to(&self, t: crate::harness::Target, key: &str)")
    if "row_top_in_content(&element)" not in verb:
        out.append(f"{WINUI}: expect_scrolled_to must read the element against the viewer, never "
                   f"a model copy (S7)")
    return out


def compose_findings(source):
    out = []
    src = strip_c(source)
    fn = block_after(src, "\nsuspend fun kayaScrollRow(node: KayaNode)")
    if not fn:
        out.append(f"{COMPOSE}: kayaScrollRow is gone — the command's one arm")
        return out
    if "scroll.scrollState.scrollTo(" not in fn or "animateScrollTo" in fn:
        out.append(f"{COMPOSE}: the realized arm must use ScrollState.scrollTo, never the animated "
                   f"form (S6)")
    if "withFrameNanos" not in fn:
        out.append(f"{COMPOSE}: the arm no longer waits for the copy's placement — a scroll before "
                   f"the first layout is dropped (S4)")
    if "it.park(index)" not in fn:
        out.append(f"{COMPOSE}: the windowed arm does not park the table window on the index (§3)")
    if not re.search(r"APPLY_SCROLL_TO_ROW -> \{[\s\S]{0,600}?scrollRowSeq \+= 1", src):
        out.append(f"{COMPOSE}: the apply arm does not bump scrollRowSeq — the effect keyed on it "
                   f"never runs (S4)")
    if "LaunchedEffect(node.scrollRowSeq)" not in src:
        out.append(f"{COMPOSE}: no effect keyed on scrollRowSeq — the request is never performed")
    verb = block_after(src, "private fun kayaScrolledTo(node: KayaNode, key: String)")
    if "kayaNodeTops[copy.id]" not in verb or "scrollRowRequest" in verb:
        out.append(f"{COMPOSE}: expect_scrolled_to must read the copy's placement, never the "
                   f"request (S7)")
    return out


ROWS = {SWIFT: swift_findings, GTK: gtk_findings, WINUI: winui_findings,
        COMPOSE: compose_findings}


# A SIDEWAYS SCROLL'S NATIVE SWITCH (docs/hscroll-plan.md §3). No scene can
# see a backend that keeps the vertical switch for a horizontal scroll: GTK's
# vertical-only policy widened the window to the strip and every verb still
# passed (the GTK arm's negative, 2026-09-28), and a shared scene may not read
# a window's size (portfolio.steps' 2026-08-28 ruling).
AXIS_SWITCH = {
    SWIFT: ("ScrollView(sideways ? .horizontal : .vertical)",),
    GTK: ("sw.set_policy(gtk4::PolicyType::Automatic, gtk4::PolicyType::Never);",),
    WINUI: ("let (h, v) = if sideways { (along, across) } else { (across, along) };",
            "viewer.SetHorizontalScrollMode(h.0)?;"),
    COMPOSE: ("viewport.horizontalScroll(node.scrollState)",),
}


def axis_switch(texts):
    out = []
    for rel, needles in AXIS_SWITCH.items():
        src = strip_c(texts[rel])
        for needle in needles:
            if needle not in src:
                out.append(f"{rel}: a sideways scroll's native switch is gone "
                           f"(`{needle}`), so a horizontal scroll scrolls vertically "
                           f"or widens its window (docs/hscroll-plan.md §3)")
    return out


def census(texts):
    out = []
    for rel, row in ROWS.items():
        out.extend(row(texts[rel]))
    out.extend(axis_switch(texts))
    return out


REAL = {rel: gate.read(rel) for rel in ROWS}


def watched(label, texts, want):
    gate.negative(label, lambda: census(texts), want=want)


n1 = gate.doctor("the swift scroll wrapped in withAnimation", REAL[SWIFT],
                 r"    proxy\.scrollTo\(request\.copy, "
                 r"anchor: kayaScrollRowAnchor\(scroll\)\)\n",
                 "    withAnimation { proxy.scrollTo(request.copy, "
                 "anchor: kayaScrollRowAnchor(scroll)) }\n")
watched("a SwiftUI scroll that glides", {**REAL, SWIFT: n1}, "never animated")
n2 = gate.doctor("the swift hold cut", REAL[SWIFT],
                 r"    guard let proxy = kayaScrollProxies\[scroll\.id\], "
                 r"kayaNodeFrames\[request\.copy\] != nil else \{\n"
                 r"        kayaPendingRowScrolls\.insert\(node\.id\)\n        return\n    \}\n",
                 "    guard let proxy = kayaScrollProxies[scroll.id] else { return }\n")
watched("a SwiftUI request dropped before layout", {**REAL, SWIFT: n2}, "dropped rather than held")
n3 = gate.doctor("the swift proxy registration no longer draining", REAL[SWIFT],
                 r"(kayaScrollProxies\[node\.id\] = proxy\n\s*)kayaDrainRowScrolls\(\)\n", r"\1")
watched("a SwiftUI proxy that never drains", {**REAL, SWIFT: n3}, "does not drain")
n4 = gate.doctor("the gtk hold cut", REAL[GTK], r"let handler = adj\.connect_changed\(",
                 "let handler = adj.connect_value_changed(")
watched("a GTK request dropped before layout", {**REAL, GTK: n4}, "dropped rather than held")
n5 = gate.doctor("the gtk harness park unshared", REAL[GTK],
                 r"            park_table_row\(core, id, index\);\n            String::new\(\)\n",
                 "            let _ = index;\n            String::new()\n")
watched("a GTK harness verb with its own park", {**REAL, GTK: n5},
        "no longer shares park_table_row")
n6 = gate.doctor("the gtk top write cut", REAL[GTK],
                 r"        adj\.set_value\(top\);\n",
                 "        let _ = top;\n")
watched("a GTK realized arm that moves nothing", {**REAL, GTK: n6}, "no longer sets the adjustment")
n7 = gate.doctor("the winui animation switched on", REAL[WINUI],
                 r"(viewer\.ChangeViewWithOptionalAnimation\(&at, None::<&IReference<f64>>, "
                 r"None::<&IReference<f32>>, )true\)", r"\1false)")
watched("a WinUI scroll that glides", {**REAL, WINUI: n7}, "never animated")
n8 = gate.doctor("the winui hold cut", REAL[WINUI],
                 r"    fe\.Loaded\(&deferred\)\?;\n    Ok\(\(\)\)\n\}\n",
                 "    let _ = deferred;\n    Ok(())\n}\n")
watched("a WinUI request dropped before Loaded", {**REAL, WINUI: n8}, "dropped rather than held")
n9 = gate.doctor("the winui harness park unshared", REAL[WINUI],
                 r"            park_table_row\(core, id, index\)\?;\n"
                 r"            Ok\(String::new\(\)\)\n",
                 "            let _ = index;\n            Ok(String::new())\n")
watched("a WinUI harness verb with its own park", {**REAL, WINUI: n9},
        "no longer shares park_table_row")
n10 = gate.doctor("the compose scroll animated", REAL[COMPOSE], r"scroll\.scrollState\.scrollTo\(",
                  "scroll.scrollState.animateScrollTo(")
watched("a Compose scroll that glides", {**REAL, COMPOSE: n10}, "never the animated form")
n11 = gate.doctor("the compose placement wait cut", REAL[COMPOSE],
                  r"    while \(frames < 120 &&\n[\s\S]*?\) \{\n"
                  r"        withFrameNanos \{ \}\n        frames \+= 1\n    \}\n", "")
watched("a Compose request that never waits for layout", {**REAL, COMPOSE: n11}, "dropped")
n12 = gate.doctor("the compose apply arm no longer bumping the sequence", REAL[COMPOSE],
                  r"                    container\.scrollRowSeq \+= 1\n", "")
watched("a Compose request whose effect never runs", {**REAL, COMPOSE: n12},
        "does not bump scrollRowSeq")
n14 = gate.doctor("the gtk latest-wins check cut", REAL[GTK],
                  r"pending\.get\(&id\) == Some\(&copy\.0\)", "true")
watched("a GTK held request landing out of order", {**REAL, GTK: n14},
        "still the container's latest")
n15 = gate.doctor("the winui latest-wins check cut", REAL[WINUI],
                  r"pending\.get\(&container\) == Some\(&copy\)", "true")
watched("a WinUI held request landing out of order", {**REAL, WINUI: n15},
        "still the container's latest")
n13 = gate.doctor("the compose verb reading the request", REAL[COMPOSE],
                  r'        val rowTop = kayaNodeTops\[copy\.id\] \?: '
                  r'return "row \\"\$key\\" has no placement yet"\n',
                  '        val rowTop = node.scrollRowRequest?.second?.toFloat() '
                  '?: return "no request"\n')
watched("a Compose reading off the request", {**REAL, COMPOSE: n13}, "never the request")

for n, (rel, needle) in enumerate(((SWIFT, "sideways ? .horizontal : .vertical"),
                                    (GTK, "PolicyType::Automatic, gtk4::PolicyType::Never);\n"
                                          "                    } else"),
                                    (WINUI, "if sideways { (along, across) }"),
                                    (COMPOSE, "viewport.horizontalScroll(node.scrollState)"))):
    cut = gate.doctor(f"the {rel} axis switch cut", REAL[rel], re.escape(needle),
                      {SWIFT: ".vertical",
                       GTK: "PolicyType::Never, gtk4::PolicyType::Automatic);\n"
                            "                    } else",
                       WINUI: "if sideways { (across, along) }",
                       COMPOSE: "viewport.verticalScroll(node.scrollState)"}[rel])
    watched(f"a sideways scroll on the vertical switch ({rel})", {**REAL, rel: cut},
            "native switch is gone")

gate.negatives_ran(19)

for line in census(REAL):
    gate.finding(line)

gate.verdict("scroll_to_row lands instantly, holds until layout and shares the tiers' park on "
             "every backend")
