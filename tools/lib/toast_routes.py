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
     ["let shown = self.shown", "kayaToastLayer(windowId) == nil ? kayaScene.toasts[windowId] : nil",
      "return covered ? nil : kayaScene.toasts[windowId]", ".overlay(alignment: .top) {",
      "KayaToastView(windowId: windowId, shown: shown)", ".id(shown.token)"]),
    ("the close", "private func closeToast() {",
     ["guard kayaScene.toasts[windowId]?.token == shown.token else { return }",
      "kayaScene.toasts[windowId] = nil", "KayaHost.emitToastClosed(shown.id)"]),
    ("the view", "struct KayaToastView: View {",
     ["Button(shown.label) { KayaHost.toastAction(shown.id) }", ".accessibilityIdentifier(\"kaya.toast.text\")",
      ".accessibilityIdentifier(\"kaya.toast.action\")", ".accessibilityAction(.escape) { closeToast() }",
      ".onAppear { kayaAnnounceToast(shown) }", ".task(id: shown.token) {",
      "let gap = kayaSeconds(now - last)", "if hovering {\n                    timer.heldPointer += gap",
      "} else if textFocused || actionFocused {\n                    timer.heldFocus += gap",
      "} else {\n                    timer.counted += gap", "kayaToastClocks[windowId] = timer\n            }\n            closeToast()"]),
    ("the timer's reading", "func kayaToastClockSaid() -> String {",
     ["guard let t = kayaToastClocks[windowId], t.token == shown.token else {",
      "kayaSeconds(ContinuousClock.now - t.started)", "if t.cancelled {"]),
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
    ("expect_toast reads the platform's toast", "var shown = kayaToastRead()"),
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
            'failures.append("toast \\"\\(text)|\\(action)\\" shown, wanted none\\(kayaToastClockSaid())")',
            'observed.append("no toast")',
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
    if flat(swift).count(flat(".modifier(KayaToastHost(")) < 3:
        out.append("toast: KayaToastHost rides fewer than the primary, the auxiliary roots and the sheets "
                   "(docs/media-player-plan.md M16 (20)), so a window or a sheet shows no toast")
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


# T8's "above its bottom bars" with a dock under the panes (docs/traps.md, the
# toast over the dock): each arm lifts its toast by the dock it measured, and
# expect_toast reads the toast's frame against the dock's on every harness.
# (file, what holds, the spelling, a cut that breaks it)
PLACEMENT = [
    (HARNESS, "expect_toast reads the toast's placement",
     "} else if let Some(over) = stage.toast_over_dock() {",
     (r"\} else if let Some\(over\) = stage\.toast_over_dock\(\) \{", "} else if let Some(over) = None::<String> {")),
    (GTK, "the toast sits above the window's bottom bars",
     "lift_toasts(&overlay, window_shell(core, window).bottom_bar_height());",
     (r"\n\s+lift_toasts\(&overlay, window_shell\(core, window\)\.bottom_bar_height\(\)\);", "")),
    (GTK, "a bottom bar's new height lifts the shown toast", "view.connect_bottom_bar_height_notify(",
     (r"view\.connect_bottom_bar_height_notify\(", "view.connect_top_bar_height_notify(")),
    (GTK, "the placement read compares the toast with the dock", "(t.y() + t.height() > d.y() + 1.0).then(",
     (r"\(t\.y\(\) \+ t\.height\(\) > d\.y\(\) \+ 1\.0\)\.then\(", "(false).then(")),
    (WINUI, "the InfoBar sits above the dock", "INFO_BAR_MARGIN - skin::dock_height(window)?",
     (r" - skin::dock_height\(window\)\?", "")),
    (WINUI, "the placement read compares the InfoBar with the dock", "Ok((bottom > top + 1.0).then(",
     (r"Ok\(\(bottom > top \+ 1\.0\)\.then\(", "Ok((false).then(")),
    (SWIFT, "expect_toast reads the toast's placement",
     "} else if let over = DispatchQueue.main.sync(execute: { kayaToastOverDock() }) {",
     (r"DispatchQueue\.main\.sync\(execute: \{ kayaToastOverDock\(\) \}\)", "Optional<String>.none")),
    (SWIFT, "the toast's frame is recorded", ".onChange(of: g.frame(in: .global)) { _, f in kayaToastFrame = f }",
     (r"\.onChange\(of: g\.frame\(in: \.global\)\) \{ _, f in kayaToastFrame = f \}", ".onChange(of: g.frame(in: .global)) { _, _ in }")),
    (COMPOSE, "the snackbar sits above the dock",
     "KayaSceneModel.sectionBarHeight + KayaSceneModel.dockHeight",
     (r" \+ KayaSceneModel\.dockHeight\n", "\n")),
    (COMPOSE, "the dock's height is composition state",
     "KayaSceneModel.dockHeight = with(density) { it.size.height.toDp() }",
     (r"KayaSceneModel\.dockHeight = with\(density\) \{ it\.size\.height\.toDp\(\) \}", "Unit")),
    (COMPOSE, "expect_toast reads the toast's placement", "val over = onUi(activity) { kayaToastOverDock() }",
     (r"val over = onUi\(activity\) \{ kayaToastOverDock\(\) \}", "val over: String? = null")),
]


