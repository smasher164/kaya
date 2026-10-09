"""docs/toast-plan.md T13: the toast's arms, held where no scene can see them go.

toast.steps reads the second of two toasts within the expect deadline, so an
arm that queues is red on its lane; but a read that answered from kaya's model
would agree with every show while the screen showed nothing, a press that wrote
the model would pass while no button existed, and a timer that never started
or a close that answered twice is invisible until a user waits. A backend whose
`depth_stub("toast")` goes must take a row in BACKENDS."""

import re

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
STUBBED = {GTK: 'depth_stub("toast")', WINUI: 'depth_stub("toast")', COMPOSE: 'depthStub("toast")'}
BACKENDS = {SWIFT: "the SwiftUI arm"}
MODEL = r"kayaScene|KayaHost\."
# (label, opener, what the body must hold)
ARM = [
    ("the host", "struct KayaToastHost: ViewModifier {",
     ["let shown = kayaScene.toasts[windowId]", ".overlay(alignment: .top) {",
      "KayaToastView(windowId: windowId, shown: shown)", ".id(shown.token)"]),
    ("the close", "private func closeToast() {",
     ["guard kayaScene.toasts[windowId]?.token == shown.token else { return }",
      "kayaScene.toasts[windowId] = nil", "KayaHost.emitToastClosed(shown.id)"]),
    ("the view", "struct KayaToastView: View {",
     ["Button(shown.label) { KayaHost.toastAction(shown.id) }", ".accessibilityIdentifier(\"kaya.toast.text\")",
      ".accessibilityIdentifier(\"kaya.toast.action\")", ".accessibilityAction(.escape) { closeToast() }",
      ".onAppear { kayaAnnounceToast(shown) }", ".task(id: shown.token) {",
      "if !(hovering || textFocused || actionFocused) { left -= 0.1 }",
      "left -= 0.1 }\n            }\n            closeToast()"]),
    ("the announcement", "@MainActor func kayaAnnounceToast(_ shown: KayaToastShown) {",
     ["notification: .announcementRequested", "UIAccessibility.post(notification: .announcement, argument: said)"]),
    ("the listener", "func kayaToastEarInstall() {",
     ['"AXAnnouncementRequested" as CFString', "kayaToastHeard.append(said)"]),
]
# (label, opener, which definition: 0 the mac, 1 iOS, what it must hold)
READS = [
    ("the mac read", "private func kayaToastRead() -> [(String, String)] {", 0,
     ['kayaAxFindAll(app, "kaya.toast.text", 0, &texts)', "kayaAxCopy(text, kAXValueAttribute)",
      'kayaAxFind(parent as! AXUIElement, "kaya.toast.action")']),
    ("the iOS read", "private func kayaToastRead() -> [(String, String)] {", 1,
     ['kayaAxFind(window, "kaya.toast.text")', 'kayaAxFind(window, "kaya.toast.action")?.accessibilityLabel']),
    ("the mac press", "private func kayaToastPress(_ identifier: String) -> Bool {", 0,
     ["AXUIElementPerformAction(button, kAXPressAction as CFString) == .success"]),
    ("the iOS press", "private func kayaToastPress(_ identifier: String) -> Bool {", 1,
     ["return toast.accessibilityPerformEscape()", "return button.accessibilityActivate()"]),
]
CALLS = [
    ("expect_toast reads the platform's toast", "let shown = kayaToastRead()"),
    ("toast_action and toast_close press the platform's buttons",
     'let pressed = kayaToastPress(parts[0] == "toast_action" ? "kaya.toast.action" : "kaya.toast.close")'),
    ("the listener is installed before the script runs", "kayaToastEarInstall()\n    #endif\n    Thread {"),
    ("expect_toast_announced reads what the listener heard", "let heard = DispatchQueue.main.sync { kayaToastHeard }"),
]
SENTENCES = {
    HARNESS: ['Ok(format!("toast {want:?}"))', 'Err(format!("toast {got:?}, wanted {want:?}"))',
              'Err(format!("no toast shown, wanted {want:?}"))',
              'Err(format!("toast {:?} shown, wanted none", format!("{text}|{action}")))',
              'Ok("no toast".to_owned())', 'Ok(format!("toast announced {want:?}"))',
              'Err(format!("toast {want:?} not announced; heard {heard:?}"))',
              'Some(Err(format!("{verb}: no toast button on screen to press")))'],
    SWIFT: ['observed.append("toast \\"\\(want)\\"")', 'failures.append("toast \\"\\(got)\\", wanted \\"\\(want)\\"")',
            'failures.append("no toast shown, wanted \\"\\(want)\\"")',
            'failures.append("toast \\"\\(text)|\\(action)\\" shown, wanted none")', 'observed.append("no toast")',
            'observed.append("toast announced \\"\\(want)\\"")',
            'failures.append("toast \\"\\(want)\\" not announced; heard [\\(list)]")',
            'failures.append("\\(parts[0]): no toast button on screen to press")'],
}


