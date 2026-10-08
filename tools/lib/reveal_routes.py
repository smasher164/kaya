"""docs/reveal-plan.md V2, V4-V6: the secure field's reveal, held where no
scene can see it go.

reveal.steps reads a revealed field's text as a COUNT off the platform's own
accessibility value, so a read that counted kaya's model would pass it; it
drives the toggle through the one door the eye button takes, so an eye
button that bypassed the door would pass it; an app write that echoed as a
toggle passes it whenever the label it would move already says the same; and
the revealed editor's refusals (copy, cut, services, Writing Tools, undo) are
gestures no harness verb makes. A backend whose `depth_stub("reveal")` goes
must take a row in BACKENDS."""

import re

from content_type_routes import flat
from kaya_gate import ROOT

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
STUBBED = {
    "crates/kaya/src/gtk.rs": 'depth_stub("reveal")',
    "crates/kaya/src/winui/mod.rs": 'depth_stub("reveal")',
    "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt": 'depthStub("reveal")',
}
BACKENDS = {SWIFT: "the SwiftUI arm"}

MASKED_SENTENCE = {
    HARNESS: "the platform masks {n} of the revealed secure field's characters",
    SWIFT: "the platform masks \\(masked) of the revealed secure field's characters",
}
# The one door and who may call it: the user's routes emit, the app's never.
DOOR = [
    ("the door swaps and emits",
     "func kayaRevealToggle(", ["kayaRevealSwap(node, on)", "KayaHost.emitToggled(node.tag, on)"]),
    ("the swap keeps the caret and the focus it found",
     "func kayaRevealSwap(", ["kayaRevealSwapping.insert(node.id)", "kayaRevealCaret[node.id]"]),
]
CALLS = [
    ("the eye button takes the door", "Button(action: { kayaRevealToggle(node, !node.revealed) })"),
    ("the harness's toggle takes the door",
     'DispatchQueue.main.sync { kayaRevealToggle(revealNode, parts[2] == "on") }'),
    ("the harness's toggle waits for the focus to come back",
     "DispatchQueue.main.sync(execute: { kayaRevealSettled(revealNode) })"),
    ("the app's write swaps without a toggle",
     "case (propRevealed, valueBool):\n                    kayaRevealSwap(kayaScene.nodes[id]!, raw[body + 24] != 0)"),
]
# The revealed editor on the mac refuses what NSSecureTextView refuses
# (measured, docs/reveal-plan.md §0), and the iOS field what a secure
# UITextField refuses.
MAC_EDITOR = ("final class KayaRevealEditor: NSTextView {", [
    "if item.action == #selector(NSText.cut(_:)) || item.action == #selector(NSText.copy(_:)) {return false}",
    "override var allowsUndo: Bool {get { false }",
    "override func cut(_ sender: Any?) { NSSound.beep() }",
    "override func copy(_ sender: Any?) { NSSound.beep() }",
    "override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [] }",
    "-> Bool {false}",
    "sendType == nil ? super.validRequestor(forSendType: sendType, returnType: returnType) : nil",
    '("Cut", #selector(NSText.cut(_:))), ("Copy", #selector(NSText.copy(_:))),'
    '("Paste", #selector(NSText.paste(_:))), ("Delete", #selector(NSText.delete(_:))),'
    '("Select All", #selector(NSText.selectAll(_:))),]',
])
MAC_CELL = ("final class KayaRevealCell: NSTextFieldCell {", [
    "if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }",
    "override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }",
])
IOS_FIELD = ("final class KayaRevealUITextField: UITextField {", [
    "#selector(UIResponderStandardEditActions.paste(_:)),"
    "#selector(UIResponderStandardEditActions.select(_:)),"
    "#selector(UIResponderStandardEditActions.selectAll(_:)),"
    "#selector(UIResponderStandardEditActions.delete(_:)),]",
])
# The revealed view keeps the field's content type (docs/autofill-plan.md A6),
# each half through the one table.
HINTS = ["field.contentType = kayaContentTypes().first { Int64($0.word) == contentType }?.platform",
         "view.textContentType = kayaContentTypes().first { Int64($0.word) == contentType }?.platform"]
# The unmasked read: the platform's value through the one count, never the model.
READ_SOURCES = ['kayaAxCopy(hit, kAXValueAttribute as String)', "hit.accessibilityValue"]
MODEL = r"kayaScene|\.revealed\b|\bnode\b|\.text\b"


def blocks(text, opener):
    """Every brace-balanced body after an occurrence of `opener`."""
    out = []
    at = text.find(opener)
    while at >= 0:
        start = text.find("{", at + len(opener) - 1 if opener.endswith("{") else at)
        depth = 0
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    out.append(text[start:i + 1])
                    break
        at = text.find(opener, at + 1)
    return out