def placement_findings(sources):
    return [f"toast: {rel}: {label} no longer holds — the file lacks {call}"
            for rel, label, call, _ in PLACEMENT if flat(call) not in flat(sources[rel])]


def placement_run(g, sources):
    g.counted("toast placement clauses held", len(PLACEMENT), floor=11)
    for line in placement_findings(sources):
        g.finding(line)
    for rel, label, _call, (pattern, repl) in PLACEMENT:
        broken = g.doctor(f"toast: {label} ({rel})", sources[rel], pattern, repl)
        g.negative(f"toast: {label} ({rel})",
                   lambda rel=rel, broken=broken: placement_findings({**sources, rel: broken}), want=label)


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
        ("a timer that never closes", r"(kayaToastClocks\[windowId\] = timer\n\s+\}\n)\s+closeToast\(\)\n",
         r"\1", "lacks kayaToastClocks[windowId] = timer"),
        ("a timer that ignores the hover", r"if hovering \{\n(\s+)timer\.heldPointer \+= gap",
         r"if false {\n\1timer.heldPointer += gap", "lacks if hovering {"),
        ("a timer counting wakes instead of the clock", r"timer\.counted \+= gap", "timer.counted += 0.1",
         "lacks } else {"),
        ("a reading taken from a replaced toast's timer",
         r"guard let t = kayaToastClocks\[windowId\], t\.token == shown\.token else \{",
         "guard let t = kayaToastClocks[windowId] else {", "lacks guard let t"),
        ("a stuck toast's failure without its timer", r"shown, wanted none\\\(kayaToastClockSaid\(\)\)\"\)",
         'shown, wanted none")', "no longer says"),
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
        ("the sentence reworded in Swift", r'failures\.append\("no toast shown, wanted (?=\\"\\\(want\)\\""\))',
         'failures.append("no toast on screen, wanted', "no longer says"),
    ]
    for label, pattern, repl, want in cuts:
        broken = g.doctor(f"toast: {label}", sources[SWIFT], pattern, repl)
        g.negative(f"toast: {label}", lambda broken=broken: findings({**sources, SWIFT: broken}), want=want)
    compose_run(g, sources)
    native_run(g, sources)
    placement_run(g, sources)
    for rel in STUBBED:
        n = sources[rel].count(STUBBED[rel])
        if n == 0:
            continue
        broken = g.doctor(f"toast: {rel}'s stubs gone without a row", sources[rel],
                          re.escape(STUBBED[rel]), "todo!()", want=n)
        g.negative(f"toast: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="has no row")


# The Compose row (docs/toast-plan.md §3): Material's snackbar, held to T6, T7
# and T13 where material3 1.3.1's defaults would break them — showSnackbar waits
# on a Mutex behind a snackbar nobody dismissed, and one with an action defaults
# to Indefinite.
A11Y = "android/kaya/src/main/kotlin/dev/kaya/KayaHarnessAccessibility.kt"
BACKENDS[COMPOSE] = "the Compose arm"
COMPOSE_MODEL = r"KayaSceneModel"
COMPOSE_ARM = [
    ("the present arm", "APPLY_PRESENT_TOAST -> {", ["KayaSceneModel.toast = KayaToast("]),
    ("the host", "internal fun KayaToastHost(modifier: Modifier, layer: Long = 0L) {",
     ["LaunchedEffect(shown?.token) {", "host.currentSnackbarData?.dismiss()",
      "val result = host.showSnackbar(KayaToastVisuals(shown))",
      "if (KayaSceneModel.toast?.token != shown.token) return@LaunchedEffect",
      "KayaPresent.toastAction(shown.id)", "KayaPresent.emitToastClosed(shown.id)"]),
    ("the duration", "private class KayaToastVisuals(toast: KayaToast) : SnackbarVisuals {",
     ["override val duration = if (toast.long) SnackbarDuration.Long else SnackbarDuration.Short"]),
    ("the bar", "private fun KayaToastBar(data: SnackbarData) {",
     ["if (value != SwipeToDismissBoxValue.Settled) data.dismiss()", "SwipeToDismissBox(state = state",
      ".testTag(KayaCompose.TOAST_TAG)", "onClick = { data.performAction() }",
      "Modifier.testTag(KayaCompose.TOAST_ACTION_TAG)", "Modifier.testTag(KayaCompose.TOAST_TEXT_TAG)"]),
]
COMPOSE_READS = [
    ("the read", "private fun kayaToastBars(activity: ComponentActivity)",
     ["root.measureAndLayoutForTest()", "walk(root.semanticsOwner.rootSemanticsNode, 0)", "== TOAST_TAG"]),
    ("the read's fields", "private fun kayaToastRead(activity: ComponentActivity)",
     ["kayaTagText(bar, TOAST_TEXT_TAG)", "kayaTagText(bar, TOAST_ACTION_TAG)"]),
    ("the press", "private fun kayaToastPress(activity: ComponentActivity, action: Boolean): Boolean {",
     ["button.config.getOrNull(SemanticsActions.OnClick)?.action", "host.config.getOrNull(SemanticsActions.Dismiss)?.action"]),
]
COMPOSE_CALLS = [
    ("the host rides the window's root", "KayaToastHost(Modifier.align(Alignment.BottomCenter))"),
    ("expect_toast reads the platform's snackbar", "val shown = onUi(activity) { kayaToastRead(activity) }"),
    ("toast_action and toast_close press the platform's doors",
     'val pressed = onUi(activity) { kayaToastPress(activity, parts[0] == "toast_action") }'),
    ("expect_toast_announced reads what the service was handed",
     "val heard = KayaHarnessAccessibility.heardLiveRegions()"),
]
COMPOSE_EAR = ["event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED",
               "if (source == null || source.liveRegion == android.view.View.ACCESSIBILITY_LIVE_REGION_NONE) return",
               "synchronized(heard) { heard.add(said) }"]
COMPOSE_SENTENCES = [
    'observed.add("toast \\"$want\\"")', 'failures.add("toast \\"${one.first}|${one.second}\\", wanted \\"$want\\"")',
    'failures.add("no toast shown, wanted \\"$want\\"")',
    'failures.add("toast \\"${one.first}|${one.second}\\" shown, wanted none")', 'observed.add("no toast")',
    'observed.add("toast announced \\"$want\\"")', 'failures.add("toast \\"$want\\" not announced; heard [$list]")',
    'failures.add("${parts[0]}: no toast button on screen to press")',
]


def compose_findings(sources):
    out = []
    kt = sources[COMPOSE]
    for label, opener, needs in COMPOSE_ARM:
        body = blocks(kt, opener)
        if len(body) != 1:
            out.append(f"toast: Compose's {opener} is defined {len(body)} times, wanted once")
            continue
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"toast: Compose's {label} lacks {need} — the snackbar could queue, wait forever, "
                           f"go unseen, or answer twice")
        if label == "the present arm" and re.search(r"\.add\(|Queue", body[0]):
            out.append("toast: Compose's present arm queues — T7 replaces the shown toast")
        if label == "the host" and flat(body[0]).find(flat("host.currentSnackbarData?.dismiss()")) > \
                flat(body[0]).find(flat("host.showSnackbar(")):
            out.append("toast: Compose's host shows before it dismisses the shown snackbar — the new one "
                       "waits on Material's Mutex")
    if "SnackbarDuration.Indefinite" in kt:
        out.append("toast: Compose names SnackbarDuration.Indefinite — T6 has no indefinite toast")
    for door, want in (("KayaPresent.toastAction(", 1), ("KayaPresent.emitToastClosed(", 1)):
        if kt.count(door) != want:
            out.append(f"toast: Compose calls {door} from {kt.count(door)} sites, wanted the host's one answer")
    for label, opener, needs in COMPOSE_READS:
        body = blocks(kt, opener)
        if len(body) != 1:
            out.append(f"toast: Compose's {opener} is defined {len(body)} times, wanted once")
            continue
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"toast: Compose's {label} lacks {need} — it no longer reads or presses the "
                           f"platform's own snackbar")
        if re.search(COMPOSE_MODEL, body[0]):
            out.append(f"toast: Compose's {label} reaches kaya's model, so it could answer from what kaya "
                       f"asked for instead of what the platform shows")
    for label, call in COMPOSE_CALLS:
        if flat(call) not in flat(kt):
            out.append(f"toast: Compose: {label} no longer holds — the file lacks {call}")
    for need in COMPOSE_EAR:
        if flat(need) not in flat(sources[A11Y]):
            out.append(f"toast: {A11Y} lacks {need} — the service no longer hears a live region")
    for line in COMPOSE_SENTENCES:
        if flat(line) not in flat(kt):
            out.append(f"toast: {COMPOSE} no longer says {line} — the harnesses' verdicts must be the same bytes")
    return out


