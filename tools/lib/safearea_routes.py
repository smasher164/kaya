"""docs/safe-area-plan.md A3-A5, A9, A10: the safe area's and the keyboard's
routes, held where no scene can see them go.

safearea.steps reads a bled widget's frame and the iOS keyboard scripts read
the keyboard and the focused field, so an arm that stopped bleeding or a field
left under the keyboard is red on its lane. But a reading that answered from
kaya's own pan agrees with every pan, a typing verb that lost the wall types
into a hidden field green, a bleed that took the keyboard's region along is
green on every leg with no keyboard up, a lane that stopped raising the keyboard
meets only the wall's refusal, and the bled canvas that grew itself every frame
read `bleeds` until the reading refused a frame past the window. A backend whose
`depth_stub("safearea")` goes must take a row in BACKENDS."""

import re

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
RUNSIM = "tools/ios/run-sim.py"
IOS_LANE = "tools/lib/lanes/ios.py"
STUBBED = {GTK: 'depth_stub("safearea")', WINUI: 'depth_stub("safearea")', COMPOSE: 'depthStub("safearea")'}
BACKENDS = {SWIFT: "the SwiftUI arm"}
PREF = ('"com.apple.keyboard.preferences"', '"AutomaticMinimizationEnabled"')
# (label, opener, which definition, what it must hold, what it may never name)
BLOCKS = [
    ("the bleed", "struct KayaBleed<Content: View>: View {", 0,
     ["let edges = kayaBleedEdges(node)", "KayaBleedLayout(edges: edges, inset: inset, slotHeight: slotHeight)",
      "kayaBleedFrames[node.id] = f }\n }\n )\n .ignoresSafeArea(.container, edges: edges)"],
     [".keyboard", ".all"]),
    ("the bleed's slot", "struct KayaBleedLayout: Layout {", 0,
     ["let grown = ProposedViewSize(width: proposal.width.map { $0 + dx }, height: proposal.height.map { $0 + dy })",
      "return CGSize(width: max(0, answer.width - dx), height: max(0, answer.height - dy))"],
     ["sizeThatFits(proposal)"]),
    ("the touching sides", "@MainActor func kayaBleedEdges(_ node: KayaNode) -> Edge.Set {", 0,
     ["kayaScene.parents[child]", "kayaFilledInset(parent) == 0",
      "if !first { edges.remove(vertical ? .top : .leading) }",
      "if !last { edges.remove(vertical ? .bottom : .trailing) }", "return kayaIsMountedRoot(child) ? edges : []"],
     []),
    ("expect_safe's reading", "@MainActor func kayaSafeReading(", 0,
     ["kayaSafeWindowRects()", "kayaPlatformFrame(node)", "kayaKeyboardInWindow()",
      "frame.maxY > keyboard.minY + tol", "runs past the window's edge", "stops short of the window's edge",
      "lies outside the safe area"],
     ["keyboardPan", "node.inset"]),
    ("the frame a reading reads", "@MainActor func kayaPlatformFrame(", 0,
     ["kayaBleedFrames[node.id]", "kayaUITextViews[node.id]?.view", "kayaFirstResponderView()",
      "kayaNodeFrames[node.id]"],
     ["keyboardPan"]),
    ("the iOS insets", "@MainActor func kayaInsetWords()", 0,
     ["window.safeAreaInsets", "statusBarManager?.isStatusBarHidden", '"cutout"'], ["fullscreen"]),
    ("the keyboard's frame", "@MainActor func kayaWatchKeyboard() {", 0,
     ["UIResponder.keyboardWillChangeFrameNotification", "UIResponder.keyboardFrameEndUserInfoKey",
      "UIResponder.keyboardWillHideNotification", "kayaKeyboardScreenFrame = end", "kayaKeyboardMoved()"], []),
    ("the keyboard over the window", "@MainActor func kayaKeyboardInWindow() -> CGRect? {\n        guard", 0,
     ["window.convert(kayaKeyboardScreenFrame, from: window.screen.coordinateSpace)", "r.intersection(window.bounds)"],
     ["keyboardPan"]),
    ("the pan", "@MainActor func kayaPanEvaluate() {", 0,
     ["kayaKeyboardInWindow()", "kayaFocusedFieldRects()", "kayaRootOf", "covered > 0.5",
      "kayaScene.keyboardPan = [root: next]"], []),
    ("the wall's reading", "@MainActor func kayaWallReading(", 0,
     ["kayaFocusedFieldRects()", "kayaKeyboardInWindow()", "rects.caret.maxY <= keyboard.minY + 0.5",
      "if kayaKeyboardFrames == 0 {", 'UserDefaults(suiteName: ' + PREF[0] + ')',
      ".object(forKey: " + PREF[1] + ") as? Bool", "if pref == false {"],
     ["keyboardPan"]),
    ("the caret line", "@MainActor func kayaFocusedFieldRects()", 0,
     ["input.caretRect(for: at)", "view is UITextField || view is UITextView"], []),
]
CALLS = [
    (SWIFT, "the app's bleed reaches the arm",
     "case (propBleed, valueBool):\n kayaScene.nodes[id]!.bleed = raw[body + 24] != 0"),
    (SWIFT, "a bled picture is drawn through the bleed",
     "if node.bleed, let image = node.image {\n let fit = kayaImageFit(natural: image.size, node: node) ?? image.size\n KayaBleed(node: node, slotHeight: fit.height)"),
    (SWIFT, "a bled canvas is drawn through the bleed",
     ".background(kayaHarnessDrivesFrames ? nil : KayaCanvasTicker())\n .modifier(KayaBleedIfAsked(node: node))"),
    (SWIFT, "a bled video view is drawn through the bleed",
     ".accessibilityAction(named: actions[1].0, actions[1].1)\n .modifier(KayaBleedIfAsked(node: node))"),
    (SWIFT, "a bled self-view is drawn through the bleed",
     ".accessibilityAddTraits(.isImage)\n .modifier(KayaBleedIfAsked(node: node))\n } else {"),
    (SWIFT, "the bleed when asked", "if node.bleed {\n KayaBleed(node: node) { content }"),
    (SWIFT, "the root alone pans", "let pan = isRoot ? kayaScene.keyboardPan[node.id] ?? 0 : 0\n kayaAnchored.offset(y: -pan).clipShape(KayaTopEdgeClip(active: pan > 0))"),
    (SWIFT, "the keyboard is watched from the primary root", "kayaArmSelftestStartupDeadline()\n #if os(iOS)\n kayaWatchKeyboard()"),
    (SWIFT, "a following scroll keeps its end as the keyboard rises",
     "if node.followsEnd, !sideways, size.height < old.height - 0.5, wasAtEnd {"),
    (SWIFT, "the wall holds type", 'kayaAwaitAnswer(answered)\n if let walled = kayaKeyboardWall("type") { failures.append(walled) }'),
    (SWIFT, "the wall holds type_secret",
     'kayaAwaitAnswer(secretAnswered)\n if let walled = kayaKeyboardWall("type_secret") { failures.append(walled) }'),
    (SWIFT, "the wall holds press return",
     'kayaAwaitAnswer(pressAnswered)\n if let walled = kayaKeyboardWall("press return") { failures.append(walled) }'),
    (SWIFT, "the wall holds press tab and space",
     'if let walled = kayaKeyboardWall("press \\(parts[1])") { failures.append(walled) }'),
    (SWIFT, "expect_keyboard reads the platform", "let keyboardUp = DispatchQueue.main.sync { kayaKeyboardInWindow() != nil }"),
    (SWIFT, "expect_safe reads the platform", "let safeRead = DispatchQueue.main.sync { kayaSafeReading(parts[1]) }"),
    (SWIFT, "expect_insets reads the platform", "DispatchQueue.main.sync(execute: { kayaInsetWords() })"),
    (SWIFT, "the mac has no software keyboard", "@MainActor func kayaKeyboardInWindow() -> CGRect? { nil }"),
    (HARNESS, "harness.rs reads the keyboard", "Step::ExpectKeyboard(want) => Some(poll(|| match stage.keyboard() {"),
    (HARNESS, "harness.rs reads the safe area", "Step::ExpectSafe(t, want) => Some(poll(|| match stage.safe(*t) {"),
    (HARNESS, "harness.rs reads the insets", "Step::ExpectInsets(want) => Some(poll(|| match stage.insets() {"),
    (RUNSIM, "the iOS lane raises the keyboard before any leg",
     "boot_pool()\n_keyboard_wrong = software_keyboard([*UDIDS, PAD_UDID], True)\nif _keyboard_wrong:\n die("),
    (RUNSIM, "the iOS lane puts the keyboard setting back", "wrong = software_keyboard(restored, False)"),
    (RUNSIM, "the setting is read back", 'if got != want:\n wrong.append('),
    (IOS_LANE, "the lane's one spelling of the setting", "SOFTWARE_KEYBOARD_PREF = (" + ", ".join(PREF) + ")"),
]


