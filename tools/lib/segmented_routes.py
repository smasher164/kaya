"""docs/segmented-plan.md G10: the choice controls' reads and presses, held
where no scene can see them go.

segmented.steps writes the index from the app and reads it back, so an arm
that ignores the write is red on its lane; but a read that answered from
kaya's model would agree with every write, and a `choose` that wrote the
model and emitted by hand would pass every pick while the control showed
anything at all. The radio and select reads share the reader. A backend
whose `depth_stub("segmented")` goes must take a row in BACKENDS."""

import re

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
STUBBED = {GTK: 'depth_stub("segmented")', WINUI: 'depth_stub("segmented")', COMPOSE: 'depthStub("segmented")'}
BACKENDS = {SWIFT: "the SwiftUI arm", COMPOSE: "the Compose arm", GTK: "the GTK arm", WINUI: "the WinUI arm"}
RUST_MODEL = r"segmented_options|segmented_symbols|core\.scene\b|\.toggle\(|\.active\(\)"
# docs/traps.md, WinUI's SelectorBar: `choose` brings an unloaded segment into
# view and presses it, never writing the bar's selection.
FORBID = {WINUI: ("fn choose_segment(t: crate::harness::Target, index: usize) {",
                  ["SetSelectedItem(", "SetSelectedIndex(", "send_value_tag("])}