def compose_run(g, sources):
    sources = {**sources, A11Y: (ROOT / A11Y).read_text(encoding="utf-8")}
    g.counted("toast Compose clauses held",
              sum(len(n) + 1 for _, _, n in COMPOSE_ARM) + 3 + sum(len(n) + 1 for _, _, n in COMPOSE_READS)
              + len(COMPOSE_CALLS) + len(COMPOSE_EAR) + len(COMPOSE_SENTENCES), floor=40)
    for line in compose_findings(sources):
        g.finding(line)
    cuts = [
        ("a queueing Compose arm", r"KayaSceneModel\.toast = KayaToast\(", "kayaToastQueue.add(KayaToast(",
         "present arm queues", COMPOSE),
        ("the shown snackbar kept", r"\n\s+host\.currentSnackbarData\?\.dismiss\(\)", "",
         "lacks host.currentSnackbarData", COMPOSE),
        ("the old wait kept past a new show", r"LaunchedEffect\(shown\?\.token\)", "LaunchedEffect(Unit)",
         "lacks LaunchedEffect(shown?.token)", COMPOSE),
        ("Material's default duration", r"override val duration = if \(toast\.long\) SnackbarDuration\.Long else SnackbarDuration\.Short",
         "override val duration = if (toast.label.isEmpty()) SnackbarDuration.Short else SnackbarDuration.Indefinite",
         "Indefinite", COMPOSE),
        ("a Compose close that answers a replaced toast",
         r"\n\s+if \(KayaSceneModel\.toast\?\.token != shown\.token\) return@LaunchedEffect", "",
         "lacks if (KayaSceneModel.toast?.token", COMPOSE),
        ("a second Compose `closed` report", r"(KayaPresent\.toastAction\(shown\.id\))",
         r"\1; KayaPresent.emitToastClosed(shown.id)", "emitToastClosed( from 2 sites", COMPOSE),
        ("the Compose action pressed past the core", r"KayaPresent\.toastAction\(shown\.id\)", "Unit",
         "lacks KayaPresent.toastAction", COMPOSE),
        ("the swipe gone", r"SwipeToDismissBox\(state = state, backgroundContent = \{\}\)", "Box",
         "lacks SwipeToDismissBox", COMPOSE),
        ("the Compose read answering from the model", r"Pair\(kayaTagText\(bar, TOAST_TEXT_TAG\)",
         "Pair(KayaSceneModel.toast?.text ?: kayaTagText(bar, TOAST_TEXT_TAG)",
         "the read's fields reaches kaya's model", COMPOSE),
        ("the Compose press a model write",
         r"val click = button\.config\.getOrNull\(SemanticsActions\.OnClick\)\?\.action \?: return false",
         "val click = { KayaSceneModel.toast = null; true }", "the press lacks", COMPOSE),
        ("the host drawn nowhere", r"\n\s+KayaToastHost\(Modifier\.align\(Alignment\.BottomCenter\)\)", "",
         "the host rides", COMPOSE),
        ("the service deaf to live regions", r"synchronized\(heard\) \{ heard\.add\(said\) \}", "Unit",
         "no longer hears a live region", A11Y),
        ("the sentence reworded in Kotlin", r'failures\.add\("no toast shown, wanted (?=\\"\$want\\""\))',
         'failures.add("no toast on screen, wanted', "no longer says", COMPOSE),
    ]
    for label, pattern, repl, want, rel in cuts:
        broken = g.doctor(f"toast: {label}", sources[rel], pattern, repl)
        g.negative(f"toast: {label}", lambda broken=broken, rel=rel: compose_findings({**sources, rel: broken}),
                   want=want)


