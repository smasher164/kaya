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
GTK = "crates/kaya/src/gtk.rs"
GTK_SECURE = "crates/kaya/src/gtk/secure_text.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
BACKENDS = {SWIFT: "the SwiftUI arm", GTK: "the GTK arm", WINUI: "the WinUI arm", COMPOSE: "the Compose arm"}
# (label, file, the block's opener, what it must hold, what it may not)
ARMS = [
    ("GTK: the user's flip emits outside the quiet guard", GTK_SECURE, "pub(super) fn reveal_doors(",
     ['connect_notify_local(Some("visibility"), move |t, _| {\n        if !quiet.get() {\n'
      "            sink.send_toggle_tag(&tag, gtk4::Text::is_visible(t));"], []),
    ("GTK: copy and cut refused while shown", GTK_SECURE, "pub(super) fn reveal_doors(",
     ['for signal in ["copy-clipboard", "cut-clipboard"]', "t.stop_signal_emission_by_name(signal);"], []),
    ("GTK: no drag out of a shown selection", GTK_SECURE, "pub(super) fn reveal_doors(",
     ["press.set_propagation_phase(gtk4::PropagationPhase::Capture);",
      "gtk4::prelude::EditableExt::select_region(&t, start, start);", "text.add_controller(press);"], []),
    ("GTK: the PRIMARY selection refuses a shown password", GTK_SECURE, "unsafe extern \"C\" fn selection_value(",
     ["if shown {", "return glib::ffi::GFALSE;"], []),
    ("GTK: the PRIMARY refusal is installed", GTK_SECURE, "fn refuse_while_shown(",
     ["(*class).get_value = Some(selection_value);"], []),
    ("GTK: every secure field takes the doors", GTK, "WidgetKind::SecureField => {",
     ["secure_text::reveal_doors(&field, &tag, &core.occurrences, &quiet);"], []),
    ("GTK: the app's write is quiet", GTK, "(NativeWidget::Secure(field), Prop::Revealed, Value::Bool(on)) => {",
     ["core.apply_quiet.set(true);\n                        text.set_visibility(on);"], ["send_toggle_tag"]),
    ("GTK: `revealable` shows kaya's eye and never the peek icon", GTK,
     "(NativeWidget::Secure(field), Prop::Revealable, Value::Bool(on)) => {",
     ["eye.set_visible(on);"], ["send_toggle_tag", "set_show_peek_icon", "set_visibility"]),
    ("GTK: the harness's toggle takes the eye's own click", GTK, "fn toggle_reveal(",
     ["eye.emit_clicked();"], ["set_visibility"]),
    ("GTK: the eye is a button the keyboard reaches, whose click leaves the focus", GTK_SECURE,
     "pub(super) fn eye(",
     ["let eye = gtk4::Button::new();", "eye.set_focus_on_click(false);", "eye.set_parent(entry);",
      "t.set_visibility(!gtk4::Text::is_visible(&t));"],
     ["set_focusable(false)", "set_can_focus(false)", "show_peek_icon"]),
    ("GTK: every secure field takes the eye, its peek icon off", GTK, "WidgetKind::SecureField => {",
     ["field.set_show_peek_icon(false);", "secure_text::eye(&field);"], []),
    ("GTK: expect_focused's eye reads the toolkit's focus", GTK, "fn eye_focused(",
     ["Ok(widget_focused(&eye))"], ["revealable", "kaya"]),
    ("GTK: the unmasked read is the bus's", GTK, "fn unmasked_len(",
     ["atspi_text_of(want, rank)", "crate::harness::unmasked_count(&shown)"],
     ["is_visible", "EditableExt::text"]),
    ("WinUI: the button's flip emits unless it agrees with the box's mode", WINUI, "fn dress_reveal_button(",
     ["let flip = (field.PasswordRevealMode()? == PasswordRevealMode::Visible) != on;",
      "if !flip {\n                    return Ok(());",
      "door.set_mode(&field, mode)?;",
      "door.sink.send_toggle_tag(&door.tag, on);",
      "button.Checked(&flipped)?;", "button.Unchecked(&flipped)?;"], []),
    ("WinUI: the flip's trace reads the transport on both sides of its send", WINUI, "fn dress_reveal_button(",
     ["let before = crate::vtrace::on().then(crate::stall::transport);\n"
      "                door.sink.send_toggle_tag(&door.tag, on);",
      '"-> toggled {on} for {}: {before} -> {}; the app has applied {} transactions",\n'
      "                        crate::wire::tag_target(&door.tag),\n"
      "                        crate::stall::transport(),"], []),
    ("WinUI: the secure text's trace reads the transport on both sides of its send", WINUI,
     "WidgetKind::SecureField => {",
     ["let before = crate::vtrace::on().then(crate::stall::transport);\n"
      "                        sink.send_text_tag(&handler_tag, &text);",
      '"-> text_changed of {} characters for {}: {before} -> {}",'], []),
    ("WinUI: a PasswordChanged with no content change since the last text_changed is no edit", WINUI,
     "WidgetKind::SecureField => {",
     ["field.PasswordChanging(", "if switching.load(std::sync::atomic::Ordering::Relaxed) {",
      "} else if args.IsContentChanging()? {\n"
      "                                    changing.store(true, std::sync::atomic::Ordering::Relaxed);",
      "edited.store(false, std::sync::atomic::Ordering::Relaxed);\n                            return Ok(());",
      "if !edited.swap(false, std::sync::atomic::Ordering::Relaxed) {"], []),
    ("WinUI: kaya's own mode switch is marked around the call", WINUI, "fn set_mode(",
     ["self.switching.store(true, Relaxed);\n        let set = field.SetPasswordRevealMode(mode);\n"
      "        self.switching.store(false, Relaxed);"], []),
    ("an action's trace says what the app answered", HARNESS, "fn await_answer(",
     ["let why = answer_wait(seen);", '"<- {why}: the app has applied {seen} -> {} transactions; {}",',
      "crate::stall::transport()"], []),
    ("WinUI: the app's write moves the button after the mode", WINUI, "fn dress_reveal_button(",
     ["let shown = field.PasswordRevealMode()? == PasswordRevealMode::Visible;",
      "if held != shown {\n        button.SetIsChecked("], []),
    ("WinUI: the template's reveal button is a tab stop", WINUI, "fn dress_reveal_button(",
     ["button.SetIsTabStop(true)?;"], ["SetIsTabStop(false)"]),
    ("WinUI: a key at the focused button types nothing into the box", WINUI, "fn dress_reveal_button(",
     ["button.CharacterReceived(", "if args.Key()? != VirtualKey::Space {",
      "peer.cast::<IToggleProvider>()?.Toggle()"], []),
    ("Compose: `press tab|space` leaves touch mode through the system's input", COMPOSE,
     "private fun kayaPressKey(", ['Log.i("kaya", "KAYA_REQUEST: key $seq $code")'], ["dispatchKeyEvent"]),
    ("WinUI: expect_focused's eye reads the button's FocusState", WINUI, "fn eye_focused(",
     ['named_descendant(&core.secure_fields[i].cast()?, "RevealButton")?',
      "FocusState()? != FocusState::Unfocused"], []),
    ("WinUI: every secure field dresses its button", WINUI, "WidgetKind::SecureField => {",
     ["field.SetPasswordRevealMode(PasswordRevealMode::Hidden)?;",
      "dress_reveal_button(&dressed, &dressing)"], ["PasswordRevealMode::Peek"]),
    ("WinUI: the app's write never emits", WINUI,
     "(NativeWidget::Secure(field), Prop::Revealed, Value::Bool(on)) => {",
     ["door.set_mode(field, mode)?;"], ["send_toggle_tag", "SetPasswordRevealMode"]),
    ("WinUI: the harness's toggle takes the button's Toggle pattern", WINUI, "fn toggle_reveal(",
     ["peer.cast::<IToggleProvider>()?.Toggle()?;"], ["SetPasswordRevealMode", "SetIsChecked"]),
    ("WinUI: the unmasked read is the box's own mode", WINUI, "fn unmasked_len(",
     ["crate::harness::unmasked_count(&shown.to_string())",
      "if field.PasswordRevealMode()? != PasswordRevealMode::Visible {\n"
      "                return Ok(Err(MaskRead::Masked(length)));"], ["secure_reveal", "revealable"]),
    ("WinUI: the masked read refuses a shown box", WINUI, "fn masked_len(",
     ["if field.PasswordRevealMode()? == PasswordRevealMode::Visible {\n"
      "                return Ok(Err(MaskRead::Unmasked("], []),
    ("Compose: the door emits", COMPOSE, "internal fun kayaRevealToggle(",
     ["node.revealed = on\n    KayaPresent.emitToggled(node.tag, on)"], []),
    ("Compose: the eye takes the door and the keyboard's focus", COMPOSE, "private fun KayaSecureField(",
     ["onClick = { kayaRevealToggle(node, !node.revealed) },\n"
      "                            modifier = Modifier.onFocusChanged { state ->",
      "if (state.isFocused) kayaRevealEyeFocused.add(node.id)",
      "contentDescription = kayaRevealName(revealed),", "trailingIcon = eye,"],
     ["emitToggled(node.tag, on)", "canFocus = false"]),
    ("Compose: the harness's toggle presses the eye's own click", COMPOSE, '"toggle" -> {',
     ['kayaRevealPress(activity, parts[1], parts[2] == "on")'], []),
    ("Compose: the press finds the eye inside the field and takes its action", COMPOSE,
     "private fun kayaRevealPress(",
     ["frame.contains(n.boundsInRoot.center)", "eye.config[SemanticsActions.OnClick].action"],
     ["kayaRevealToggle", "revealed ="]),
    ("Compose: the unmasked read is the node info's", COMPOSE, "private fun kayaUnmaskedRead(",
     ['kayaUnmaskedCount(info.text?.toString() ?: "")'], ["textState", "field.text", ".revealed", "kayaTextLayouts"]),
    ("Compose: expect_unmasked reads through it", COMPOSE, '"expect_unmasked" -> {',
     ["kayaUnmaskedRead(activity, parts[1])"], []),
]
# The app's write is configuration (V2): it sets the state and never reaches
# the door, whose callers are the eye alone.
COMPOSE_WRITE = "PROP_REVEALED -> KayaSceneModel.nodes[id]!!.revealed = readBool(b)"