# The widget backends' rows (docs/segmented-plan.md §3): per backend, (label,
# opener, which occurrence, what the block must hold, whether it is a read
# that may not reach kaya's model). The create arm's emit sits behind its
# quiet guard; the app's write sets that guard around the platform's setter.
ROWS = {
    GTK: [
        ("the toggle group's door", "WidgetKind::Segmented => {", 0,
         ["adw::ToggleGroup::new()", "group.set_homogeneous(true);", "group.connect_active_notify(",
          "if !quiet.get() && g.active() != gtk4::INVALID_LIST_POSITION {",
          "sink.send_value_tag(&tag, f64::from(g.active()));"], False),
        ("the app's write", "(NativeWidget::Segmented(group), Prop::Value, Value::F64(v)) => {", 0,
         ["core.apply_quiet.set(true);\n                    group.set_active(v as u32);\n"
          "                    core.apply_quiet.set(false);"], False),
        ("choose", "if t.kind == crate::harness::TargetKind::Segmented {", 0,
         ["segment_buttons(&core.segmenteds[i])", "button.activate();"], True),
        ("expect", "if t.kind == crate::harness::TargetKind::Segmented {", 1,
         ["segment_buttons(&core.segmenteds[i])", ".find(|b| b.is_active())", ".map(segment_button_name)"], True),
        ("expect_segments", "fn segments(&self, t: crate::harness::Target) -> String {", 0,
         ["segment_buttons(&core.segmenteds[i])", "if b.is_active() {", "segment_button_name(b)"], True),
        ("expect_segment_symbol", "fn segment_symbol(&self, t: crate::harness::Target, index: usize) -> String {", 0,
         ["segment_buttons(&core.segmenteds[i])", "button.child().and_then(|c| c.downcast::<gtk4::Image>().ok())",
          "image.icon_name()", "symbol_name_of_icon(&icon)"], True),
        ("the segment buttons", "fn segment_buttons(group: &adw::ToggleGroup) -> Vec<gtk4::ToggleButton> {", 0,
         ["group.first_child()", "c.downcast_ref::<gtk4::ToggleButton>()"], True),
    ],
    WINUI: [
        ("the SelectorBar's door", "WidgetKind::Segmented => {", 0,
         ["SelectorBar::new()?", "bar.SelectionChanged(",
          "if quiet.load(std::sync::atomic::Ordering::Relaxed) {\n                            return Ok(());",
          "sink.send_value_tag(&tag, f64::from(index));", "selector_bar_equalize(&equalize)"], False),
        ("the app's write", "(NativeWidget::Segmented(bar), Prop::Value, Value::F64(v)) => {", 0,
         [".store(true, std::sync::atomic::Ordering::Relaxed);", "bar.SetSelectedItem(&item)",
          ".store(false, std::sync::atomic::Ordering::Relaxed);"], False),
        ("choose", "if t.kind == crate::harness::TargetKind::Segmented {", 0,
         ["Self::choose_segment(t, index);"], True),
        ("choose's press", "fn choose_segment(t: crate::harness::Target, index: usize) {", 0,
         ["if !item.cast::<FrameworkElement>()?.IsLoaded()? {\n                return Ok(None);",
          "FrameworkElementAutomationPeer::CreatePeerForElement(&element)?",
          "peer.cast::<ISelectionItemProvider>()?.Select()?;",
          "if let Some(before) = press(core, i)? {",
          "if ask && let Some(view) = selector_bar_items_view(bar)? {",
          "view.StartBringItemIntoView(index as i32, &options)?;"], True),
        ("the bar's ItemsView", "fn selector_bar_items_view(", 0,
         ["node.cast::<bindings::Microsoft::UI::Xaml::Controls::ItemsView>()",
          "VisualTreeHelper::GetChild(&element, k)?"], True),
        ("expect", "if t.kind == crate::harness::TargetKind::Segmented {", 1,
         ["let Some(n) = selector_bar_selected(bar)? else {",
          "uia_name(&windows_core::Interface::cast(&item)?, \"the item\")"], True),
        ("expect_segments", "fn segments(&self, t: crate::harness::Target) -> String {", 0,
         ["let selected = selector_bar_selected(bar)?;",
          "let name = uia_name(&windows_core::Interface::cast(&item)?, \"the item\");",
          "if selected == Some(n) {"], True),
        ("the bar's selection", "fn selector_bar_selected(bar: &SelectorBar) -> windows_core::Result<Option<u32>> {", 0,
         ["let Ok(selected) = bar.SelectedItem() else {", "if items.GetAt(n)? == selected {"], True),
        ("expect_segment_symbol", "fn segment_symbol(&self, t: crate::harness::Target, index: usize) -> String {", 0,
         ["items.GetAt(index as u32)?.Icon()", "Ok(icon) => icon_uia_name(&icon),"], True),
    ],
}
COMPOSE_ARM = ("internal fun KayaSegmented(", [
    "SingleChoiceSegmentedButtonRow(",
    "modifier = boxFill.then(a11y).semantics { this[KayaNodeId] = node.id },",
    "val selected = node.value.toInt() == i",
    "selected = selected,",
    "onClick = {\n                    node.value = i.toDouble()",
    "contentDescription = segment.text,",
    "modifier = Modifier.semantics { this[KayaGlyph] = glyph },",
])
COMPOSE_MODEL = r"\.value\b|\.symbol\b|\.children\.getOrNull|emitValueChanged|KayaSceneModel"
# (function, what it must hold); each reads the semantics tree, never the model
COMPOSE_READS = [
    ("private fun kayaChoiceOptions(", ["root.measureAndLayoutForTest()",
                                        "kayaTaggedNode(root.semanticsOwner.rootSemanticsNode, id)",
                                        "child.config.contains(SemanticsProperties.Selected)",
                                        "options.sortWith(compareBy<SemanticsNode> { it.boundsInRoot.top }"]),
    ("private fun kayaSelectShown(", ["kayaSemanticsValue(field, SemanticsProperties.EditableText)"]),
    ("private fun kayaChoiceSelectedText(", ["kayaSelectShown(activity, choice.id)",
                                             "kayaChoiceOptions(activity, choice.id)",
                                             "it.config.getOrNull(SemanticsProperties.Selected) == true"]),
    ("private fun kayaSegmentsText(", ["kayaChoiceOptions(activity, choice.id)",
                                       "if (it.config.getOrNull(SemanticsProperties.Selected) == true)"]),
    ("private fun kayaSegmentSymbolText(", ["kayaSemanticsValue(unmerged, KayaGlyph)"]),
]
COMPOSE_PRESSES = [
    ("private fun kayaChoicePress(", ["option.config.getOrNull(SemanticsActions.OnClick)?.action"]),
    ("private fun kayaSelectPress(", ["KayaSceneModel.menuPopupViews",
                                      "row.config.getOrNull(SemanticsActions.OnClick)?.action"]),
]
COMPOSE_CALLS = [
    ("expect reads select, radio and segmented through the platform",
     "kayaChoiceTarget(parts[1])?.let { kayaChoiceSelectedText(activity, it) }"),
    ("choose presses the option", "val why = kayaChoicePress(activity, parts[1], parts.getOrNull(2)?.toIntOrNull())"),
    ("expect_segments reads the platform's segments", "?.let { kayaSegmentsText(activity, it) }"),
    ("expect_segment_symbol reads the drawn glyph", "?.let { kayaSegmentSymbolText(activity, it, glyphIndex) }"),
    ("the radio group carries its node id",
     "modifier = boxFill.then(a11y).selectableGroup()\n                    .semantics { this[KayaNodeId] = node.id },"),
    ("the select's field carries its node id",
     ".semantics { this[KayaNodeId] = node.id }\n                        .menuAnchor(),"),
    ("the select's rows carry their option's id and their popup is found",
     "KayaMenuPopupRoot()\n                    node.children.forEachIndexed { i, option ->\n"
     "                        androidx.compose.material3.DropdownMenuItem(\n"
     "                            modifier = Modifier.semantics { this[KayaNodeId] = option.id },"),
]
MODEL = r"kayaScene|\bnode\.(value|text|children|symbol|tag)\b|\bsegment\.(symbol|text)\b|\$0\.(value|children)\b"
# (label, opener, wanted once per platform, what it must hold)
ARM = ("struct KayaSegmented: View", [
    "get: { Int(node.value) },",
    "kayaUserWrite { node.value = Double(newIndex) }\n                    KayaHost.emitValue(node.tag, Double(newIndex))",
    ".pickerStyle(.segmented)",
    ".accessibilityLabel(segment.text)",
    ".help(segment.text)",
])
READS = [
    ("the mac read", 0, [
        "AXUIElementCopyElementAtPosition(",
        'if role == "AXRadioGroup" {',
        "selected: (kayaAxCopy(kid, kAXValueAttribute) as? NSNumber)?.intValue == 1,",
        "glyph: kayaAxCopy(kid, kAXIdentifierAttribute) as? String,",
        "press: { AXUIElementPerformAction(kid, kAXPressAction as CFString) == .success })",
        'return .popUp(kayaAxCopy(element, kAXValueAttribute) as? String ?? "")',
    ]),
    ("the iOS read", 1, [
        "UIAccessibility.convertToScreenCoordinates(anchor.bounds, in: anchor)",
        "selected: element.accessibilityTraits.contains(.selected),",
        "if element.accessibilityActivate() { return true }",
    ]),
]
ANSWERS = ["func kayaChoiceSelectedText(", "func kayaSegmentsText(", "func kayaSegmentSymbolText(",
           "func kayaChoicePress("]