# The GTK and WinUI rows (docs/toast-plan.md §3, T10). GTK: libadwaita QUEUES
# a toast added while another is shown, and a NORMAL one waits behind it, so
# the shown toast is dismissed first and the new one added HIGH. WinUI: one
# InfoBar, closed and re-opened so its notification fires again, timed by
# kaya. Both answer through one deferred door each.
BACKENDS[GTK] = "the GTK arm"
BACKENDS[WINUI] = "the WinUI arm"
NATIVE_MODEL = {GTK: r"core\.scene|shown_toasts", WINUI: r"core\.scene|\.shown\b|left_ms"}
NATIVE_ARM = [
    (GTK, "the overlay", "fn install_nav_chrome(window: &gtk4::Window, id: u64) -> WindowChrome {",
     ["toasts.set_child(Some(&view));", "let hosted = tight::host(&toasts);"]),
    (GTK, "the present", "fn present_toast(core: &mut CoreState, spec: crate::protocol::ToastSpec) {",
     ["if let Some((_, old)) = core.shown_toasts.remove(&window) {\n        old.dismiss();",
      "toast.set_priority(adw::ToastPriority::High);",
      "crate::protocol::ToastDuration::Short => 5,", "crate::protocol::ToastDuration::Long => 10,",
      "toast.connect_button_clicked(move |_| toast_pressed(window, id));",
      "toast.connect_dismissed(move |_| toast_dismissed(window, id));", "overlay.add_toast(toast.clone());"]),
    (GTK, "the action's door", "fn toast_pressed(window: u64, id: u64) {",
     ["glib::idle_add_local_once(", "core.scene.toast_action(crate::protocol::ToastId(id))", "send_asks(core);",
      "refresh_roles(core);"]),
    (GTK, "the close's door", "fn toast_dismissed(window: u64, id: u64) {",
     ["glib::idle_add_local_once(", "core.scene.toast_closed(crate::protocol::ToastId(id));", "send_asks(core);"]),
    (WINUI, "the present", "fn info_bar_present(core: &mut CoreState, spec: crate::protocol::ToastSpec)",
     ["info_bar_take(window);\n    let (popup, bar, action, timer)", "toast.left_ms = info_bar_ms(spec.duration);",
      "toast.last_tick = std::time::Instant::now();",
      "let layer = info_bar_host(core, window, &popup, &bar)?;", "popup.SetIsOpen(true)?;",
      "bar.SetIsOpen(true)?;", "timer.Start()?;"]),
    (WINUI, "the bar", "fn info_bar_make(window: u64) -> windows_core::Result<InfoBarToast> {",
     ["bar.SetIsClosable(true)?;", "args.Reason()? == InfoBarCloseReason::CloseButton",
      "if !(toast.hovered || toast.focused) {\n                toast.left_ms -= gap;",
      "let gap = now.duration_since(toast.last_tick).as_millis() as i64;", "element.PointerEntered(&hover(true))?;",
      "element.GotFocus(&focus(true))?;",
      "if let Some(id) = info_bar_take(window) {\n            info_bar_answer(id, true);"]),
    (WINUI, "the announcement", "fn info_bar_announce(",
     ["format!(\"{}, {}\", spec.text, spec.action_label)", ".RaiseNotificationEvent(",
      '&HSTRING::from("InfoBarOpenedActivityId"),',
      ")?;\n    #[cfg(feature = \"harness\")]\n    info_bar_ear::raised(&said);"]),
    (WINUI, "the duration", "fn info_bar_ms(duration: crate::protocol::ToastDuration) -> i64 {",
     [".and_then(|s| s.MessageDuration())", "crate::protocol::ToastDuration::Short => 5,",
      "crate::protocol::ToastDuration::Long => 10,"]),
    (WINUI, "the doors", "fn info_bar_answer(id: u64, pressed: bool) {",
     ["dispatcher.0.TryEnqueue(&handler)", "core.scene.toast_action(crate::protocol::ToastId(id))",
      "core.scene.toast_closed(crate::protocol::ToastId(id));", "info_bar_send_asks(core);"]),
]
NATIVE_READS = [
    (GTK, "the read", "fn shown_toast_widget(core: &CoreState) -> Option<gtk4::Widget> {",
     ['widget.type_().name() == "AdwToastWidget"', "newest = Some(widget.clone());"]),
    (GTK, "expect_toast", "fn toast(&self) -> Option<(String, String)> {", ["shown_toast_widget(core)?"]),
    (GTK, "toast_action", "fn toast_action(&self) -> bool {",
     ["toast_widget_parts(&widget).1 else { return false };", "button.activate()"]),
    (GTK, "toast_close", "fn toast_close(&self) -> bool {",
     ["toast_widget_parts(&widget).2 else { return false };", "button.activate()"]),
    (GTK, "expect_toast_announced", "fn toast_announced(&self, text: &str, action: &str) -> Result<(), Vec<String>> {",
     ['format!("A toast appeared: {text}, has a button: {action}")', "toast_ear::heard()"]),
    (WINUI, "the read", "fn info_bar_window_on_screen() -> windows_core::Result<",
     ["if hosted && bar.IsOpen()? {", "popup.IsOpen()? };"]),
    (WINUI, "expect_toast", "fn toast(&self) -> Option<(String, String)> {",
     ['named_descendant(&element, "Message")?', ".GetName()?"]),
    (WINUI, "toast_action", "fn toast_action(&self) -> bool {",
     ["let Some(bar) = info_bar_on_screen()?", ".cast::<IInvokeProvider>()?\n                .Invoke()?;"]),
    (WINUI, "toast_close", "fn toast_close(&self) -> bool {",
     ['find_template_button(&bar.cast::<UIElement>()?, "CloseButton")?', ".Invoke()?;"]),
    (WINUI, "expect_toast_announced", "fn toast_announced(&self, text: &str, action: &str) -> Result<(), Vec<String>> {",
     ["info_bar_ear::said(text, action)", "info_bar_ear::heard()"]),
]
NATIVE_CALLS = [
    (GTK, "the listener walks the tree and starts the script",
     'toast_ear::install_then(move || crate::harness::spawn(&scene, GtkStage, |line| println!("{line}")));'),
    (GTK, "the listener walks before it starts anything", "walked = walk(root, 0).await;"),
    (GTK, "the listener holds the script for EAR_BOUND at most (docs/traps.md, the toast leg that never started)",
     "std::thread::sleep(EAR_BOUND);\n                if slot.lock().unwrap().is_some() {"),
    (GTK, "the listener's stream takes the announcements alone (docs/traps.md, the toast ear's full queue)",
     '.and_then(|b| b.member("Announcement"))'),
    (GTK, "the listener's stream takes the announcements alone (docs/traps.md, the toast ear's full queue)",
     "atspi::zbus::MessageStream::for_match_rule(rule, conn.connection(), None).await"),
    (GTK, "the Core undo route sends the toast's answer", "core.occurrences.send(occurrence);\n                        send_asks(core);"),
    (GTK, "a banked edit withdraws an undo toast", "for op in core.scene.take_toast_out() {"),
    (WINUI, "every present is announced", "timer.Start()?;\n    info_bar_announce(&bar, &spec)"),
    (WINUI, "an undo sends the toast's answer", "core.occurrences.send(occurrence);\n    info_bar_send_asks(core);"),
    (WINUI, "a banked edit withdraws an undo toast", "for op in core.scene.take_toast_out() {"),
]


