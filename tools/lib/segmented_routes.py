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
BACKENDS = {SWIFT: "the SwiftUI arm"}
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
    SWIFT: ['observed.append("segments \\"\\(wantSegments)\\"")',
            'failures.append("segments \\"\\(gotSegments)\\", wanted \\"\\(wantSegments)\\"")',
            'observed.append("segment \\(glyphIndex) symbol \\"\\(wantGlyph)\\"")',
            '"segment \\(glyphIndex) symbol \\"\\(gotGlyph)\\", wanted \\"\\(wantGlyph)\\""'],
}


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
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in backends:
            out.append(f"segmented: {rel} no longer stubs the segmented control and has no row in "
                       f"tools/lib/segmented_routes.py's BACKENDS")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in [HARNESS, SWIFT, *STUBBED]}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("segmented clauses held",
              len(ARM[1]) + 1 + sum(len(n) + 1 for _, _, n in READS) + 2 * len(ANSWERS) + len(CALLS)
              + sum(len(v) for v in SENTENCES.values()), floor=35)
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
    for rel in STUBBED:
        n = sources[rel].count(STUBBED[rel])
        broken = g.doctor(f"segmented: {rel}'s stubs gone without a row", sources[rel],
                          re.escape(STUBBED[rel]), "todo!()", want=n)
        g.negative(f"segmented: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="has no row")