def findings(sources, backends=None):
    backends = BACKENDS if backends is None else backends
    out = []
    swift = sources[SWIFT]
    for label, opener, at, wants, never in BLOCKS:
        found = blocks(swift, opener)
        if len(found) <= at:
            out.append(f"safearea: {label} is gone — {SWIFT} lacks {opener.splitlines()[0]}")
            continue
        for want in wants:
            if flat(want) not in flat(found[at]):
                out.append(f"safearea: {label} lacks {want[:80]}")
        for name in never:
            if name in found[at]:
                out.append(f"safearea: {label} names {name}")
    bleed = blocks(swift, BLOCKS[0][1])
    if bleed and bleed[0].count(".ignoresSafeArea(") != 1:
        out.append(f"safearea: the bleed names .ignoresSafeArea( {bleed[0].count('.ignoresSafeArea(')} times, "
                   f"wanted once — a frame reader that ignores the safe area itself reads its own "
                   f"extended frame, and a bleed that stopped at the safe area read as bleeding")
    walls = swift.count("kayaKeyboardWall(")
    if walls != 5:
        out.append(f"safearea: the wall is called from {walls - 1} typing verb site(s), wanted 4 "
                   f"(type, type_secret, press return, press tab and space)")
    for rel, label, call in CALLS:
        if flat(call) not in flat(sources[rel]):
            out.append(f"safearea: {label} no longer holds — {rel} lacks {call.splitlines()[0]}")
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in backends:
            out.append(f"safearea: {rel} no longer stubs the safe area and has no row in "
                       f"tools/lib/safearea_routes.py's BACKENDS")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8")
               for rel in [HARNESS, SWIFT, RUNSIM, IOS_LANE, *STUBBED]}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("safearea clauses held",
              sum(len(w) + len(n) + 1 for *_, w, n in BLOCKS) + len(CALLS) + 1, floor=60)
    g.counted("safearea backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("a bleed taking the keyboard's region", SWIFT, r"\.ignoresSafeArea\(\.container, edges: edges\)",
         ".ignoresSafeArea(.all, edges: edges)", "the bleed names .all"),
        ("a bleed that stops at the safe area", SWIFT,
         r"(kayaBleedFrames\[node\.id\] = f \}\n\s+\}\n\s+\))\n\s+\.ignoresSafeArea\(\.container, edges: edges\)",
         r"\1", "the bleed lacks kayaBleedFrames[node.id] = f }"),
        ("the bleed's reader outside the ignore", SWIFT,
         r"(\n\s+)content\n\s+\.background\(\n((?:.*\n){5}\s+\))\n\s+\.ignoresSafeArea\(\.container, edges: edges\)\n",
         r"\1content\1.ignoresSafeArea(.container, edges: edges)\1.background(\n\2\n",
         "the bleed lacks kayaBleedFrames[node.id] = f }"),
        ("the bleed's reader extending itself", SWIFT,
         r"(\.onChange\(of: geo\.frame\(in: \.global\)\) \{ _, f in kayaBleedFrames\[node\.id\] = f \}\n\s+\})\n",
         r"\1\n                    .ignoresSafeArea(.container, edges: edges)\n",
         "the bleed names .ignoresSafeArea( 2 times"),
        ("a bleed that stops at the inset", SWIFT,
         r"KayaBleedLayout\(edges: edges, inset: inset, slotHeight: slotHeight\)",
         "KayaBleedLayout(edges: edges, inset: 0, slotHeight: slotHeight)", "the bleed lacks KayaBleedLayout(edges: edges, inset: inset"),
        ("the slot passed through, the runaway", SWIFT,
         r"let answer = subviews\.first\?\.sizeThatFits\(grown\) \?\? \.zero\n\s+return CGSize\(width: max\(0, answer\.width - dx\), height: max\(0, answer\.height - dy\)\)",
         "return subviews.first?.sizeThatFits(proposal) ?? .zero", "the bleed's slot names sizeThatFits(proposal)"),
        ("touching through a padded container", SWIFT, r"kayaFilledInset\(parent\) == 0", "true",
         "the touching sides lacks kayaFilledInset(parent) == 0"),
        ("expect_safe blind to a runaway", SWIFT, r'return \(nil, "\\\(spec\) runs past the window\'s edge: \\\(facts\)"\)',
         'return ("bleeds", facts)', "expect_safe's reading lacks runs past the window's edge"),
        ("expect_safe answering from the pan", SWIFT, r"let keyboard = kayaKeyboardInWindow\(\)\n(\s+)let tol: CGFloat = 1",
         r"let keyboard = kayaScene.keyboardPan.isEmpty ? nil : kayaKeyboardInWindow()\n\1let tol: CGFloat = 1",
         "expect_safe's reading names keyboardPan"),
        ("expect_safe ignoring the keyboard", SWIFT, r"frame\.maxY > keyboard\.minY \+ tol", "false",
         "expect_safe's reading lacks frame.maxY > keyboard.minY + tol"),
        ("the iOS insets off the fullscreen prop", SWIFT,
         r"let barHidden = window\.windowScene\?\.statusBarManager\?\.isStatusBarHidden \?\? false",
         "let barHidden = kayaScene.windows[0]?.fullscreen ?? false", "the iOS insets names fullscreen"),
        ("the keyboard frame never kept", SWIFT, r"kayaKeyboardScreenFrame = end\n", "_ = end\n",
         "the keyboard's frame lacks kayaKeyboardScreenFrame = end"),
        ("the pan never written", SWIFT, r"kayaScene\.keyboardPan = \[root: next\]", "_ = next",
         "the pan lacks kayaScene.keyboardPan = [root: next]"),
        ("the pan never applied", SWIFT, r"kayaAnchored\.offset\(y: -pan\)\.clipShape\(KayaTopEdgeClip\(active: pan > 0\)\)",
         "kayaAnchored", "the root alone pans"),
        ("the pan as a branch, which rebuilt the root and dropped the focus", SWIFT,
         r"kayaAnchored\.offset\(y: -pan\)\.clipShape\(KayaTopEdgeClip\(active: pan > 0\)\)",
         "if pan > 0 { kayaAnchored.offset(y: -pan) } else { kayaAnchored }", "the root alone pans"),
        ("the keyboard never watched", SWIFT, r"(#if os\(iOS\)\n\s+)kayaWatchKeyboard\(\)", r"\1_ = 0",
         "the keyboard is watched from the primary root"),
        ("the wall's caret read off the field", SWIFT, r"rects\.caret\.maxY <= keyboard\.minY \+ 0\.5",
         "rects.field.minY <= keyboard.minY + 0.5", "the wall's reading lacks rects.caret.maxY"),
        ("type without the wall", SWIFT, r'\n\s+if let walled = kayaKeyboardWall\("type"\) \{ failures\.append\(walled\) \}', "",
         "the wall holds type"),
        ("press return without the wall", SWIFT,
         r'\n\s+if let walled = kayaKeyboardWall\("press return"\) \{ failures\.append\(walled\) \}', "",
         "the wall holds press return"),
        ("the wall's sentence blaming the keyboard setting whatever it saw", SWIFT,
         r"if kayaKeyboardFrames == 0 \{", "if true {", "the wall's reading lacks if kayaKeyboardFrames == 0 {"),
        ("the wall's sentence blaming the setting it read as false", SWIFT,
         r"if pref == false \{", "if false {", "the wall's reading lacks if pref == false {"),
        ("a following scroll losing its end", SWIFT, r"if node\.followsEnd, !sideways, size\.height < old\.height - 0\.5, wasAtEnd \{",
         "if false {", "a following scroll keeps its end"),
        ("the mac answering a keyboard", SWIFT, r"@MainActor func kayaKeyboardInWindow\(\) -> CGRect\? \{ nil \}",
         "@MainActor func kayaKeyboardInWindow() -> CGRect? { .zero }", "the mac has no software keyboard"),
        ("harness.rs not reading the keyboard", HARNESS, r"match stage\.keyboard\(\) \{", "match Ok::<bool, String>(false) {",
         "harness.rs reads the keyboard"),
        ("the lane never raising the keyboard", RUNSIM,
         r"_keyboard_wrong = software_keyboard\(\[\*UDIDS, PAD_UDID\], True\)", "_keyboard_wrong = []",
         "the iOS lane raises the keyboard"),
        ("the lane leaving the setting behind", RUNSIM, r"wrong = software_keyboard\(restored, False\)", "wrong = []",
         "the iOS lane puts the keyboard setting back"),
        ("the setting never read back", RUNSIM, r"if got != want:\n(\s+)wrong\.append\(", r"if False:\n\1wrong.append(",
         "the setting is read back"),
        ("the lane spelling another setting", IOS_LANE, r'"AutomaticMinimizationEnabled"\)', '"HardwareKeyboardLastSeen")',
         "the lane's one spelling of the setting"),
    ]
    for label, rel, pattern, repl, want in cuts:
        broken = g.doctor(f"safearea: {label}", sources[rel], pattern, repl)
        g.negative(f"safearea: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want=want)
    for rel in STUBBED:
        if rel in BACKENDS and STUBBED[rel] not in sources[rel]:
            continue
        n = sources[rel].count(STUBBED[rel])
        broken = g.doctor(f"safearea: {rel}'s stubs gone without a row", sources[rel],
                          re.escape(STUBBED[rel]), "todo!()", want=n)
        g.negative(f"safearea: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="has no row")
