"""docs/expander-plan.md K5, K8, K15: the expander's reads and press, held
where no scene can see them go.

expander.steps writes `expanded` from the app and reads it back, and presses
the header and reads the app's answer, so an arm that ignores either direction
is red on its lane. But a read that answered from kaya's model agrees with
every write, a press that wrote the model and emitted by hand passes every
toggle while the screen shows anything, and a harness that stopped refusing a
step aimed inside a collapsed body reads straight through it on the mac,
where the model keeps what the screen dropped. A backend whose
`depth_stub("expander")` goes must take a row in BACKENDS."""

import re

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
STUBBED = {GTK: 'depth_stub("expander")', WINUI: 'depth_stub("expander")', COMPOSE: 'depthStub("expander")'}
BACKENDS = {SWIFT: "the SwiftUI arm", COMPOSE: "the Compose arm", GTK: "the GTK arm", WINUI: "the WinUI arm"}
MODEL = r"node\.expanded|node\.summary|node\.laidOut|node\.children"
ARM = ("struct KayaExpander: View {", [
    "DisclosureGroup(isExpanded: open)",
    "get: { node.expanded },",
    "kayaUserWrite { node.expanded = now }",
    "KayaHost.emitToggled(node.tag, now)",
    ".background(KayaExpanderAnchor(id: node.id, header: true, open: open.wrappedValue))",
    ".background(KayaExpanderAnchor(id: node.id, header: false))",
    ".accessibilityElement(children: .ignore)",
    "kayaA11y(header, node, leaf: true).accessibilityAction { open.wrappedValue.toggle() }",
])
# (label, opener, which definition, what it must hold, whether it may reach the model)
READS = [
    ("the mac header read", "func kayaExpanderHeaderRead(", 0,
     ["(kayaExpanderHeaders[node.id] ?? [])", "AXUIElementCopyElementAtPosition(",
      'if role == "AXDisclosureTriangle" {', "kayaAxCopy(element, kAXValueAttribute) as? NSNumber",
      "open: value.intValue == 1,",
      "press: { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }"]),
    ("the iOS header read", "func kayaExpanderHeaderRead(", 1,
     ["(kayaExpanderHeaders[node.id] ?? [])", "kayaExpanderButton(anchor)", "let status = button.accessibilityExpandedStatus",
      "open: status == .expanded,", "press: { button.accessibilityActivate() }"]),
    ("the body read", "private func kayaExpanderBodyShown(", 0,
     ["kayaExpanderBodies[node.id]", "window.isVisible"]),
    ("expect_expanded", "func kayaExpanderReadSpec(", 0,
     ["kayaExpanderHeaderRead(node)", "kayaExpanderBodyShown(node)"]),
    ("the press", "func kayaExpanderPress(", 0, ["kayaExpanderHeaderRead(node)", "header.press()"]),
    ("the K5 reading", "func kayaCollapsedAncestor(", 0, ["kayaExpanderHeaderRead(expander)", "!header.open"]),
]
CALLS = [
    (SWIFT, "the app's write reaches the arm",
     "case (propExpanded, valueBool):\n                    kayaScene.nodes[id]!.expanded = raw[body + 24] != 0"),
    (SWIFT, "the props ride the header, never the container", "} else if node.kind == kindExpander && !leaf {"),
    (SWIFT, "toggle presses the header", "let unpressed = kayaExpanderPress(parts[1], parts[2] == \"on\")"),
    (SWIFT, "the K5 refusal runs before every step",
     "let hidden = kayaCollapsedAncestor(parts[1])\n            {\n                failures.append(kayaOutOfReach(hidden))"),
    (SWIFT, "the header reads as a button", 'case "AXDisclosureTriangle": return "button"'),
    (SWIFT, "the header's text observed bare, as harness.rs and Compose observe it",
     "if kayaBytesEqual(gotHeader, wantHeader) {\n observed.append(wantHeader)"),
    (HARNESS, "harness.rs refuses a step aimed inside a collapsed expander",
     ".find_map(|t| stage.collapsed_ancestor(*t))\n                .map(out_of_reach);"),
    (HARNESS, "harness.rs reads both halves",
     "Step::ExpectExpanded(t, want) => Some(poll(|| expanded_reading(stage.expanded(*t), *want))),"),
]
COMPOSE_ARM = ("internal fun KayaExpander(", [
    "kayaExpanderFlip(node, !node.expanded)",
    "AnimatedVisibility(visible = open,",
    "stateDescription = state",
    "if (open) collapse { kayaExpanderFlip(node, false) } else expand { kayaExpanderFlip(node, true) }",
    "this[KayaNodeId] = node.id",
    "this[KayaExpanderBody] = node.id",
    ".then(a11y)",
    "if (node.a11yLabel.isEmpty()) contentDescription = node.text",
    "onClickLabel = press",
    "val press = node.a11yHint.ifEmpty { null }\n        ?: kayaExpanderActionWord(",
    "supportingContent = if (node.summary.isEmpty()) null else { { Text(node.summary) } },",
])
COMPOSE_READS = [
    ("the Compose header read", "private fun kayaExpanderHeaderRead(",
     ["kayaTaggedNode(root.semanticsOwner.rootSemanticsNode, node.id)", "cfg.contains(SemanticsActions.Collapse)",
      "cfg.contains(SemanticsActions.Expand)", "cfg.getOrNull(SemanticsProperties.StateDescription)",
      "cfg.getOrNull(SemanticsActions.OnClick)?.action", "cfg.getOrNull(SemanticsProperties.Text)",
      "(lines.filter { it != name } + listOfNotNull(hint)).joinToString(\". \")"]),
    ("the Compose body read", "private fun kayaExpanderBodyShown(",
     ["at.config.getOrNull(KayaExpanderBody) == node.id",
      "found.any { it.layoutInfo.isAttached && it.size.height > 0 }"]),
    ("Compose's expect_expanded", "private fun kayaExpanderReadSpec(",
     ["kayaExpanderHeaderRead(activity, node)", "kayaExpanderBodyShown(activity, node)"]),
    ("the Compose press", "private fun kayaExpanderPress(", ["kayaExpanderHeaderRead(activity, node)", "header.press()"]),
    ("the Compose K5 reading", "private fun kayaCollapsedAncestor(",
     ["kayaExpanderHeaderRead(activity, expander).first?.open == false"]),
]
CALLS += [
    (COMPOSE, "the app's write reaches the Compose arm",
     "PROP_EXPANDED -> KayaSceneModel.nodes[id]!!.expanded = readBool(b)"),
    (COMPOSE, "the Compose K5 refusal runs before every step",
     "val hidden = kayaCollapsedAncestor(activity, parts[1])\n if (hidden != null) {\n failures.add(kayaOutOfReach(hidden))"),
    (COMPOSE, "Compose's toggle presses the header", 'kayaExpanderPress(activity, parts[1], parts[2] == "on")'),
    (COMPOSE, "the Compose hint rides the expander's description, not twice",
     "if (node.a11yHint.isNotEmpty() && node.kind != KayaCompose.KIND_EXPANDER) {"),
    (SWIFT, "the SwiftUI header's hint is the expander's description",
     "let hint = node.kind == kindExpander ? kayaExpanderDescription(node) : node.a11yHint"),
]
# The two widget backends (docs/expander-plan.md §3): (backend, label, opener,
# what the block must hold, what it may never name).
WIDGET_ROWS = [
    (GTK, "the GTK arm", "WidgetKind::Expander => {",
     ["x.free.connect_expanded_notify(move |e| {", "x.row.connect_expanded_notify(move |r| {", "if !quiet.get() {",
      "sink.send_toggle_tag(&tag, e.is_expanded());", "sink.send_toggle_tag(&tag, r.is_expanded());"], []),
    (GTK, "the GTK app write", "(NativeWidget::Expander(x), Prop::Expanded, Value::Bool(open)) => {",
     ["core.apply_quiet.set(true);", "x.free.set_expanded(open);", "x.row.set_expanded(open);",
      "core.apply_quiet.set(was);"], ["send_toggle_tag"]),
    (GTK, "the GTK summary", "(NativeWidget::Expander(x), Prop::Summary, Value::Str(s)) => {",
     ["x.summary.set_label(&s);", "set_subtitle(&x.row, &s);", "expander_describe(x);"], []),
    (GTK, "the GTK header read", "fn expanded(&self, t: crate::harness::Target) -> Result<(bool, bool), String> {",
     ["list_item_rank(&core.window, &header)", "atspi_rank(&core.window, &header)", "x.free_body.is_mapped()",
      "atspi_states(role, rank)", "Ok((states.contains(atspi::State::Expanded), shown))"],
     ["is_expanded()", "send_toggle_tag", "set_expanded("]),
    (GTK, "the GTK press", "fn toggle(&self, t: crate::harness::Target, on: bool) {",
     ['atspi_act(atspi::Role::Button, rank, "activate")', "x.row_header.activate();"],
     ["send_toggle_tag", "set_expanded("]),
    (GTK, "the GTK K5 reading", "fn collapsed_ancestor(&self, t: crate::harness::Target) -> Option<usize> {",
     ["!x.is_expanded()", "x.free_body.upcast_ref::<gtk4::Widget>()"], ["set_expanded("]),
    (GTK, "the GTK spoken summary's read", "if target.kind == K::Expander {",
     ["atspi_collect(role, rank, true)"], []),
    (WINUI, "the WinUI arm", "WidgetKind::Expander => {",
     ["expander.Expanding(", "expander.Collapsed(", "if !quiet.load(std::sync::atomic::Ordering::Relaxed) {",
      "sink.send_toggle_tag(&tag, open);"], []),
    (WINUI, "the WinUI app write", "(NativeWidget::Expander { expander, .. }, Prop::Expanded, Value::Bool(open)) => {",
     ["core.apply_quiet.store(true, std::sync::atomic::Ordering::Relaxed);", "expander.SetIsExpanded(open);",
      "core.apply_quiet.store(false, std::sync::atomic::Ordering::Relaxed);"], ["send_toggle_tag"]),
    (WINUI, "the WinUI summary", "(NativeWidget::Expander { summary, .. }, Prop::Summary, Value::Str(s)) => {",
     ["summary.SetText(&HSTRING::from(&s))?;", "expander_describe(core, id)?;"], []),
    (WINUI, "the WinUI header read", "fn expanded(&self, t: crate::harness::Target) -> Result<(bool, bool), String> {",
     ["peer.cast::<IExpandCollapseProvider>()", "pattern.ExpandCollapseState()? == ExpandCollapseState::Expanded",
      "shown_peer.IsOffscreen()?"], ["IsExpanded()", "SetIsExpanded", "send_toggle_tag"]),
    (WINUI, "the WinUI press", "fn toggle(&self, t: crate::harness::Target, on: bool) {",
     ["peer.cast::<IExpandCollapseProvider>()?", "if on { pattern.Expand() } else { pattern.Collapse() }"],
     ["SetIsExpanded", "send_toggle_tag"]),
    (WINUI, "the WinUI K5 reading", "fn collapsed_ancestor(&self, t: crate::harness::Target) -> Option<usize> {",
     ["core.tree_parent.get(&node)", "!core.expanders[i].IsExpanded()?"], ["SetIsExpanded"]),
    (WINUI, "the WinUI header Narrator focuses", "fn expander_header_sync(expander: &Expander) -> windows_core::Result<()> {",
     ['named_descendant(&expander.cast::<UIElement>()?, "ExpanderHeader")?',
      "AutomationProperties::SetName(&header, &AutomationProperties::GetName(expander)?)?;",
      "AutomationProperties::SetHelpText(&header, &AutomationProperties::GetHelpText(expander)?)"], []),
    (WINUI, "the WinUI spoken summary's read", "fn ax_hint(&self, target: crate::harness::Target) -> String {",
     ['Some(element) => match named_descendant(&element, "ExpanderHeader")? {'], []),
    # docs/expander-plan.md §7 (2026-10-09): iOS states the header through
    # UIKit's own expanded status, which VoiceOver speaks in the user's
    # language, and speaks the summary as the header's value.
    (SWIFT, "the iOS header label", "@ViewBuilder private func kayaExpanderLabel(",
     ["kayaA11y(header.accessibilityValue(node.summary), node, leaf: true)"], ['"expanded" :', '"collapsed"']),
    (SWIFT, "the iOS status publisher", "func kayaExpanderPublish(_ anchor: UIView, _ open: Bool) {",
     ["guard #available(iOS 18.0, *) else { return }", "box.open = open", "kayaExpanderSettle(anchor, tries: 8)"], []),
    (SWIFT, "the iOS status settle", "private func kayaExpanderSettle(_ anchor: UIView, tries: Int) {",
     ["kayaExpanderButton(anchor).0?.accessibilityExpandedStatus = box.open ? .expanded : .collapsed",
      "kayaAxAutomationOn"], ["node."]),
    (SWIFT, "the iOS anchor", "struct KayaExpanderAnchor: UIViewRepresentable {",
     ["func makeUIView(context: Context) -> UIView {", "if header { kayaExpanderPublish(view, open) }"], []),
    (SWIFT, "an assistive client's start republishing", "private func kayaAxEnableAutomation() {",
     ["DispatchQueue.main.async { kayaExpanderRepublish() }"], []),
    (SWIFT, "the iOS spoken summary's read", "private func kayaAxHintRead(_ identifier: String, description: Bool = false)",
     ['[hit.accessibilityValue ?? "", hit.accessibilityHint ?? ""]'], []),
    # The click's label says what the press does (docs/expander-plan.md K13, §7).
    (COMPOSE, "the Compose press's own word", "internal fun kayaExpanderActionWord(",
     ['if (open) "expand_button_content_description_expanded" else "expand_button_content_description_collapsed"',
      'context.resources.getIdentifier('], ["node."]),
]
# The maintainer's ruling of 2026-10-09 (docs/expander-plan.md K3): the summary
# is spoken, as the header's description, an app's hint after it.
SPOKEN = [
    (SWIFT, "func kayaExpanderDescription(", '[node.summary, node.a11yHint].filter { !$0.isEmpty }.joined(separator: ". ")'),
    (GTK, "fn expander_describe(x: &GtkExpanderParts) {", '[summary.as_str(), hint.as_str()]'),
    (GTK, "fn expander_describe(x: &GtkExpanderParts) {", "gtk4::accessible::Property::Description(&said)"),
    (WINUI, "fn expander_describe(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {",
     '[summary.as_str(), hint.as_str()]'),
    (WINUI, "fn expander_describe(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {",
     "AutomationProperties::SetHelpText("),
]
# Sentences both harnesses print, compared with their interpolations flattened.
SENTENCES = ["the target is out of reach inside collapsed expander#",
             "the target is within reach, wanted out of reach inside a collapsed expander",
             "the header reads expanded but the body is not shown",
             "the header reads collapsed but the body is shown",
             "out of reach inside expander#"]