MASKED_SENTENCE = {
    HARNESS: "the platform masks {n} of the revealed secure field's characters",
    SWIFT: "the platform masks \\(masked) of the revealed secure field's characters",
    COMPOSE: "the platform masks $masked of the revealed secure field's characters",
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
    ("the mac field draws kaya's key-view eye", "KayaRevealEye(node: node, revealed: node.revealed)"),
    ("the harness's toggle takes the door",
     'DispatchQueue.main.sync { kayaRevealToggle(revealNode, parts[2] == "on") }'),
    ("the harness's toggle waits for the focus to come back",
     "DispatchQueue.main.sync(execute: { kayaRevealSettled(revealNode) })"),
    ("the app's write swaps without a toggle",
     "case (propRevealed, valueBool):\n                    kayaRevealSwap(kayaScene.nodes[id]!, raw[body + 24] != 0)"),
]
# The mac eye (docs/reveal-plan.md V10, measured 2026-10-08): a SwiftUI Button
# is no key view, so the eye is an NSButton that Tab reaches whatever the
# system's keyboard navigation says, a click that leaves the field's focus, and
# a focus that survives SwiftUI remaking the eye at every swap.
ARMS += [
    ("mac: the eye is in the key view loop and a click leaves the focus", SWIFT,
     "final class KayaRevealEyeButton: NSButton {",
     ["override var canBecomeKeyView: Bool { true }",
      "override var acceptsFirstResponder: Bool { NSApp.currentEvent?.type != .leftMouseDown }",
      "window.makeFirstResponder(self)", "kayaRevealEyeOwed.contains(nodeId)"], ["refusesFirstResponder = true"]),
    ("mac: the eye takes the door and owes a held focus to its successor", SWIFT,
     "struct KayaRevealEye: NSViewRepresentable {",
     ["let button = KayaRevealEyeButton()", "kayaRevealToggle(node, !node.revealed)",
      "$0.window?.firstResponder === $0", "kayaRevealEyeOwed.insert(id)"], []),
    ("mac: expect_focused's eye reads the window's first responder", SWIFT,
     "func kayaRevealEyeHoldsFocus(_ id: UInt64) -> Bool {\n        kayaNSWindows",
     ["($0.firstResponder as? KayaRevealEyeButton)?.nodeId == id"], ["kayaRevealEyeFocused"]),
]
# iOS (measured 2026-10-08, docs/traps.md): the shown field's menu is the masked
# one's, Paste and Select All, it banks no undo, and type_secret's keys reach it
# in-process at its own first responder, since XCTest redacts only what it types
# through a secure element; a masked field's keys stay on that redacted route.
ARMS += [
    ("iOS: the shown field refuses select and keeps no undo stack", SWIFT,
     "final class KayaRevealUITextField: UITextField {", ["override var undoManager: UndoManager? { nil }"],
     ["UIResponderStandardEditActions.select(_:)", "UIResponderStandardEditActions.copy(",
      "UIResponderStandardEditActions.cut("]),
    ("iOS: Writing Tools off on the shown field", SWIFT, "struct KayaRevealedField: UIViewRepresentable {",
     ["if #available(iOS 18.0, *) { view.writingToolsBehavior = .none }"], []),
    ("iOS: a shown field's keys reach its own first responder", SWIFT, "private func kayaTypeIntoRevealed(",
     ["let node = kayaScene.secureFields.first(where: { $0.id == id }), node.revealed",
      "field.isFirstResponder", "(field.delegate as? KayaRevealedField.Coordinator)?.node === node",
      "responder.insertText(String(character))"], ["kayaTypeThroughHost"]),
]
CALLS += [
    ("type_secret asks the shown route first", "kayaTypeIntoRevealed(secret.expose)"),
    ("a masked field's keys stay on XCTest's redacted route",
     'kayaTypeThroughHost(secret.expose, verb: "type_secure_b64")'),
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


def findings(sources, backends=None):
    backends = BACKENDS if backends is None else backends
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
    for label, rel, opener, needs, refused in ARMS:
        body = blocks(sources[rel], opener)
        if len(body) != 1:
            out.append(f"reveal: {rel}'s {opener} is found {len(body)} times, wanted once ({label})")
            continue
        for need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"reveal: {label} no longer holds — {opener}...}} lacks {need.splitlines()[0]}")
        for name in refused:
            if flat(name) in flat(body[0]):
                out.append(f"reveal: {label} no longer holds — {opener}...}} names {name}")
    if COMPOSE_WRITE not in sources[COMPOSE]:
        out.append(f"reveal: {COMPOSE}: the app's `revealed` write no longer sets the state alone "
                   f"({COMPOSE_WRITE})")
    callers = sources[COMPOSE].count("kayaRevealToggle(") - 1
    if callers != 1:
        out.append(f"reveal: {COMPOSE}: kayaRevealToggle is called from {callers} sites, wanted the eye "
                   f"alone, so something other than the user's flip emits toggled")
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in backends:
            out.append(f"reveal: {rel} no longer stubs the reveal and has no row in "
                       f"tools/lib/reveal_routes.py's BACKENDS")
    return out