def findings(sources):
    out = []
    swift = sources[SWIFT]
    for label, opener, needs in DOOR:
        body = blocks(swift, opener)
        if len(body) != 1:
            out.append(f"reveal: {opener} is defined {len(body)} times, wanted once ({label})")
            continue
        for need in needs:
            if need not in body[0]:
                out.append(f"reveal: {label} no longer holds — {opener}...}} lacks {need}")
    if "KayaHost.emitToggled(node.tag, on)" in "".join(blocks(swift, "func kayaRevealSwap(")):
        out.append("reveal: kayaRevealSwap emits toggled, so the app's own write echoes as the user's")
    for label, call in CALLS:
        if flat(call) not in flat(swift):
            out.append(f"reveal: {label} no longer holds — the file lacks {call.splitlines()[0]}")
    for opener, needs in (MAC_EDITOR, MAC_CELL, IOS_FIELD):
        body = blocks(swift, opener)
        if len(body) != 1:
            out.append(f"reveal: {opener} is defined {len(body)} times, wanted once")
            continue
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"reveal: {opener.split()[2]} lost {need[:80]} — the revealed field "
                           f"offers what the masked one refuses")
    fields = blocks(swift, "struct KayaRevealedField:")
    if len(fields) != 2:
        out.append(f"reveal: KayaRevealedField is defined {len(fields)} times, wanted one per platform")
    for hint in HINTS:
        if not any(flat(hint) in flat(body) for body in fields):
            out.append(f"reveal: a revealed field no longer carries its content type ({hint[:40]}...)")
    reads = blocks(swift, "private func kayaAxUnmaskedRead(")
    if len(reads) != 2:
        out.append(f"reveal: kayaAxUnmaskedRead is defined {len(reads)} times, wanted one per platform")
    for body, source in zip(reads, READ_SOURCES):
        if not re.search(r"kayaUnmaskedCount\(" + re.escape(source), body):
            out.append(f"reveal: kayaAxUnmaskedRead no longer counts the platform's own {source}")
        if re.search(MODEL, body):
            out.append("reveal: kayaAxUnmaskedRead reaches kaya's model, so it could answer "
                       "from what kaya asked for instead of what the platform shows")
    for rel, spelled in MASKED_SENTENCE.items():
        if spelled not in sources[rel]:
            out.append(f"reveal: {rel} no longer says {MASKED_SENTENCE[HARNESS]!r} for a revealed "
                       f"field the platform still masks")
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in BACKENDS:
            out.append(f"reveal: {rel} no longer stubs the reveal and has no row in "
                       f"tools/lib/reveal_routes.py's BACKENDS")
    return out


def run(g):
    rels = [HARNESS, SWIFT, *STUBBED]
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in rels}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("reveal clauses held", len(DOOR) + len(CALLS) + 3 + len(HINTS) + 2, floor=12)
    g.counted("reveal backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("the eye button swapping without the door", SWIFT,
         r"Button\(action: \{ kayaRevealToggle\(node, !node\.revealed\) \}\)",
         "Button(action: { kayaRevealSwap(node, !node.revealed) })", "the eye button takes the door"),
        ("the app's write echoing as a toggle", SWIFT,
         r"kayaRevealSwap\(kayaScene\.nodes\[id\]!, raw\[body \+ 24\] != 0\)",
         "kayaRevealToggle(kayaScene.nodes[id]!, raw[body + 24] != 0)",
         "the app's write swaps without a toggle"),
        ("the door forgetting to emit", SWIFT, r"\n    KayaHost\.emitToggled\(node\.tag, on\)\n", "\n",
         "the door swaps and emits"),
        ("the toggle not waiting for the focus", SWIFT,
         r"DispatchQueue\.main\.sync\(execute: \{ kayaRevealSettled\(revealNode\) \}\)",
         "DispatchQueue.main.sync(execute: { true })", "waits for the focus to come back"),
        ("the mac read counting the model", SWIFT,
         r'kayaUnmaskedCount\(kayaAxCopy\(hit, kAXValueAttribute as String\) as\? String \?\? ""\)',
         'kayaUnmaskedCount(kayaScene.secureFields.first?.text ?? "")', "reaches kaya's model"),
        ("the mac editor copying", SWIFT,
         r" \|\| item\.action == #selector\(NSText\.copy\(_:\)\)", "", "KayaRevealEditor: lost"),
        ("the mac editor keeping an undo stack", SWIFT,
         r"(override var allowsUndo: Bool \{\n            )get \{ false \}", r"\1get { true }",
         "KayaRevealEditor: lost"),
        ("the mac editor offering Services", SWIFT,
         r"sendType == nil \? super\.validRequestor\(forSendType: sendType, returnType: returnType\) : nil",
         "super.validRequestor(forSendType: sendType, returnType: returnType)", "KayaRevealEditor: lost"),
        ("Writing Tools left on", SWIFT,
         r"if #available\(macOS 15\.0, \*\) \{ editor\.writingToolsBehavior = \.none \}\n", "",
         "KayaRevealCell: lost"),
        ("the iOS field copying", SWIFT,
         r"#selector\(UIResponderStandardEditActions\.paste\(_:\)\),\n",
         "#selector(UIResponderStandardEditActions.paste(_:)),\n"
         "                #selector(UIResponderStandardEditActions.copy(_:)),\n",
         "KayaRevealUITextField: lost"),
        ("the mac revealed field dropping its hint", SWIFT,
         r"field\.contentType = kayaContentTypes\(\)", "field.toolTip = kayaContentTypes()",
         "no longer carries its content type"),
        ("the masked sentence reworded in Swift", SWIFT,
         r"of the revealed secure field's characters\"\)", "of the field's characters\")",
         "no longer says"),
        ("GTK's stub gone with no row", "crates/kaya/src/gtk.rs", r'depth_stub\("reveal"\)',
         'depth_stub("revealed")', "has no row"),
    ]
    for label, rel, pattern, repl, want in cuts:
        broken = g.doctor(f"reveal: {label}", sources[rel], pattern, repl,
                          want=len(re.findall(pattern, sources[rel])) or 1)
        g.negative(f"reveal: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want=want)
