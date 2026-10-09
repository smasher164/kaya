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
BACKENDS = {SWIFT: "the SwiftUI arm"}
MODEL = r"node\.expanded|node\.summary|node\.laidOut|node\.children"
ARM = ("struct KayaExpander: View {", [
    "DisclosureGroup(isExpanded: open)",
    "get: { node.expanded },",
    "kayaUserWrite { node.expanded = now }",
    "KayaHost.emitToggled(node.tag, now)",
    ".background(KayaExpanderAnchor(id: node.id, header: true))",
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
     ["(kayaExpanderHeaders[node.id] ?? [])", "button.accessibilityValue", "press: { button.accessibilityActivate() }"]),
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
    (HARNESS, "harness.rs refuses a step aimed inside a collapsed expander",
     ".find_map(|t| stage.collapsed_ancestor(*t))\n                .map(out_of_reach);"),
    (HARNESS, "harness.rs reads both halves",
     "Step::ExpectExpanded(t, want) => Some(poll(|| expanded_reading(stage.expanded(*t), *want))),"),
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
    return re.sub(r"\{[^}]*\}|\\\([^)]*\)", "<v>", said)


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
    for rel, label, call in CALLS:
        if flat(call) not in flat(sources[rel]):
            out.append(f"expander: {label} no longer holds — {rel} lacks {call.splitlines()[0]}")
    for lead in SENTENCES:
        said = {rel: sentence(sources[rel], lead) for rel in (HARNESS, SWIFT)}
        if None in said.values() or said[HARNESS] != said[SWIFT]:
            out.append(f"expander: the two harnesses no longer say one sentence for {lead!r} "
                       f"(harness.rs {said[HARNESS]!r}, SwiftUI {said[SWIFT]!r}) — the verdicts must be "
                       f"the same bytes")
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in backends:
            out.append(f"expander: {rel} no longer stubs the expander and has no row in "
                       f"tools/lib/expander_routes.py's BACKENDS")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in [HARNESS, SWIFT, *STUBBED]}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("expander clauses held",
              len(ARM[1]) + 1 + sum(len(w) + 2 for *_, w in READS) + len(CALLS) + len(SENTENCES), floor=40)
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
        ("the props on the container", SWIFT, r"\} else if node\.kind == kindExpander && !leaf \{",
         "} else if false && !leaf {", "the props ride the header"),
        ("the form row with no press", SWIFT, r"\.accessibilityAction \{ open\.wrappedValue\.toggle\(\) \}", "",
         "the SwiftUI arm lacks kayaA11y(header, node, leaf: true).accessibilityAction"),
        ("harness.rs reading through a collapsed expander", HARNESS,
         r"\.find_map\(\|t\| stage\.collapsed_ancestor\(\*t\)\)", ".find_map(|_| None::<usize>)",
         "harness.rs refuses a step aimed inside a collapsed expander"),
    ]
    for label, rel, pattern, repl, want in cuts:
        broken = g.doctor(f"expander: {label}", sources[rel], pattern, repl)
        g.negative(f"expander: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want=want)
    for rel in STUBBED:
        n = sources[rel].count(STUBBED[rel])
        broken = g.doctor(f"expander: {rel}'s stubs gone without a row", sources[rel],
                          re.escape(STUBBED[rel]), "todo!()", want=n)
        g.negative(f"expander: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="has no row")