def native_findings(sources):
    out = []
    for rel, label, opener, needs in NATIVE_ARM + NATIVE_READS:
        body = blocks(sources[rel], opener)
        if len(body) != 1:
            out.append(f"toast: {rel}'s {opener} is defined {len(body)} times, wanted once")
            continue
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"toast: {rel}'s {label} lacks {need.splitlines()[0]} — the toast could queue, go "
                           f"unseen or unheard, never close, or answer twice")
        if (rel, label, opener, needs) in NATIVE_READS and re.search(NATIVE_MODEL[rel], body[0]):
            out.append(f"toast: {rel}'s {label} reaches kaya's model, so it could answer from what kaya asked "
                       f"for instead of what the platform shows")
    for rel in (GTK, WINUI):
        for door in ("core.scene.toast_action(", "core.scene.toast_closed("):
            if sources[rel].count(door) != 1:
                out.append(f"toast: {rel} calls {door} from {sources[rel].count(door)} sites, wanted its one door")
    present = flat("".join(blocks(sources[GTK], NATIVE_ARM[1][2])))
    if present.find(flat("old.dismiss();")) > present.find(flat("overlay.add_toast(")):
        out.append("toast: GTK adds the new toast before it dismisses the shown one — libadwaita queues it")
    if "MessageStream::from(" in sources[GTK]:
        out.append(f"toast: {GTK} reads an unfiltered MessageStream::from(...): every reply lands in it, and "
                   f"unread past 64 it stops the connection reading (docs/traps.md, the toast ear's full queue)")
    for rel, label, call in NATIVE_CALLS:
        if flat(call) not in flat(sources[rel]):
            out.append(f"toast: {rel}: {label} no longer holds — the file lacks {call.splitlines()[0]}")
    return out