def sentence(text, lead):
    rust = re.search(r'"(' + re.escape(lead) + r'(?:[^"\\]|\\.)*)"', text, re.S)
    if rust is None:
        return None
    said = re.sub(r"\\\n\s*", "", rust.group(1))
    return re.sub(r"\$\{[^}]*\}|\$\w+|\{[^}]*\}|\\\([^)]*\)", "<v>", said)


def findings(sources, backends=None):
    backends = BACKENDS if backends is None else backends
    out = []
    swift = sources[SWIFT]
    opener, needs = ARM
    body = blocks(swift, opener)
    if len(body) != 1:
        out.append(f"expander: {opener} is defined {len(body)} times, wanted once")
    else:
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"expander: the SwiftUI arm lacks {need.splitlines()[0]} — the platform could "
                           f"show a state the app never wrote, or a flip nobody hears")
        if body[0].count("emitToggled(") != 1:
            out.append(f"expander: the SwiftUI arm emits from {body[0].count('emitToggled(')} sites, "
                       f"wanted the isExpanded binding's set alone")
    for label, opener, at, wants in READS:
        found = blocks(swift, opener)
        if len(found) <= at:
            out.append(f"expander: {label} is gone — {SWIFT} lacks {opener}")
            continue
        for want in wants:
            if flat(want) not in flat(found[at]):
                out.append(f"expander: {label} lacks {want[:70]} — it no longer reads or presses the "
                           f"platform's own header")
        if re.search(MODEL, found[at]):
            out.append(f"expander: {label} reaches kaya's model, so it could answer from what kaya "
                       f"asked for instead of what the platform shows")
        if re.search(r"emitToggled|node\.expanded\s*=", found[at]):
            out.append(f"expander: {label} writes the model or emits by hand")
    if COMPOSE in backends:
        kotlin = sources[COMPOSE]
        opener, needs = COMPOSE_ARM
        body = blocks(kotlin, opener)
        if len(body) != 1:
            out.append(f"expander: {opener} is defined {len(body)} times, wanted once")
        else:
            for need in needs:
                if flat(need) not in flat(body[0]):
                    out.append(f"expander: the Compose arm lacks {need} — the platform could show a state "
                               f"the app never wrote, or a flip nobody hears")
            if "emitToggled(" in body[0]:
                out.append("expander: the Compose arm emits outside kayaExpanderFlip")
        flip = blocks(kotlin, "internal fun kayaExpanderFlip(")
        if len(flip) != 1 or flip[0].count("KayaPresent.emitToggled(node.tag, open)") != 1:
            out.append("expander: kayaExpanderFlip no longer emits toggled once, the header's one door")
        for label, opener, wants in COMPOSE_READS:
            found = blocks(kotlin, opener)
            if len(found) != 1:
                out.append(f"expander: {label} is gone — {COMPOSE} lacks {opener}")
                continue
            for want in wants:
                if flat(want) not in flat(found[0]):
                    out.append(f"expander: {label} lacks {want[:70]} — it no longer reads or presses the "
                               f"platform's own header")
            if re.search(MODEL, found[0]):
                out.append(f"expander: {label} reaches kaya's model, so it could answer from what kaya "
                           f"asked for instead of what the platform shows")
            if re.search(r"emitToggled|kayaExpanderFlip|node\.expanded\s*=", found[0]):
                out.append(f"expander: {label} writes the model or emits by hand")
    for rel, label, opener, wants, never in WIDGET_ROWS:
        if rel not in backends:
            continue
        found = sorted(blocks(sources[rel], opener), key=lambda b: -sum(flat(w) in flat(b) for w in wants))
        if not found:
            out.append(f"expander: {label} is gone — {rel} has no {opener}")
            continue
        for want in wants:
            if flat(want) not in flat(found[0]):
                out.append(f"expander: {label} lacks {want[:70]} — it no longer reads, presses or hears the "
                           f"platform's own header")
        for name in never:
            if name in found[0]:
                out.append(f"expander: {label} names {name} — it writes the platform's state or emits by hand")
        if any("send_toggle_tag(" in w for w in wants):
            emits = found[0].count("send_toggle_tag(")
            want_emits = sum("send_toggle_tag(" in w for w in wants)
            if emits != want_emits:
                out.append(f"expander: {label} emits from {emits} sites, wanted {want_emits}")
    for rel, opener, join in SPOKEN:
        found = blocks(sources[rel], opener)
        if len(found) != 1 or flat(join) not in flat(found[0]):
            out.append(f"expander: {rel}'s {opener} no longer joins the summary into the header's "
                       f"description — a summary drawn but not spoken")
    for rel, label, call in CALLS:
        if flat(call) not in flat(sources[rel]):
            out.append(f"expander: {label} no longer holds — {rel} lacks {call.splitlines()[0]}")
    for lead in SENTENCES:
        said = {rel: sentence(sources[rel], lead) for rel in (HARNESS, SWIFT, COMPOSE)}
        if None in said.values() or len(set(said.values())) != 1:
            out.append(f"expander: the three harnesses no longer say one sentence for {lead!r} "
                       f"(harness.rs {said[HARNESS]!r}, SwiftUI {said[SWIFT]!r}, Compose {said[COMPOSE]!r}) — "
                       f"the verdicts must be the same bytes")
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in backends:
            out.append(f"expander: {rel} no longer stubs the expander and has no row in "
                       f"tools/lib/expander_routes.py's BACKENDS")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in [HARNESS, SWIFT, *STUBBED]}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("expander clauses held",
              len(ARM[1]) + 1 + sum(len(w) + 2 for *_, w in READS) + len(CALLS) + len(SENTENCES)
              + len(COMPOSE_ARM[1]) + 2 + sum(len(w) + 2 for *_, w in COMPOSE_READS) + len(SPOKEN)
              + sum(len(w) + len(n) for *_, w, n in WIDGET_ROWS), floor=80)
    g.counted("expander backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("the arm bound to a constant", SWIFT, r"get: \{ node\.expanded \},", "get: { false },",
         "the SwiftUI arm lacks get: { node.expanded }"),
        ("the user's flip unheard", SWIFT, r"\n\s+KayaHost\.emitToggled\(node\.tag, now\)", "",
         "emits from 0 sites"),
        ("the app's write never reaching the arm", SWIFT,
         r"case \(propExpanded, valueBool\):\n(\s+)kayaScene\.nodes\[id\]!\.expanded = raw\[body \+ 24\] != 0",
         r"case (propExpanded, valueBool):\n\1_ = raw[body + 24]", "the app's write reaches the arm"),
        ("the mac header read off the model", SWIFT, r"open: value\.intValue == 1,", "open: node.expanded,",
         "the mac header read reaches kaya's model"),
        ("the body read off the model", SWIFT,
         r"(private func kayaExpanderBodyShown\(_ node: KayaNode\) -> Bool \{\n)",
         r"\1    if node.expanded { return true }\n", "the body read reaches kaya's model"),
        ("the press a model write", SWIFT, r"return header\.press\(\) \? nil :",
         "node.expanded = open; KayaHost.emitToggled(node.tag, open); return nil;",
         "the press writes the model or emits by hand"),
        ("the K5 refusal cut from the SwiftUI runner", SWIFT,
         r"\{\n(\s+)failures\.append\(kayaOutOfReach\(hidden\)\)\n(\s+)continue\n", r"{\n\2_ = hidden\n",
         "the K5 refusal runs before every step"),
        ("the K5 sentence reworded in Swift", SWIFT, r"the target is out of reach inside collapsed expander#",
         "the target is hidden inside collapsed expander#", "no longer say one sentence"),
        ("the header's text observed quoted on SwiftUI", SWIFT, r"observed\.append\(wantHeader\)",
         'observed.append("\\"\\(wantHeader)\\"")', "the header's text observed bare"),
        ("the props on the container", SWIFT, r"\} else if node\.kind == kindExpander && !leaf \{",
         "} else if false && !leaf {", "the props ride the header"),
        ("the form row with no press", SWIFT, r"\.accessibilityAction \{ open\.wrappedValue\.toggle\(\) \}", "",
         "the SwiftUI arm lacks kayaA11y(header, node, leaf: true).accessibilityAction"),
        ("the Compose flip unheard", COMPOSE, r"\n\s+KayaPresent\.emitToggled\(node\.tag, open\)", "",
         "kayaExpanderFlip no longer emits toggled once"),
        ("the Compose header read off the model", COMPOSE,
         r"val collapses = cfg\.contains\(SemanticsActions\.Collapse\)", "val collapses = node.expanded",
         "the Compose header read reaches kaya's model"),
        ("the Compose body read off the model", COMPOSE,
         r"return found\.any \{ it\.layoutInfo\.isAttached && it\.size\.height > 0 \}", "return node.expanded",
         "the Compose body read reaches kaya's model"),
        ("the Compose body read by presence alone", COMPOSE, r"it\.layoutInfo\.isAttached && it\.size\.height > 0",
         "it.layoutInfo.isAttached", "the Compose body read lacks found.any { it.layoutInfo.isAttached && it.size"),
        ("the Compose press a model write", COMPOSE, r'header\.press\(\) -> ""', 'kayaExpanderFlip(node, open) -> ""',
         "the Compose press writes the model or emits by hand"),
        ("the K5 refusal cut from the Compose runner", COMPOSE,
         r"if \(hidden != null\) \{\n(\s+)failures\.add\(kayaOutOfReach\(hidden\)\)", r"if (hidden != null) {\n\1_ = hidden",
         "the Compose K5 refusal runs before every step"),
        ("the K5 sentence reworded in Kotlin", COMPOSE, r"the target is out of reach inside collapsed expander#\$index",
         "the target is hidden inside collapsed expander#$index", "no longer say one sentence"),
        ("the Compose state bound to a constant", COMPOSE, r"stateDescription = state\b", 'stateDescription = "collapsed"',
         "the Compose arm lacks stateDescription = state"),
        ("the app's write never reaching the Compose arm", COMPOSE,
         r"PROP_EXPANDED -> KayaSceneModel\.nodes\[id\]!!\.expanded = readBool\(b\)", "PROP_EXPANDED -> readBool(b)",
         "the app's write reaches the Compose arm"),
        ("the Compose body shown whatever the state", COMPOSE, r"AnimatedVisibility\(visible = open,",
         "AnimatedVisibility(visible = true,", "the Compose arm lacks AnimatedVisibility(visible = open,"),
        ("a summary drawn but not spoken on SwiftUI", SWIFT, r"\[node\.summary, node\.a11yHint\]", "[node.a11yHint]",
         "a summary drawn but not spoken"),
        ("a summary drawn but not spoken on Compose", COMPOSE,
         r"supportingContent = if \(node\.summary\.isEmpty\(\)\) null else \{ \{ Text\(node\.summary\) \} \},",
         "supportingContent = null,", "the Compose arm lacks supportingContent"),
        ("the iOS summary not spoken", SWIFT, r"kayaA11y\(header\.accessibilityValue\(node\.summary\), node, leaf: true\)",
         "kayaA11y(header, node, leaf: true)", "the iOS header label lacks kayaA11y(header.accessibilityValue"),
        ("the iOS state in English", SWIFT, r"kayaA11y\(header\.accessibilityValue\(node\.summary\), node, leaf: true\)",
         'kayaA11y(header.accessibilityValue(open.wrappedValue ? "expanded" : "collapsed"), node, leaf: true)',
         'the iOS header label names "expanded" :'),
        ("the iOS status bound to a constant", SWIFT,
         r"accessibilityExpandedStatus = box\.open \? \.expanded : \.collapsed", "accessibilityExpandedStatus = .collapsed",
         "the iOS status settle lacks kayaExpanderButton(anchor).0?.accessibilityExpandedStatus = box.open"),
        ("the iOS header read off the value", SWIFT, r"open: status == \.expanded,",
         'open: button.accessibilityValue == "expanded",', "the iOS header read lacks open: status == .expanded,"),
        ("the iOS status not republished for a late client", SWIFT,
         r"\n\s+DispatchQueue\.main\.async \{ kayaExpanderRepublish\(\) \}", "",
         "an assistive client's start republishing lacks"),
        ("the iOS summary read off the hint alone", SWIFT,
         r'\[hit\.accessibilityValue \?\? "", hit\.accessibilityHint \?\? ""\]', '[hit.accessibilityHint ?? ""]',
         "the iOS spoken summary's read lacks"),
        ("the SwiftUI header's hint without its summary", SWIFT,
         r"let hint = node\.kind == kindExpander \? kayaExpanderDescription\(node\) : node\.a11yHint",
         "let hint = node.a11yHint", "the SwiftUI header's hint is the expander's description"),
        ("the Compose click label saying the summary", COMPOSE, r"onClickLabel = press\)",
         "onClickLabel = node.summary)", "the Compose arm lacks onClickLabel = press"),
        ("the Compose press word off the framework", COMPOSE, r'"expand_button_content_description_collapsed"',
         '"collapsed"', "the Compose press's own word lacks"),
        ("the Compose description off the header's lines", COMPOSE,
         r'\(lines\.filter \{ it != name \} \+ listOfNotNull\(hint\)\)\.joinToString\("\. "\)', 'listOfNotNull(hint).joinToString(". ")',
         "the Compose header read lacks (lines.filter"),
        ("the GTK user's flip unheard", GTK, r"\n\s+sink\.send_toggle_tag\(&tag, r\.is_expanded\(\)\);", "",
         "the GTK arm lacks sink.send_toggle_tag(&tag, r.is_expanded());"),
        ("the GTK app write echoing", GTK,
         r"(Prop::Expanded, Value::Bool\(open\)\) => \{\n\s+use adw::prelude::ExpanderRowExt;\n\s+let was = core\.apply_quiet\.get\(\);\n\s+)core\.apply_quiet\.set\(true\);",
         r"\1", "the GTK app write lacks core.apply_quiet.set(true);"),
        ("the GTK header read off GTK's own property", GTK,
         r"Ok\(\(states\.contains\(atspi::State::Expanded\), shown\)\)", "Ok((shown, shown))",
         "the GTK header read lacks Ok((states.contains"),
        ("a summary drawn but not spoken on GTK", GTK,
         r"(adw::prelude::ExpanderRowExt::set_subtitle\(&x\.row, &s\);\n)\s+expander_describe\(x\);\n", r"\1",
         "the GTK summary lacks expander_describe(x);"),
        ("the GTK form press a model write", GTK, r"x\.row_header\.activate\(\);",
         "adw::prelude::ExpanderRowExt::set_expanded(&x.row, on);", "the GTK press names set_expanded("),
        ("the WinUI user's flip unheard", WINUI, r"\n\s+sink\.send_toggle_tag\(&tag, open\);", "",
         "the WinUI arm lacks sink.send_toggle_tag(&tag, open);"),
        ("the WinUI app write echoing", WINUI,
         r"core\.apply_quiet\.store\(true, std::sync::atomic::Ordering::Relaxed\);\n(\s+)let write = expander\.SetIsExpanded",
         r"let write = expander.SetIsExpanded", "the WinUI app write lacks core.apply_quiet.store(true"),
        ("the WinUI header read off the control's property", WINUI,
         r"pattern\.ExpandCollapseState\(\)\? == ExpandCollapseState::Expanded", "core.expanders[i].IsExpanded()?",
         "the WinUI header read lacks pattern.ExpandCollapseState()"),
        ("a summary drawn but not spoken on WinUI", WINUI,
         r"(summary\.SetVisibility\(if s\.is_empty\(\) \{ Visibility::Collapsed \} else \{ Visibility::Visible \}\)\?;\n)\s+expander_describe\(core, id\)\?;\n",
         r"\1", "the WinUI summary lacks expander_describe(core, id)?;"),
        ("the WinUI press a control write", WINUI, r"if on \{ pattern\.Expand\(\) \} else \{ pattern\.Collapse\(\) \}",
         "core.expanders[i].SetIsExpanded(on)", "the WinUI press lacks if on { pattern.Expand()"),
        ("the WinUI header left unnamed and unspoken", WINUI,
         r"\n\s+AutomationProperties::SetHelpText\(&header, &AutomationProperties::GetHelpText\(expander\)\?\)", "\n    Ok(())",
         "the WinUI header Narrator focuses lacks AutomationProperties::SetHelpText(&header"),
        ("harness.rs reading through a collapsed expander", HARNESS,
         r"\.find_map\(\|t\| stage\.collapsed_ancestor\(\*t\)\)", ".find_map(|_| None::<usize>)",
         "harness.rs refuses a step aimed inside a collapsed expander"),
    ]
    for label, rel, pattern, repl, want in cuts:
        broken = g.doctor(f"expander: {label}", sources[rel], pattern, repl)
        g.negative(f"expander: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want=want)
    for rel in STUBBED:
        if rel in BACKENDS and STUBBED[rel] not in sources[rel]:
            g.negative(f"expander: {rel}'s row withheld",
                       lambda rel=rel: findings(sources, {k: v for k, v in BACKENDS.items() if k != rel}),
                       want="has no row")
            continue
        n = sources[rel].count(STUBBED[rel])
        broken = g.doctor(f"expander: {rel}'s stubs gone without a row", sources[rel],
                          re.escape(STUBBED[rel]), "todo!()", want=n)
        g.negative(f"expander: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="has no row")