CALLS = [
    ("expect reads select, radio and segmented through the platform", ".map { kayaChoiceSelectedText($0) }"),
    ("choose presses the segment", "return kayaChoicePress(node, segmentIndex)"),
    ("expect_segments reads the platform's segments", "return kayaSegmentsText(node)"),
    ("expect_segment_symbol reads the segment's glyph", "return kayaSegmentSymbolText(node, glyphIndex)"),
    ("every choice arm carries its anchor", ".background(KayaChoiceAnchor(id: node.id))"),
]
SENTENCES = {
    HARNESS: ['Ok(format!("segments {want:?}"))', 'Err(format!("segments {got:?}, wanted {want:?}"))',
              'Ok(format!("segment {index} symbol {want:?}"))',
              'Err(format!("segment {index} symbol {got:?}, wanted {want:?}"))'],
    COMPOSE: [r'observed.add("segments \"$wantSegments\"")',
              r'failures.add("segments \"$gotSegments\", wanted \"$wantSegments\"")',
              r'observed.add("segment $glyphIndex symbol \"$wantGlyph\"")',
              r'failures.add("segment $glyphIndex symbol \"$gotGlyph\", wanted \"$wantGlyph\"")'],
    SWIFT: ['observed.append("segments \\"\\(wantSegments)\\"")',
            'failures.append("segments \\"\\(gotSegments)\\", wanted \\"\\(wantSegments)\\"")',
            'observed.append("segment \\(glyphIndex) symbol \\"\\(wantGlyph)\\"")',
            '"segment \\(glyphIndex) symbol \\"\\(gotGlyph)\\", wanted \\"\\(wantGlyph)\\""'],
}