def run(g):
    rels = [HARNESS, SWIFT, GTK_SECURE, *STUBBED]
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in rels}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("reveal clauses held", len(DOOR) + len(CALLS) + 3 + len(HINTS) + 4 + len(ARMS), floor=54)
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
        ("the iOS field offering Select", SWIFT,
         r"(#selector\(UIResponderStandardEditActions\.paste\(_:\)\),\n)",
         r"\1                #selector(UIResponderStandardEditActions.select(_:)),\n",
         "refuses select and keeps no undo"),
        ("the iOS field keeping an undo stack", SWIFT,
         r"\n        override var undoManager: UndoManager\? \{ nil \}", "",
         "refuses select and keeps no undo"),
        ("Writing Tools left on in the iOS field", SWIFT,
         r"if #available\(iOS 18\.0, \*\) \{ view\.writingToolsBehavior = \.none \}", "",
         "Writing Tools off on the shown field"),
        ("a masked field's keys typed in-process", SWIFT,
         r"(\$0\.id == id \}\)), node\.revealed\n", r"\1\n", "keys reach its own first responder"),
        ("the shown field's keys sent to any field", SWIFT,
         r"field\.isFirstResponder,\n", "true,\n", "keys reach its own first responder"),
        ("type_secret on iOS forgetting the shown route", SWIFT,
         r"kayaTypeIntoRevealed\(secret\.expose\)", "Optional<(typed: Bool, why: String)>.none",
         "asks the shown route first"),
        ("the mac revealed field dropping its hint", SWIFT,
         r"field\.contentType = kayaContentTypes\(\)", "field.toolTip = kayaContentTypes()",
         "no longer carries its content type"),
        ("the masked sentence reworded in Swift", SWIFT,
         r"of the revealed secure field's characters\"\)", "of the field's characters\")",
         "no longer says"),
        ("GTK: the user's flip swallowed as quiet", GTK_SECURE,
         r"(move \|t, _\| \{\n        if )!quiet\.get\(\)", r"\1quiet.get()", "emits outside the quiet guard"),
        ("GTK: a shown password copied", GTK_SECURE, r"\n                t\.stop_signal_emission_by_name\(signal\);", "",
         "copy and cut refused"),
        ("GTK: a shown selection dragged out", GTK_SECURE, r"\n    text\.add_controller\(press\);", "",
         "no drag out"),
        ("GTK: a shown selection offered as PRIMARY", GTK_SECURE, r"if shown \{", "if false {",
         "PRIMARY selection refuses"),
        ("GTK: the PRIMARY refusal never installed", GTK_SECURE,
         r"\(\*class\)\.get_value = Some\(selection_value\);", "", "PRIMARY refusal is installed"),
        ("GTK: the app's write echoing", GTK,
         r"(core\.apply_quiet\.set\(true\);\n                        text\.set_visibility\(on\);\n)"
         r"                        core\.apply_quiet\.set\(false\);",
         r"\1                        core.apply_quiet.set(false); core.occurrences.send_toggle_tag(&[], on);",
         "the app's write is quiet"),
        ("GTK: the peek icon brought back", GTK, r"\n                        eye\.set_visible\(on\);",
         "\n                        field.set_show_peek_icon(on); eye.set_visible(on);", "never the peek icon"),
        ("GTK: the harness's toggle writing the visibility", GTK,
         r"eye\.emit_clicked\(\);", "text.set_visibility(on);", "the eye's own click"),
        ("GTK: the eye out of the tab order", GTK_SECURE, r"(let eye = gtk4::Button::new\(\);)",
         r"\1\n    eye.set_focusable(false);", "the keyboard reaches"),
        ("GTK: the eye's click taking the field's focus", GTK_SECURE, r"\n    eye\.set_focus_on_click\(false\);",
         "", "the keyboard reaches"),
        ("GTK: the eye's focus read off something else", GTK, r"Ok\(widget_focused\(&eye\)\)",
         "Ok(eye.is_visible())", "reads the toolkit's focus"),
        ("WinUI: the reveal button left out of the tab order", WINUI, r"\n    button\.SetIsTabStop\(true\)\?;",
         "", "is a tab stop"),
        ("WinUI: a character at the button reaching the box", WINUI,
         r"\n        button\.CharacterReceived\(", "\n        let _ = (", "types nothing into the box"),
        ("Compose: a key dispatched in-process, in touch mode", COMPOSE,
         r'Log\.i\("kaya", "KAYA_REQUEST: key \$seq \$code"\)', "activity.dispatchKeyEvent(null)",
         "leaves touch mode"),
        ("WinUI: the eye's focus read off something else", WINUI,
         r"FocusState\(\)\? != FocusState::Unfocused\)\)\n", "IsTabStop()?))\n", "reads the button's FocusState"),
        ("mac: the eye no key view", SWIFT, r"\n        override var canBecomeKeyView: Bool \{ true \}", "",
         "in the key view loop"),
        ("mac: a click on the eye taking the field's focus", SWIFT,
         r"override var acceptsFirstResponder: Bool \{ NSApp\.currentEvent\?\.type != \.leftMouseDown \}",
         "override var acceptsFirstResponder: Bool { true }", "in the key view loop"),
        ("mac: the eye's focus lost at the swap", SWIFT, r"\n                kayaRevealEyeOwed\.insert\(id\)", "",
         "owes a held focus"),
        ("mac: the eye's focus read off kaya's own set", SWIFT,
         r"\(\$0\.firstResponder as\? KayaRevealEyeButton\)\?\.nodeId == id",
         "kayaRevealEyeFocused.contains(id)", "first responder"),
        ("mac: the field drawing a SwiftUI Button for its eye", SWIFT,
         r"KayaRevealEye\(node: node, revealed: node\.revealed\)", "EmptyView()", "key-view eye"),
        ("GTK: the unmasked read counting the model", GTK,
         r"Some\(shown\) => crate::harness::unmasked_count\(&shown\)",
         "Some(shown) => crate::harness::unmasked_count(&gtk4::prelude::EditableExt::text(&f))",
         "the unmasked read is the bus's"),
        ("WinUI: the button's flip swallowed", WINUI,
         r"\n                door\.sink\.send_toggle_tag\(&door\.tag, on\);", "", "flip emits"),
        ("WinUI: the flip's trace reading the transport after the send alone", WINUI,
         r"let before = crate::vtrace::on\(\)\.then\(crate::stall::transport\);\n(                door\.sink)",
         r"\1", "both sides of its send"),
        ("WinUI: the secure text's trace dropped", WINUI,
         r'"-> text_changed of \{\} characters for \{\}: \{before\} -> \{\}",', '"",',
         "secure text's trace"),
        ("WinUI: every PasswordChanged sent as an edit", WINUI,
         r"if !edited\.swap\(false, std::sync::atomic::Ordering::Relaxed\) \{", "if false {", "is no edit"),
        ("WinUI: a raise that changed no content marking an edit", WINUI,
         r"\} else if args\.IsContentChanging\(\)\? \{", "} else if true {", "is no edit"),
        ("WinUI: kaya's mode switch taken as an edit", WINUI,
         r"if switching\.load\(std::sync::atomic::Ordering::Relaxed\) \{", "if false {", "is no edit"),
        ("WinUI: the mode switch unmarked", WINUI,
         r"self\.switching\.store\(true, Relaxed\);", "", "marked around the call"),
        ("WinUI: the app's write switching the mode bare", WINUI,
         r"door\.set_mode\(field, mode\)\?;", "field.SetPasswordRevealMode(mode)?;", "never emits"),
        ("WinUI: the app's own write leaving its edit marked", WINUI,
         r"\n                            edited\.store\(false, std::sync::atomic::Ordering::Relaxed\);", "",
         "is no edit"),
        ("an action's trace silent on the answer", HARNESS,
         r'"<- \{why\}: the app has applied \{seen\} -> \{\} transactions; \{\}",', '"<- {why}",',
         "what the app answered"),
        ("WinUI: every Checked taken as the user's flip", WINUI,
         r"if !flip \{\n                    return Ok\(\(\)\);\n                \}\n", "", "agrees with the box's mode"),
        ("WinUI: the box left on Peek", WINUI,
         r"(let field = PasswordBox::new\(\)\?;\n                    field\.SetPasswordRevealMode\(PasswordRevealMode::)Hidden",
         r"\1Peek", "dresses its button"),
        ("WinUI: the app's write echoing", WINUI,
         r"(Prop::Revealed, Value::Bool\(on\)\) => \{\n.*\n.*\n                        door\.set_mode\(field, mode\)\?;)",
         r"\1 core.occurrences.send_toggle_tag(&[], on);", "the app's write never emits"),
        ("WinUI: the harness's toggle setting the mode", WINUI,
         r"peer\.cast::<IToggleProvider>\(\)\?\.Toggle\(\)\?;",
         "field.SetPasswordRevealMode(PasswordRevealMode::Visible)?;", "Toggle pattern"),
        ("WinUI: the unmasked read trusting the length", WINUI,
         r"if field\.PasswordRevealMode\(\)\? != PasswordRevealMode::Visible \{", "if false {",
         "the box's own mode"),
        ("WinUI: the masked read blind to a shown box", WINUI,
         r"if field\.PasswordRevealMode\(\)\? == PasswordRevealMode::Visible \{\n                return Ok\(Err\(MaskRead::Unmasked\(",
         "if false {\n                return Ok(Err(MaskRead::Unmasked(", "refuses a shown box"),
        ("Compose: the eye flipping the state without the door", COMPOSE,
         r"onClick = \{ kayaRevealToggle\(node, !node\.revealed\) \},",
         "onClick = { node.revealed = !node.revealed },", "the eye takes the door"),
        ("Compose: the eye kept out of the tab order", COMPOSE,
         r"(onClick = \{ kayaRevealToggle\(node, !node\.revealed\) \},\n)",
         r"\1                            modifier = Modifier.focusProperties { canFocus = false },\n",
         "the keyboard's focus"),
        ("Compose: the eye's focus unreported", COMPOSE,
         r"if \(state\.isFocused\) kayaRevealEyeFocused\.add\(node\.id\)", "if (false) Unit",
         "the keyboard's focus"),
        ("Compose: the door forgetting to emit", COMPOSE,
         r"(node\.revealed = on\n)    KayaPresent\.emitToggled\(node\.tag, on\)\n", r"\1",
         "the door emits"),
        ("Compose: the app's write echoing", COMPOSE,
         r"PROP_REVEALED -> KayaSceneModel\.nodes\[id\]!!\.revealed = readBool\(b\)",
         "PROP_REVEALED -> kayaRevealToggle(KayaSceneModel.nodes[id]!!, readBool(b))",
         "called from 2 sites"),
        ("Compose: the harness's toggle writing the state", COMPOSE,
         r"(val press = eye\.config\[SemanticsActions\.OnClick\]\.action\n[^\n]*\n\s*)press\(\)",
         r"\1kayaRevealToggle(field, on)", "takes its action"),
        ("Compose: the unmasked read counting the model", COMPOSE,
         r'kayaUnmaskedCount\(info\.text\?\.toString\(\) \?: ""\)',
         "kayaUnmaskedCount(field.textState.text.toString())", "the node info's"),
        ("the masked sentence reworded in Kotlin", COMPOSE,
         r"masks \$masked of the revealed secure field's characters", "masks $masked of the field's characters",
         "no longer says"),
    ]
    for label, rel, pattern, repl, want in cuts:
        broken = g.doctor(f"reveal: {label}", sources[rel], pattern, repl,
                          want=len(re.findall(pattern, sources[rel])) or 1)
        g.negative(f"reveal: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want=want)
    for rel in (GTK, WINUI, COMPOSE):
        g.negative(f"reveal: {BACKENDS[rel]}'s row withheld",
                   lambda rel=rel: findings(sources, {k: v for k, v in BACKENDS.items() if k != rel}),
                   want="has no row")