def native_run(g, sources):
    g.counted("toast GTK and WinUI clauses held",
              sum(len(n) for _, _, _, n in NATIVE_ARM) + sum(len(n) + 1 for _, _, _, n in NATIVE_READS)
              + 4 + 1 + 1 + len(NATIVE_CALLS), floor=60)
    for line in native_findings(sources):
        g.finding(line)
    cuts = [
        ("GTK adding beside the shown toast", r"\n(\s+)old\.dismiss\(\);", "", "lacks if let Some((_, old))", GTK),
        ("GTK's toast queued at NORMAL", r"adw::ToastPriority::High", "adw::ToastPriority::Normal",
         "lacks toast.set_priority(adw::ToastPriority::High)", GTK),
        ("GTK adding before dismissing",
         r"(if let Some\(\(_, old\)\) = core\.shown_toasts\.remove\(&window\) \{\n\s+old\.dismiss\(\);\n\s+\})",
         r"overlay.add_toast(adw::Toast::new(\"\"));\n    \1", "before it dismisses", GTK),
        ("GTK's action pressed past the core", r"core\.scene\.toast_action\(crate::protocol::ToastId\(id\)\)",
         "Vec::<ApplyOp>::new()", "lacks core.scene.toast_action", GTK),
        ("GTK answering `closed` twice", r"(\n\s+send_asks\(core\);\n\s+refresh_roles\(core\);)",
         r"\n            core.scene.toast_closed(crate::protocol::ToastId(id));\1", "toast_closed( from 2 sites", GTK),
        ("GTK's read answering from the model",
         r"let widget = shown_toast_widget\(core\)\?;",
         "let widget = shown_toast_widget(core)?; let _ = core.shown_toasts.len();",
         "expect_toast reaches kaya's model", GTK),
        ("GTK's listener starting nothing first", r"walked = walk\(root, 0\)\.await;", "walked = 8;",
         "the listener walks before", GTK),
        ("GTK's listener reading every message, its replies included",
         r"let stream = match rule \{[^}]*\};",
         "let stream: Result<_, atspi::zbus::Error> = Ok(atspi::zbus::MessageStream::from(conn.connection()));",
         "unfiltered MessageStream::from", GTK),
        ("GTK's listener holding the script unbounded", r"std::thread::sleep\(EAR_BOUND\);",
         "std::thread::park();", "for EAR_BOUND at most", GTK),
        ("WinUI re-opening without closing", r"\n\s+info_bar_take\(window\);(\n\s+let \(popup, bar, action, timer\))",
         r"\1", "lacks info_bar_take(window);", WINUI),
        ("WinUI's timer running under the pointer", r"if !\(toast\.hovered \|\| toast\.focused\) \{",
         "if true {", "lacks if !(toast.hovered", WINUI),
        ("WinUI's timer counting ticks instead of the clock", r"toast\.left_ms -= gap;",
         "toast.left_ms -= INFO_BAR_TICK_MS;", "lacks if !(toast.hovered", WINUI),
        ("WinUI's clock carried over from the last toast", r"\n\s+toast\.last_tick = std::time::Instant::now\(\);\n(\s+\(toast\.popup)",
         r"\n\1", "lacks toast.last_tick", WINUI),
        ("WinUI unannounced", r"timer\.Start\(\)\?;\n    info_bar_announce\(&bar, &spec\)", "timer.Start()?;\n    Ok(())",
         "every present is announced", WINUI),
        ("WinUI recording what it never raised",
         r"\)\?;(\n    #\[cfg\(feature = \"harness\"\)\]\n    info_bar_ear::raised\(&said\);)", r"); let _ = 0;\1",
         "lacks )?;", WINUI),
        ("WinUI answering kaya's own close", r"args\.Reason\(\)\? == InfoBarCloseReason::CloseButton", "true",
         "lacks args.Reason()", WINUI),
        ("WinUI's action pressed past the core",
         r"core\.scene\.toast_action\(crate::protocol::ToastId\(id\)\)", "Vec::<ApplyOp>::new()",
         "lacks core.scene.toast_action", WINUI),
        ("WinUI's read answering from the model", r"if hosted && bar\.IsOpen\(\)\? \{",
         "if INFO_BAR_TOASTS.with_borrow(|b| b.values().any(|t| t.shown.is_some())) {",
         "the read reaches kaya's model", WINUI),
    ]
    for label, pattern, repl, want, rel in cuts:
        broken = g.doctor(f"toast: {label}", sources[rel], pattern, repl)
        g.negative(f"toast: {label}", lambda broken=broken, rel=rel: native_findings({**sources, rel: broken}),
                   want=want)