def compose_findings(kt):
    out = []
    opener, needs = COMPOSE_ARM
    body = blocks(kt, opener)
    if len(body) != 1:
        out.append(f"segmented: {opener} is defined {len(body)} times, wanted once")
    else:
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"segmented: the Compose arm lacks {need.splitlines()[0]} — the control "
                           f"could draw a selection the app never wrote, or a pick nobody hears")
        if body[0].count("emitValueChanged(") != 1:
            out.append(f"segmented: the Compose arm emits from {body[0].count('emitValueChanged(')} sites, "
                       f"wanted the segment's onClick alone")
    for opener, needs in COMPOSE_READS + COMPOSE_PRESSES:
        body = blocks(kt, opener)
        if len(body) != 1:
            out.append(f"segmented: {opener} is defined {len(body)} times, wanted once")
            continue
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"segmented: Compose's {opener}...) lacks {need} — it no longer reads or "
                           f"presses the platform's own control")
        if (opener, needs) in COMPOSE_READS and re.search(COMPOSE_MODEL, body[0]):
            out.append(f"segmented: Compose's {opener}...) reaches kaya's model, so it could answer "
                       f"from what kaya asked for instead of what the platform shows")
        if (opener, needs) in COMPOSE_PRESSES and re.search(r"emitValueChanged|\.value\s*=", body[0]):
            out.append(f"segmented: Compose's {opener}...) writes the model or emits by hand")
    for label, call in COMPOSE_CALLS:
        if flat(call) not in flat(kt):
            out.append(f"segmented: on Compose {label} no longer holds — the file lacks {call.splitlines()[0]}")
    return out


def findings(sources, backends=None):
    backends = BACKENDS if backends is None else backends
    out = []
    swift = sources[SWIFT]
    opener, needs = ARM
    body = blocks(swift, opener)
    if len(body) != 1:
        out.append(f"segmented: {opener} is defined {len(body)} times, wanted once")
    else:
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"segmented: the SwiftUI arm lacks {need.splitlines()[0]} — the control "
                           f"could draw a selection the app never wrote, or a pick nobody hears")
        if body[0].count("emitValue(") != 1:
            out.append(f"segmented: the SwiftUI arm emits from {body[0].count('emitValue(')} sites, "
                       f"wanted the selection binding's set alone")
    reads = blocks(swift, "func kayaChoiceRead(")
    if len(reads) != 2:
        out.append(f"segmented: kayaChoiceRead is defined {len(reads)} times, wanted one per platform")
    else:
        for label, at, needs in READS:
            for need in needs:
                if flat(need) not in flat(reads[at]):
                    out.append(f"segmented: {label} lacks {need[:70]} — it no longer reads the "
                               f"platform's own selection")
            if re.search(MODEL, reads[at]):
                out.append(f"segmented: {label} reaches kaya's model, so it could answer from what "
                           f"kaya asked for instead of what the platform shows")
    for opener in ANSWERS:
        body = blocks(swift, opener)
        if len(body) != 1:
            out.append(f"segmented: {opener} is defined {len(body)} times, wanted once")
            continue
        if "kayaChoiceRead(node)" not in body[0]:
            out.append(f"segmented: {opener}...) no longer goes through kayaChoiceRead")
        if re.search(MODEL, body[0]):
            out.append(f"segmented: {opener}...) reaches kaya's model, so it could answer from what "
                       f"kaya asked for instead of what the platform shows")
    for label, call in CALLS:
        want = 4 if "KayaChoiceAnchor" in call else 1
        if flat(swift).count(flat(call)) < want:
            out.append(f"segmented: {label} no longer holds — the file lacks {call}")
    for rel, spelled in SENTENCES.items():
        for line in spelled:
            if flat(line) not in flat(sources[rel]):
                out.append(f"segmented: {rel} no longer says {line} — the two harnesses' verdicts "
                           f"must be the same bytes")
    if COMPOSE in backends:
        out += compose_findings(sources[COMPOSE])
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in backends:
            out.append(f"segmented: {rel} no longer stubs the segmented control and has no row in "
                       f"tools/lib/segmented_routes.py's BACKENDS")
    out += row_findings(sources, backends)
    return out