def present_arm(swift):
    start = swift.find("case applyPresentToast:")
    stop = swift.find("case applyWithdrawToast:", start)
    return swift[start:stop] if start >= 0 and stop > start else ""


def findings(sources, backends=None):
    backends = BACKENDS if backends is None else backends
    out = []
    swift = sources[SWIFT]
    arm = present_arm(swift)
    if not arm:
        out.append("toast: the SwiftUI apply arm for present_toast is gone")
    else:
        if flat("kayaScene.toasts[toastWindow] = KayaToastShown(") not in flat(arm):
            out.append("toast: the present arm no longer REPLACES the window's slot — a toast that waits "
                       "behind another is a toast the user never sees")
        if re.search(r"\.append\(|\.insert\(|Queue", arm):
            out.append("toast: the present arm queues — T7 replaces the shown toast")
    if flat(swift).count(flat(".modifier(KayaToastHost(")) < 2:
        out.append("toast: KayaToastHost rides fewer than the primary and the auxiliary roots, so a "
                   "window shows no toast")
    for label, opener, needs in ARM:
        body = blocks(swift, opener)
        if len(body) != 1:
            out.append(f"toast: {opener} is defined {len(body)} times, wanted once")
            continue
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"toast: {label} lacks {need.splitlines()[0]} — the toast could go unseen, "
                           f"unheard, never close, or answer twice")
    if swift.count("KayaHost.emitToastClosed(") != 1:
        out.append(f"toast: the arm reports `closed` from {swift.count('KayaHost.emitToastClosed(')} sites, "
                   f"wanted closeToast() alone")
    if swift.count("KayaHost.toastAction(") != 1:
        out.append(f"toast: the arm presses the action from {swift.count('KayaHost.toastAction(')} sites, "
                   f"wanted the button alone")
    for label, opener, at, needs in READS:
        found = blocks(swift, opener)
        if len(found) != 2:
            out.append(f"toast: {opener} is defined {len(found)} times, wanted one per platform")
            continue
        for need in needs:
            if flat(need) not in flat(found[at]):
                out.append(f"toast: {label} lacks {need} — it no longer reads or presses the "
                           f"platform's own toast")
        if re.search(MODEL, found[at]):
            out.append(f"toast: {label} reaches kaya's model, so it could answer from what kaya asked "
                       f"for instead of what the platform shows")
    for label, call in CALLS:
        if flat(call) not in flat(swift):
            out.append(f"toast: {label} no longer holds — the file lacks {call.splitlines()[0]}")
    for rel, spelled in SENTENCES.items():
        for line in spelled:
            if flat(line) not in flat(sources[rel]):
                out.append(f"toast: {rel} no longer says {line} — the two harnesses' verdicts must be "
                           f"the same bytes")
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in backends:
            out.append(f"toast: {rel} no longer stubs the toast and has no row in "
                       f"tools/lib/toast_routes.py's BACKENDS")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in [HARNESS, SWIFT, *STUBBED]}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("toast clauses held",
              3 + sum(len(n) for _, _, n in ARM) + 2 + sum(len(n) + 1 for _, _, _, n in READS) + len(CALLS)
              + sum(len(v) for v in SENTENCES.values()), floor=45)
    g.counted("toast backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("a queueing present arm", r"kayaScene\.toasts\[toastWindow\] = KayaToastShown\(",
         "kayaToastQueue.append(KayaToastShown(", "no longer REPLACES"),
        ("a replacement keeping the old view", r"\n\s+\.id\(shown\.token\)", "", "lacks .id(shown.token)"),
        ("the toast drawn on the primary alone", r"\n\s+\.modifier\(KayaToastHost\(windowId: windowId\)\)", "",
         "rides fewer than"),
        ("a timer that never closes", r"(if !\(hovering \|\| textFocused \|\| actionFocused\) \{ left -= 0\.1 \}\n\s+\}\n)\s+closeToast\(\)\n",
         r"\1", "lacks left -= 0.1 }"),
        ("a timer that ignores the hover", r"if !\(hovering \|\| textFocused \|\| actionFocused\) \{ left -= 0\.1 \}",
         "left -= 0.1", "lacks if !(hovering"),
        ("a close that answers a replaced toast",
         r"\n\s+guard kayaScene\.toasts\[windowId\]\?\.token == shown\.token else \{ return \}", "",
         "lacks guard kayaScene.toasts"),
        ("a second `closed` report", r"(KayaHost\.toastAction\(shown\.id\))", r"\1; KayaHost.emitToastClosed(shown.id)",
         "reports `closed` from 2 sites"),
        ("the action pressed past the core", r"Button\(shown\.label\) \{ KayaHost\.toastAction\(shown\.id\) \}",
         "Button(shown.label) { kayaScene.toasts[windowId] = nil }", "lacks Button(shown.label)"),
        ("the toast unannounced", r"\n\s+\.onAppear \{ kayaAnnounceToast\(shown\) \}", "",
         "lacks .onAppear { kayaAnnounceToast"),
        ("the mac read answering from the model",
         r"(let app = kayaPanelAxApp\(\)\n\s+var texts: \[AXUIElement\] = \[\]\n)",
         r"\1            if let s = kayaScene.toasts[0] { return [(s.text, s.label)] }\n",
         "the mac read reaches kaya's model"),
        ("the iOS read answering from the model", r"let action = kayaAxFind\(window, \"kaya\.toast\.action\"\)\?\.accessibilityLabel \?\? \"\"",
         'let action = kayaScene.toasts[0]?.label ?? ""', "the iOS read"),
        ("the mac press a model write",
         r"return AXUIElementPerformAction\(button, kAXPressAction as CFString\) == \.success",
         "KayaHost.toastAction(kayaScene.toasts[0]?.id ?? 0); return button == button",
         "the mac press"),
        ("the listener never installed", r"\n\s+kayaToastEarInstall\(\)(\n\s+#endif\n\s+Thread \{)", r"\1",
         "the listener is installed"),
        ("the sentence reworded in Swift", r'failures\.append\("no toast shown, wanted',
         'failures.append("no toast on screen, wanted', "no longer says"),
    ]
    for label, pattern, repl, want in cuts:
        broken = g.doctor(f"toast: {label}", sources[SWIFT], pattern, repl)
        g.negative(f"toast: {label}", lambda broken=broken: findings({**sources, SWIFT: broken}), want=want)
    for rel in STUBBED:
        n = sources[rel].count(STUBBED[rel])
        if n == 0:
            continue
        broken = g.doctor(f"toast: {rel}'s stubs gone without a row", sources[rel],
                          re.escape(STUBBED[rel]), "todo!()", want=n)
        g.negative(f"toast: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="has no row")