def row_findings(sources, backends):
    out = []
    for rel, (opener, calls) in FORBID.items():
        if rel not in backends or rel not in sources:
            continue
        for body in blocks(sources[rel], opener):
            for call in calls:
                if call in body:
                    out.append(f"segmented: {backends[rel]}'s choose calls {call}...), writing the "
                               f"selection instead of bringing the segment into view and pressing it")
    for rel, rows in ROWS.items():
        if rel not in backends or rel not in sources:
            continue
        name = backends[rel]
        for label, opener, at, needs, read in rows:
            found = blocks(sources[rel], opener)
            if len(found) <= at:
                out.append(f"segmented: {name}'s {label} is gone — {rel} lacks {opener}")
                continue
            body = found[at]
            for need in needs:
                if flat(need) not in flat(body):
                    out.append(f"segmented: {name}'s {label} lacks {need.splitlines()[0][:70]} — the "
                               f"control could show a selection the app never wrote, or a pick nobody hears")
            if read and re.search(RUST_MODEL, body):
                out.append(f"segmented: {name}'s {label} reaches kaya's model, so it could answer from "
                           f"what kaya asked for instead of what the platform shows")
            if not read and "send_value_tag(" in body:
                emits = body.count("send_value_tag(")
                quiet = re.search(r"quiet\.(get|load)\(", body)
                if emits != 1:
                    out.append(f"segmented: {name}'s {label} emits from {emits} sites, wanted one")
                if not quiet or quiet.start() > body.find("send_value_tag("):
                    out.append(f"segmented: {name}'s {label} emits outside its quiet guard, so the "
                               f"app's own write would echo")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in [HARNESS, SWIFT, *STUBBED]}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("segmented clauses held",
              len(ARM[1]) + 1 + sum(len(n) + 1 for _, _, n in READS) + 2 * len(ANSWERS) + len(CALLS)
              + sum(len(v) for v in SENTENCES.values()), floor=35)
    g.counted("segmented Compose clauses held",
              len(COMPOSE_ARM[1]) + 1 + sum(len(n) + 1 for _, n in COMPOSE_READS + COMPOSE_PRESSES)
              + len(COMPOSE_CALLS), floor=30)
    g.counted("segmented backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("the arm ignoring the app's write", SWIFT,
         r'(let picker = Picker\(\n\s+"",\n\s+selection: Binding\(\n\s+)get: \{ Int\(node\.value\) \},',
         r"\1get: { 0 },", "the SwiftUI arm lacks get: { Int(node.value) }"),
        ("the arm's pick unheard", SWIFT,
         r"(kayaUserWrite \{ node\.value = Double\(newIndex\) \}\n)\s+KayaHost\.emitValue\(node\.tag, Double\(newIndex\)\)\n(\s+\}\)\n\s+\) \{\n\s+ForEach\(Array\(node\.children\.enumerated\(\)\), id: \\\.element\.id\) \{ index, segment in)",
         r"\1\2", "emits from 0 sites"),
        ("a symbol segment nameless", SWIFT, r"\n\s+\.accessibilityLabel\(segment\.text\)", "",
         "lacks .accessibilityLabel(segment.text)"),
        ("the mac pop-up read answering from the model", SWIFT,
         r'return \.popUp\(kayaAxCopy\(element, kAXValueAttribute\) as\? String \?\? ""\)',
         'return .popUp(node.children.first?.text ?? "")', "the mac read reaches kaya's model"),
        ("the mac segment's selection not read", SWIFT,
         r"selected: \(kayaAxCopy\(kid, kAXValueAttribute\) as\? NSNumber\)\?\.intValue == 1,",
         "selected: false,", "the mac read lacks selected:"),
        ("the mac press a model write", SWIFT,
         r"press: \{ AXUIElementPerformAction\(kid, kAXPressAction as CFString\) == \.success \}\)",
         "press: { true })", "the mac read lacks press:"),
        ("the iOS selection not read", SWIFT, r"selected: element\.accessibilityTraits\.contains\(\.selected\),",
         "selected: index == 0,", "the iOS read lacks selected:"),
        ("the selected text read off the model", SWIFT,
         r"(func kayaChoiceSelectedText\(_ node: KayaNode\) -> String \{\n)",
         r"\1    if node.children.isEmpty { return String(node.value) }\n",
         "kayaChoiceSelectedText(...) reaches kaya's model"),
        ("expect answering from the model", SWIFT, r"\.map \{ kayaChoiceSelectedText\(\$0\) \}",
         ".map { $0.children[Int($0.value)].text }", "expect reads select, radio and segmented"),
        ("choose writing the model", SWIFT, r"return kayaChoicePress\(node, segmentIndex\)",
         "node.value = Double(segmentIndex)\n                    return nil", "choose presses the segment"),
        ("the radio arm without its anchor", SWIFT,
         r"(\.pickerStyle\(\.segmented\)\n            #endif\n            \.labelsHidden\(\)\n            \.fixedSize\(\)\n)            \.background\(KayaChoiceAnchor\(id: node\.id\)\)\n",
         r"\1", "every choice arm carries its anchor"),
        ("the sentence reworded in Swift", SWIFT, r'failures\.append\("segments \\"\\\(gotSegments\)\\", wanted',
         'failures.append("segments read \\"\\(gotSegments)\\", wanted', "no longer says"),
    ]
    for label, rel, pattern, repl, want in cuts:
        broken = g.doctor(f"segmented: {label}", sources[rel], pattern, repl)
        g.negative(f"segmented: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want=want)
    compose_cuts = [
        ("the Compose arm ignoring the app's write", r"val selected = node\.value\.toInt\(\) == i",
         "val selected = i == 0", "the Compose arm lacks val selected"),
        ("the Compose pick unheard",
         r"(\n\s+\"segmented tap node=\$\{node\.id\} index=\$i tag=\$\{kayaTagDigest\(node\.tag\)\}\"\))\n\s+KayaPresent\.emitValueChanged\(node\.tag, i\.toDouble\(\)\)",
         r"\1", "the Compose arm emits from 0 sites"),
        ("a Compose symbol segment nameless", r"contentDescription = segment\.text,", "contentDescription = null,",
         "lacks contentDescription = segment.text"),
        ("the drawn glyph untagged", r"modifier = Modifier\.semantics \{ this\[KayaGlyph\] = glyph \},", "",
         "lacks modifier = Modifier.semantics { this[KayaGlyph]"),
        ("Compose's selected text read off the model",
         r"(private fun kayaChoiceSelectedText\(activity: ComponentActivity, choice: KayaNode\): String \{\n)",
         r"\1        if (choice.value >= 0) return choice.children[choice.value.toInt()].text\n",
         "kayaChoiceSelectedText(...) reaches kaya's model"),
        ("Compose's segments read without the selection",
         r"if \(it\.config\.getOrNull\(SemanticsProperties\.Selected\) == true\) \"\[\$name\]\"",
         'if (options.indexOf(it) == 0) "[$name]"', "kayaSegmentsText(...) lacks"),
        ("Compose's select read off the model",
         r"kayaSemanticsValue\(field, SemanticsProperties\.EditableText\)",
         "KayaSceneModel.nodes[id]?.children?.firstOrNull()?.text?.let { androidx.compose.ui.text.AnnotatedString(it) }",
         "kayaSelectShown(...) lacks"),
        ("Compose's choose writing the model",
         r"val why = kayaChoicePress\(activity, parts\[1\], parts\.getOrNull\(2\)\?\.toIntOrNull\(\)\)",
         "val why = null", "choose presses the option"),
        ("Compose's press emitting by hand", r"(\n\s+)click\(\)\n(\s+KayaDiag\.note\(\"choose )",
         r"\1KayaPresent.emitValueChanged(choice.tag, index.toDouble())\n\2", "writes the model or emits by hand"),
        ("Compose's radio group untagged",
         r"(modifier = boxFill\.then\(a11y\)\.selectableGroup\(\))\n\s+\.semantics \{ this\[KayaNodeId\] = node\.id \},",
         r"\1,", "the radio group carries its node id"),
        ("Compose's select popup unregistered", r"\n\s+KayaMenuPopupRoot\(\)(\n\s+node\.children\.forEachIndexed \{ i, option ->)",
         r"\1", "their popup is found"),
        ("Compose's options in semantics order", r"\n\s+options\.sortWith\(compareBy<SemanticsNode> \{ it\.boundsInRoot\.top \}\n\s+\.thenBy \{[^\n]*\}\)", "",
         "lacks options.sortWith"),
        ("the sentence reworded in Kotlin", r'failures\.add\("segments \\"\$gotSegments', 'failures.add("segments read \\"$gotSegments',
         "no longer says"),
    ]
    for label, pattern, repl, want in compose_cuts:
        broken = g.doctor(f"segmented: {label}", sources[COMPOSE], pattern, repl)
        g.negative(f"segmented: {label}", lambda broken=broken: findings({**sources, COMPOSE: broken}),
                   want=want)
    g.counted("segmented GTK and WinUI clauses held",
              sum(len(needs) + 1 for rows in ROWS.values() for _, _, _, needs, _ in rows)
              + sum(len(calls) for _, calls in FORBID.values()), floor=55)
    row_cuts = [
        ("GTK's read answering from the model", GTK,
         r"(fn segments\(&self, t: crate::harness::Target\) -> String \{\n\s+Self::on_main\(move \|core\| \{\n)",
         r"\1            let _ = &core.segmented_options;\n", "the GTK arm's expect_segments reaches kaya's model"),
        ("GTK's segments read without the selection", GTK, r"if b\.is_active\(\) \{\n(\s+)format!\(\"\[\{name\}\]\"\)",
         r'if false {\n\1format!("[{name}]")', "the GTK arm's expect_segments lacks if b.is_active()"),
        ("GTK's choose a model write", GTK, r"(Some\(button\) => \{\n\s+)button\.activate\(\);",
         r"\1core.segmenteds[i].set_active(index as u32);", "the GTK arm's choose lacks button.activate()"),
        ("GTK's app write unguarded", GTK,
         r"core\.apply_quiet\.set\(true\);\n(\s+)group\.set_active\(v as u32\);", r"group.set_active(v as u32);",
         "the GTK arm's the app's write lacks"),
        ("GTK's pick unheard", GTK, r"\n\s+sink\.send_value_tag\(&tag, f64::from\(g\.active\(\)\)\);", "",
         "the GTK arm's the toggle group's door lacks sink.send_value_tag"),
        ("GTK's pick heard outside the guard", GTK,
         r"if !quiet\.get\(\) && g\.active\(\) != gtk4::INVALID_LIST_POSITION \{\n(\s+)sink\.send_value_tag\(&tag, f64::from\(g\.active\(\)\)\);",
         r"sink.send_value_tag(&tag, f64::from(g.active()));\n\1if !quiet.get() && g.active() != gtk4::INVALID_LIST_POSITION {",
         "emits outside its quiet guard"),
        ("GTK's glyph read off the model", GTK,
         r"symbol_name_of_icon\(&icon\)(\n\s+\.map\(str::to_string\)\n\s+\.unwrap_or_else\(\|\| format!\(\"<segment \{index\} draws)",
         r"core.segmented_symbols.values().next().and_then(|s| crate::wire::symbol_name(*s))\1",
         "the GTK arm's expect_segment_symbol"),
        ("WinUI's read answering from the model", WINUI, r"let name = uia_name\(&windows_core::Interface::cast\(&item\)\?, \"the item\"\);",
         'let name = core.segmented_options.len().to_string();', "the WinUI arm's expect_segments"),
        ("WinUI's segments read without the selection", WINUI,
         r"out\.push\(if selected == Some\(n\) \{", "out.push(if n == 0 {",
         "the WinUI arm's expect_segments lacks if selected == Some(n)"),
        ("WinUI's selection read off the first IsSelected item", WINUI,
         r"if items\.GetAt\(n\)\? == selected \{", "if items.GetAt(n)?.IsSelected()? {",
         "the WinUI arm's the bar's selection lacks if items.GetAt(n)? == selected"),
        ("WinUI's choose a model write", WINUI, r"peer\.cast::<ISelectionItemProvider>\(\)\?\.Select\(\)\?;",
         "core.segmenteds[i].SetSelectedItem(&element.cast()?)?;", "the WinUI arm's choose's press lacks peer.cast"),
        ("WinUI's unloaded segment selected instead of brought into view", WINUI,
         r"view\.StartBringItemIntoView\(index as i32, &options\)\?;",
         "bar.SetSelectedItem(&bar.Items()?.GetAt(index as u32)?)?;", "writing the selection instead"),
        ("WinUI's choose pressing an unloaded segment", WINUI,
         r"if !item\.cast::<FrameworkElement>\(\)\?\.IsLoaded\(\)\? \{\n\s+return Ok\(None\);\n\s+\}\n", "",
         "the WinUI arm's choose's press lacks if !item.cast"),
        ("WinUI's choose with no ItemsView found", WINUI,
         r"if let Ok\(view\) = node\.cast::<bindings::Microsoft::UI::Xaml::Controls::ItemsView>\(\) \{",
         "if let Ok(view) = node.cast::<SelectorBar>() {", "the WinUI arm's the bar's ItemsView lacks"),
        ("WinUI's app write unguarded", WINUI,
         r"(\(NativeWidget::Segmented\(bar\), Prop::Value, Value::F64\(v\)\) => \{\n)\s+core\.apply_quiet\n\s+\.store\(true, std::sync::atomic::Ordering::Relaxed\);\n",
         r"\1", "the WinUI arm's the app's write lacks .store(true"),
        ("WinUI's pick unheard", WINUI,
         r"(if let Some\(index\) = selector_bar_selected\(bar\)\? \{)\n\s+sink\.send_value_tag\(&tag, f64::from\(index\)\);",
         r"\1",
         "the WinUI arm's the SelectorBar's door lacks sink.send_value_tag"),
        ("WinUI's glyph read off the model", WINUI,
         r"(Ok\(match items\.GetAt\(index as u32\)\?\.Icon\(\) \{\n\s+)Ok\(icon\) => icon_uia_name\(&icon\),",
         r"\1Ok(_) => format!(\"{}\", core.segmented_symbols.len()),", "the WinUI arm's expect_segment_symbol"),
    ]
    for label, rel, pattern, repl, want in row_cuts:
        broken = g.doctor(f"segmented: {label}", sources[rel], pattern, repl)
        g.negative(f"segmented: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want=want)
    for rel in STUBBED:
        if rel in BACKENDS and STUBBED[rel] not in sources[rel]:
            g.negative(f"segmented: {rel}'s row withheld",
                       lambda rel=rel: findings(sources, {k: v for k, v in BACKENDS.items() if k != rel}),
                       want="has no row")
            continue
        n = sources[rel].count(STUBBED[rel])
        broken = g.doctor(f"segmented: {rel}'s stubs gone without a row", sources[rel],
                          re.escape(STUBBED[rel]), "todo!()", want=n)
        g.negative(f"segmented: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="has no row")
