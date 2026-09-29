#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# THE SUBMIT GESTURE'S RULES NO SCENE CAN SEE (docs/submit-plan.md S1, S2,
# S3, S4, S6). `submitted` publishes ONLY through the platform's own submit
# door — an entry's or search field's Return, a submitting textarea's Return
# or Send key — never from a text-change path and never from an apply, so a
# programmatic write cannot echo. A textarea's door is dominated by the
# `submits` prop, Shift+Return on a desktop stays the newline, a handled
# Return inserts nothing, and a phone's key says Send. The shared scene
# drives `press return` on every kind and reads the label afterwards, so an
# emit moved onto the text-change path, an emit no longer gated by the prop
# or a Shift arm cut out passes tools/scenes/submit.steps byte for byte:
# the scene never types Shift+Return, never writes the field from the app
# while it is focused, and reads no keyboard's label.
#
# AND THE NUMBER FIELD'S COMMIT, one rule over (docs/number-field-plan.md §3
# rules 1 and 6, §7): value_committed rides Return, focus loss and a step
# and never a keystroke. tools/scenes/numberfield.steps reads the label
# before and after a Return, so it catches a per-keystroke emit only while
# its one "commits: 0" line stands; the doors are held here instead. The
# table grows by itself, check-slider-commit's shape: a backend whose
# depth_stub("numberfield") goes must take a row.

import re

SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

gate = Gate("check-submit")


def block_at(text, start):
    """The brace-balanced block whose `{` is the first after `start`."""
    open_at = text.find("{", start)
    if open_at < 0:
        return ""
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    return ""


def block_after(text, anchor):
    at = text.find(anchor)
    return "" if at < 0 else block_at(text, at)


def blocks_after(text, anchor):
    """Every brace-balanced block that follows an occurrence of `anchor`."""
    out = []
    at = text.find(anchor)
    while at >= 0:
        out.append(block_at(text, at))
        at = text.find(anchor, at + len(anchor))
    return out


def strip_c(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return "\n".join(re.sub(r"//.*", "", ln) for ln in s.split("\n"))


def only_through_doors(rel, source, emit, doors):
    """Every `emit` call in `source` sits inside one of `doors`; a call
    outside them is an emit from a path that is not the gesture's."""
    total = source.count(emit)
    inside = sum(d.count(emit) for d in doors)
    if total == 0:
        return [f"{rel}: nothing calls {emit} — no submit door is wired"]
    if total > inside:
        return [f"{rel}: {emit} is called {total} time(s) and only {inside} sit inside a "
                f"submit door — an emit outside a gesture door is a text-change or an apply "
                f"echoing as a submit (S1, S3)"]
    return []


def swift_findings(source):
    out = []
    src = strip_c(source)
    if not re.search(r"static func emitSubmitted\(_ node: KayaNode, _ text: String\)", src):
        out.append(f"{SWIFT}: KayaHost.emitSubmitted is gone — the one door to the vtable's "
                   f"emit_submitted")
        return out
    emit = "KayaHost.emitSubmitted("
    entry = block_after(src, "struct KayaEntry: View {")
    if ".onSubmit { KayaHost.emitSubmitted(node, node.text) }" not in entry:
        out.append(f"{SWIFT}: KayaEntry has no `.onSubmit` emit — Return on an entry submits "
                   f"nothing, the entry's activate door (S2)")
    search = block_after(src, "struct KayaSearch: View {")
    if search.count(emit) < 2:
        out.append(f"{SWIFT}: KayaSearch must emit from `.onSubmit` on BOTH the mac and the "
                   f"iOS arm ({search.count(emit)} found)")
    mac = block_after(src, "func textView(_ textView: NSTextView, doCommandBy selector: Selector)")
    if not mac:
        out.append(f"{SWIFT}: the mac textarea's doCommandBy arm is gone — Return on a "
                   f"submitting textarea inserts a newline")
    else:
        if "guard let node, node.submits else { return false }" not in mac:
            out.append(f"{SWIFT}: the mac textarea's Return emit is not dominated by submits — "
                       f"a plain textarea would submit (S2)")
        if "#selector(NSResponder.insertNewline(_:))" not in mac or emit not in mac:
            out.append(f"{SWIFT}: the mac textarea's insertNewline: arm no longer emits")
        brk = block_after(mac, "#selector(NSResponder.insertLineBreak(_:))")
        if 'insertText("\\n"' not in brk:
            out.append(f"{SWIFT}: the mac textarea's insertLineBreak: arm no longer inserts the "
                       f"newline — Shift+Return stopped being the newline (S2)")
    ios = block_after(src, "replacementText replacement: String\n            ) -> Bool {")
    if 'if let node, node.submits, replacement == "\\n" {' not in ios:
        out.append(f"{SWIFT}: the iOS textarea's shouldChangeTextIn emit is not dominated by "
                   f"submits and the newline — a plain textarea would submit, or a submitting "
                   f"one on every edit (S2)")
    ios_door = block_after(ios, 'if let node, node.submits, replacement == "\\n" {')
    if emit not in ios_door or "return false" not in ios_door:
        out.append(f"{SWIFT}: the iOS textarea's Send arm must emit and refuse the newline — "
                   f"a handled Return inserts nothing (S2)")
    if src.count("returnKeyType = node.submits ? .send : .default") < 1 \
            or "let key: UIReturnKeyType = node.submits ? .send : .default" not in src:
        out.append(f"{SWIFT}: the iOS textarea's key is not keyed on submits — a submitting "
                   f"textarea's phone key must say Send, at creation and on update (S4)")
    doors = blocks_after(src, ".onSubmit {") + [mac, ios_door]
    out.extend(only_through_doors(SWIFT, src, emit, doors))
    return out


def gtk_findings(source):
    out = []
    src = strip_c(source)
    emit = "send_submitted_tag("
    entry = block_after(src, "WidgetKind::Entry => {")
    entry_door = block_after(entry, "entry.connect_activate(")
    if emit not in entry_door:
        out.append(f"{GTK}: the entry arm's `activate` does not emit — Return on an entry "
                   f"submits nothing, the entry's activate door (S2)")
    search = block_after(src, "WidgetKind::Search => {")
    search_door = block_after(search, "search.connect_activate(")
    if emit not in search_door:
        out.append(f"{GTK}: the search arm's `activate` does not emit (S2)")
    area = block_after(src, "WidgetKind::Textarea => {")
    if "keys.set_propagation_phase(gtk4::PropagationPhase::Capture);" not in area:
        out.append(f"{GTK}: the textarea's key controller is not in the capture phase — the "
                   f"view's own Return inserts the newline before the controller sees it (S2)")
    key = block_after(area, "keys.connect_key_pressed(")
    if not key:
        out.append(f"{GTK}: the textarea arm has no key controller — Return never submits")
    else:
        if "!submits.borrow().contains(&wid)" not in key:
            out.append(f"{GTK}: the textarea's Return emit is not dominated by submits — a plain "
                       f"textarea would submit (S2)")
        shift = block_after(key, "SHIFT_MASK")
        if 'insert_at_cursor("\\n")' not in shift:
            out.append(f"{GTK}: the textarea's Shift arm no longer inserts the newline — "
                       f"Shift+Return stopped being the newline (S2)")
        if emit not in key or "glib::Propagation::Stop" not in key:
            out.append(f"{GTK}: the textarea's Return must emit and stop the event — a handled "
                       f"Return inserts nothing (S2)")
    if "(NativeWidget::Textarea(..), Prop::Submits, Value::Bool(on)) => {" not in src:
        out.append(f"{GTK}: no Prop::Submits apply arm — the set the key controller reads is "
                   f"never written")
    out.extend(only_through_doors(GTK, src, emit, [entry_door, search_door, key]))
    return out


def winui_findings(source):
    out = []
    src = strip_c(source)
    emit = "send_submitted_tag("
    door = block_after(src, "\nfn submit_on_enter(")
    if not door:
        out.append(f"{WINUI}: submit_on_enter is gone — the one KeyDown door every text kind "
                   f"shares")
        return out
    if "VirtualKey::Enter" not in door:
        out.append(f"{WINUI}: submit_on_enter no longer keys on VirtualKey::Enter")
    if "element.PreviewKeyDown(" not in door:
        out.append(f"{WINUI}: submit_on_enter is not on the tunnelling PreviewKeyDown — a "
                   f"TextBox with AcceptsReturn handles Enter itself before the bubbling KeyDown, "
                   f"which then never fires (§7.4), so a submitting textarea inserts its newline")
    if "SUBMITS.with_borrow(|set| set.contains(&id))" not in door:
        out.append(f"{WINUI}: the gated (textarea) branch is not dominated by submits — a plain "
                   f"textarea would submit (S2)")
    if "modifier_down(VK_SHIFT)" not in door:
        out.append(f"{WINUI}: the gated branch no longer reads Shift — Shift+Enter stopped "
                   f"being the newline (S2)")
    if not re.search(r"send_submitted_tag\(&tag, &text\);\s*args\.SetHandled\(true\)\?;", door):
        out.append(f"{WINUI}: the emit is not followed by SetHandled(true) — a handled Enter "
                   f"inserts nothing, and this one inserts (S2)")
    calls = re.findall(r"submit_on_enter\(Editable::(Entry|Textarea)\(field\.clone\(\)\), "
                       r"tag\.clone\(\), core\.occurrences\.clone\(\), (None|Some\(id\.0\))\)",
                       src)
    if calls.count(("Entry", "None")) != 2:
        out.append(f"{WINUI}: the entry and search arms must each wire submit_on_enter ungated "
                   f"({calls.count(('Entry', 'None'))} of 2 found)")
    if ("Textarea", "Some(id.0)") not in calls:
        out.append(f"{WINUI}: the textarea arm must wire submit_on_enter GATED on its own id "
                   f"(Some(id.0)) — ungated, a plain textarea submits (S2)")
    if "(NativeWidget::Textarea(_), Prop::Submits, Value::Bool(on)) => {" not in src:
        out.append(f"{WINUI}: no Prop::Submits apply arm — SUBMITS is never written")
    out.extend(only_through_doors(WINUI, src, emit, [door]))
    return out


def compose_findings(source):
    out = []
    src = strip_c(source)
    emit = "KayaPresent.emitSubmitted("
    field = block_after(src, "\nfun KayaTextField(")
    if not field:
        out.append(f"{COMPOSE}: KayaTextField is gone — the arm this gate reads")
        return out
    if not re.search(r"else if \(!singleLine && node\.submits\) \{\s*"
                     r"KeyboardOptions\(imeAction = ImeAction\.Send\)", field):
        out.append(f"{COMPOSE}: a submitting textarea's keyboard action is not Send — the "
                   f"phone key must say Send (S4)")
    action = block_after(field, "onKeyboardAction = {")
    if not action:
        out.append(f"{COMPOSE}: KayaTextField has no onKeyboardAction — the keyboard's key "
                   f"submits nothing")
    else:
        single = block_after(action, "if (singleLine)")
        if emit not in single or "performDefaultAction()" not in single:
            out.append(f"{COMPOSE}: a single-line field's action must emit and then do the "
                       f"platform's default (S2, S4's search dismissal)")
        gated = block_after(action, "else if (node.submits)")
        if emit not in gated:
            out.append(f"{COMPOSE}: the textarea's Send emit is not dominated by submits (S2)")
        if "performDefaultAction()" in gated:
            out.append(f"{COMPOSE}: a submitting textarea's Send also performs the default "
                       f"action — a handled Send inserts nothing, and this one inserts (S2)")
    preview = ""
    for cand in blocks_after(field, ".onPreviewKeyEvent { event ->"):
        if "Key.Enter" in cand:
            preview = cand
    if not preview:
        out.append(f"{COMPOSE}: no onPreviewKeyEvent arm reads Enter — a hardware Return on a "
                   f"submitting textarea inserts a newline")
    else:
        if "(node.submits && !event.isShiftPressed)" not in preview:
            out.append(f"{COMPOSE}: the textarea's hardware Return emit is not dominated by "
                       f"submits and Shift — a plain textarea would submit, or Shift+Return "
                       f"stopped being the newline (S2)")
        if "(singleLine || (node.submits" not in preview:
            out.append(f"{COMPOSE}: a single-line field's hardware Return no longer publishes — "
                       f"a key event never reaches onKeyboardAction (§7.3), so Return in an "
                       f"entry submits nothing")
        if emit not in preview:
            out.append(f"{COMPOSE}: the hardware Return arm does not emit")
    if not re.search(r"PROP_SUBMITS ->\s*KayaSceneModel\.nodes\[id\]!!\.submits = readBool\(b\)",
                     src):
        out.append(f"{COMPOSE}: no PROP_SUBMITS apply arm — node.submits is never written")
    out.extend(only_through_doors(COMPOSE, src, emit, [action, preview]))
    return out


ROWS = {SWIFT: swift_findings, GTK: gtk_findings, WINUI: winui_findings,
        COMPOSE: compose_findings}


def calls_only_inside(rel, source, call, blocks, where):
    """Every `call` in `source` other than its own definition sits inside
    one of `blocks`; `where` names the doors for the sentence."""
    total = source.count(call) - source.count("func " + call)
    inside = sum(b.count(call) for b in blocks)
    if total == 0:
        return [f"{rel}: nothing calls {call} — the number field's {where} is not wired"]
    if total > inside:
        return [f"{rel}: {call} is called {total} time(s) and only {inside} sit inside "
                f"{where} — a commit from any other path is a keystroke or an apply "
                f"committing (docs/number-field-plan.md §3)"]
    return []


def swift_number_findings(source):
    out = []
    src = strip_c(source)
    field = block_after(src, "struct KayaNumberField: View {")
    if not field:
        return [f"{SWIFT}: no KayaNumberField — the arm this clause holds is gone"]
    commit = block_after(src, "func kayaNumberCommit(_ node: KayaNode) {")
    step = block_after(src, "func kayaNumberStep(_ node: KayaNode, _ steps: Int32) {")
    settle = block_after(src, "func kayaNumberSettle(")
    setter = block_after(field, "set: { newValue in")
    for bad in ("kayaNumberCommit(", "kayaNumberStep(", "KayaHost.emit"):
        if bad in setter:
            out.append(f"{SWIFT}: the number field's text binding calls {bad} — a keystroke "
                       f"commits (§3 rule 1)")
    submit = block_after(field, ".onSubmit {")
    if "kayaNumberCommit(node)" not in submit:
        out.append(f"{SWIFT}: the number field's `.onSubmit` does not commit — Return commits "
                   f"nothing (§3 rule 1)")
    lost = block_after(field, "if wasFocused && !newValue {")
    if "kayaNumberCommit(node)" not in lost:
        out.append(f"{SWIFT}: the number field's focus loss does not commit (§3 rule 1)")
    keys = blocks_after(field, ".onKeyPress(")
    stepping = sum(k.count("kayaNumberStep(node, ") for k in keys)
    if stepping != 4:
        out.append(f"{SWIFT}: the number field steps from {stepping} "
                   f"key arm(s), not the four (arrows by one, page keys by ten; §3 rule 6)")
    out.extend(calls_only_inside(SWIFT, src, "kayaNumberCommit(", [submit, lost],
                                 "its Return and focus-loss doors"))
    out.extend(calls_only_inside(SWIFT, src, "kayaNumberStep(", keys, "its key doors"))
    out.extend(calls_only_inside(SWIFT, src, "kayaNumberSettle(", [commit, step],
                                 "the commit and step paths"))
    moved = block_after(settle, "if answer == 2 {")
    if settle.count("KayaHost.emit") != 1 or "KayaHost.emitValueCommitted(" not in moved:
        out.append(f"{SWIFT}: kayaNumberSettle must emit value_committed once, and only when "
                   f"the core answers a moved value — an unchanged commit fires nothing (§2)")
    for name, body in (("KayaNumberField", field), ("kayaNumberCommit", commit),
                       ("kayaNumberStep", step)):
        if "KayaHost.emit" in body:
            out.append(f"{SWIFT}: {name} emits for itself — the one emit is kayaNumberSettle's")
    return out


def gtk_number_findings(source):
    """GTK's spin button reads its text on activate, on focus-out and before
    every step (gtk_spin_button_update), and reports each through ONE
    `value-changed`; kaya's one emit sits behind that signal, outside the
    quiet guard, and only for a value the core's rule moved."""
    out = []
    src = strip_c(source)
    arm = block_after(src, "WidgetKind::NumberField => {")
    if not arm:
        return [f"{GTK}: no WidgetKind::NumberField create arm — the arm this clause holds "
                f"is gone"]
    committed = block_after(src, "fn number_committed(")
    door = block_after(arm, "spin.connect_value_changed(move |sb| {")
    keystroke = block_after(arm, "EditableExt::connect_changed(&spin, move |_| {")
    reads = block_after(arm, "spin.connect_input(move |sb| {")
    if "SpinButtonUpdatePolicy::Always" not in arm:
        out.append(f"{GTK}: the spin button's update policy is not ALWAYS — out-of-range text "
                   f"reverts instead of clamping (§3 rule 3)")
    if not re.match(r"\{\s*if quiet\.get\(\) \{\s*return;\s*\}", door):
        out.append(f"{GTK}: the number field's value-changed door does not open on the quiet "
                   f"guard — an app write echoes as a commit (§2)")
    for bad in ("number_committed(", "send_value_committed_tag(", ".update("):
        if bad in keystroke:
            out.append(f"{GTK}: the number field's `changed` handler calls {bad} — a "
                       f"keystroke commits (§3 rule 1)")
    if "spin.remove_controller(controller);" not in arm:
        out.append(f"{GTK}: GTK's own focus-out door is left on the spin button — it commits "
                   f"whenever the WINDOW loses the keyboard, which a wayland virtual keyboard "
                   f"does on every keystroke burst (§4.5)")
    leave = block_after(arm, "focus_door.connect_leave(move |_| {")
    if "if !inside {" not in leave or "spin.update();" not in block_after(leave, "if !inside {"):
        out.append(f"{GTK}: the number field's focus door does not commit once the window's "
                   f"focus sits elsewhere — Tab away commits nothing (§3 rule 1)")
    if "crate::number_field::commit(" not in reads:
        out.append(f"{GTK}: the spin button's `input` handler does not read the text through "
                   f"number_field::commit — the platform's parse decides the value (§3 rule 5)")
    if "send_value_committed_tag(" in arm:
        out.append(f"{GTK}: the number field's create arm emits for itself — the one emit is "
                   f"number_committed's")
    calls = src.count("number_committed(") - src.count("fn number_committed(")
    inside = door.count("number_committed(")
    if calls == 0:
        out.append(f"{GTK}: nothing calls number_committed — the number field's value-changed "
                   f"door is not wired")
    elif calls > inside:
        out.append(f"{GTK}: number_committed is called {calls} time(s) and only {inside} sit "
                   f"inside the spin button's value-changed door — a commit from any other "
                   f"path is a keystroke or an apply committing (docs/number-field-plan.md §3)")
    moved = block_after(committed, "if let Commit::Moved(")
    if committed.count("send_value_committed_tag(") != 1 or \
            "send_value_committed_tag(" not in moved:
        out.append(f"{GTK}: number_committed must emit value_committed once, and only when the "
                   f"core's rule moved the value — an unchanged commit fires nothing (§2)")
    return out


def compose_number_findings(source):
    """Compose has no number control: a text field whose commit doors are
    the keyboard's action (Done), a hardware Return in the preview key arm
    and the focus leaving it; ONE settle emits, and only for a value the
    core's rule moved."""
    out = []
    src = strip_c(source)
    field = block_after(src, "\nprivate fun KayaNumberField(")
    if not field:
        return [f"{COMPOSE}: no KayaNumberField — the arm this clause holds is gone"]
    commit = block_after(src, "\ninternal fun kayaNumberCommit(")
    settle = block_after(src, "\nprivate fun kayaNumberSettle(")
    action = block_after(field, "onKeyboardAction = {")
    preview = ""
    for cand in blocks_after(field, ".onPreviewKeyEvent { event ->"):
        if "Key.Enter" in cand:
            preview = cand
    lost = block_after(field, "if (wasFocused && !state.isFocused) {")
    keystroke = block_after(field, ".collect {")
    for bad in ("kayaNumberCommit(", "kayaNumberSettle(", "KayaPresent.emit"):
        if bad in keystroke:
            out.append(f"{COMPOSE}: the number field's text collector calls {bad} — a "
                       f"keystroke commits (§3 rule 1)")
    if "kayaNumberCommit(node)" not in action:
        out.append(f"{COMPOSE}: the number field's keyboard action does not commit — the "
                   f"phone's Done commits nothing (§3 rule 1)")
    if "kayaNumberCommit(node)" not in preview:
        out.append(f"{COMPOSE}: the number field's hardware Return does not commit — a key "
                   f"event never reaches onKeyboardAction (§3 rule 1)")
    if "kayaNumberCommit(node)" not in lost:
        out.append(f"{COMPOSE}: the number field's focus loss does not commit (§3 rule 1)")
    calls = src.count("kayaNumberCommit(") - src.count("fun kayaNumberCommit(")
    inside = sum(b.count("kayaNumberCommit(") for b in (action, preview, lost))
    if calls > inside:
        out.append(f"{COMPOSE}: kayaNumberCommit( is called {calls} time(s) and only {inside} "
                   f"sit inside its Done, Return and focus-loss doors — a commit from any "
                   f"other path is a keystroke or an apply committing "
                   f"(docs/number-field-plan.md §3)")
    settles = src.count("kayaNumberSettle(") - src.count("fun kayaNumberSettle(")
    if settles != commit.count("kayaNumberSettle("):
        out.append(f"{COMPOSE}: kayaNumberSettle is reached from outside the commit path")
    moved = block_after(settle, "if (answer == 2) {")
    if settle.count("KayaPresent.emit") != 1 or \
            "KayaPresent.emitValueCommitted(" not in moved:
        out.append(f"{COMPOSE}: kayaNumberSettle must emit value_committed once, and only when "
                   f"the core answers a moved value — an unchanged commit fires nothing (§2)")
    for name, body in (("KayaNumberField", field), ("kayaNumberCommit", commit)):
        if "KayaPresent.emit" in body:
            out.append(f"{COMPOSE}: {name} emits for itself — the one emit is "
                       f"kayaNumberSettle's")
    return out


def winui_number_findings(source):
    """NumberBox reads its text at Enter, focus loss and before every step,
    through the NumberFormatter it is given, and reports each through ONE
    ValueChanged; kaya's formatter is that reader, and kaya's one emit sits
    behind that event, outside the quiet guard, only for a value the core's
    rule moved."""
    out = []
    src = strip_c(source)
    arm = block_after(src, "WidgetKind::NumberField => {")
    if not arm:
        return [f"{WINUI}: no WidgetKind::NumberField create arm — the arm this clause holds "
                f"is gone"]
    door = block_after(arm, "move |sender, args| {")
    shape = block_after(src, "fn winui_number_shape(")
    settle = block_after(src, "fn winui_number_settle(")
    reader = block_after(src, "fn read(text: &HSTRING) -> Option<f64> {")
    if "NumberBoxValidationMode::InvalidInputOverwritten" not in arm:
        out.append(f"{WINUI}: the NumberBox does not overwrite invalid input — unreadable text "
                   f"stays in the box (§3 rule 2)")
    if "field.ValueChanged(&handler)" not in arm or not door:
        out.append(f"{WINUI}: the NumberBox's ValueChanged is not the number field's door — "
                   f"Return, focus loss and a step commit nothing (§3 rules 1, 6)")
    if not re.match(r"\{\s*if quiet\.load\([^)]*\) \{\s*return Ok\(\(\)\);\s*\}", door):
        out.append(f"{WINUI}: the number field's ValueChanged door does not open on the quiet "
                   f"guard — an app write echoes as a commit (§2)")
    if "SetNumberFormatter(" not in shape or "KayaNumberText {" not in shape:
        out.append(f"{WINUI}: the NumberBox is not given kaya's own formatter — its text is the "
                   f"platform's parse and display (§3 rule 5)")
    if "crate::fmt::parse_number(" not in reader:
        out.append(f"{WINUI}: KayaNumberText reads the text for itself, not through "
                   f"fmt::parse_number — the platform's parse decides the value (§3 rule 5)")
    if "send_value_committed_tag(" in arm:
        out.append(f"{WINUI}: the number field's create arm emits for itself — the one emit is "
                   f"winui_number_settle's")
    calls = src.count("winui_number_settle(") - src.count("fn winui_number_settle(")
    inside = door.count("winui_number_settle(")
    if calls == 0:
        out.append(f"{WINUI}: nothing calls winui_number_settle — the number field's "
                   f"ValueChanged door is not wired")
    elif calls > inside:
        out.append(f"{WINUI}: winui_number_settle is called {calls} time(s) and only {inside} "
                   f"sit inside the NumberBox's ValueChanged door — a commit from any other "
                   f"path is a keystroke or an apply committing (docs/number-field-plan.md §3)")
    moved = block_after(settle, "if let Commit::Moved(v) = answer {")
    if settle.count("send_value_committed_tag(") != 1 or \
            "send_value_committed_tag(" not in moved:
        out.append(f"{WINUI}: winui_number_settle must emit value_committed once, and only when "
                   f"the core's rule moved the value — an unchanged commit fires nothing (§2)")
    return out


# The number field's rows; a backend with no row must still stub the kind.
NUMBER_ROWS = {SWIFT: swift_number_findings, GTK: gtk_number_findings,
               WINUI: winui_number_findings, COMPOSE: compose_number_findings}
STUBS = {GTK: 'depth_stub("numberfield")', WINUI: 'depth_stub("numberfield")',
         COMPOSE: 'depthStub("numberfield")'}


def census(texts, number_rows=None):
    number_rows = NUMBER_ROWS if number_rows is None else number_rows
    out = []
    for rel, row in ROWS.items():
        out.extend(row(texts[rel]))
    for rel, row in number_rows.items():
        out.extend(row(texts[rel]))
    for rel, stub in STUBS.items():
        if rel not in number_rows and stub not in texts[rel]:
            out.append(f"{rel}: the number field's arm has landed (no {stub} left) and this "
                       f"gate has no row for its commit doors — add one naming the backend's "
                       f"own Return, focus-loss and step events (docs/number-field-plan.md §6)")
    return out


REAL = {rel: gate.read(rel) for rel in ROWS}


def watched(label, texts, want):
    gate.negative(label, lambda: census(texts), want=want)


# SWIFT
n1 = gate.doctor("the KayaEntry onSubmit cut out", REAL[SWIFT],
                 r"(\.focused\(\$focused\)\n(?:\s*//[^\n]*\n)*)\s*\.onSubmit \{ "
                 r"KayaHost\.emitSubmitted\(node, node\.text\) \}\n(\s*\.onAppear \{ focused = )",
                 r"\1\2")
watched("a SwiftUI entry whose Return submits nothing", {**REAL, SWIFT: n1},
        "KayaEntry has no `.onSubmit` emit")
n2 = gate.doctor("an emit planted on the text-change path", REAL[SWIFT],
                 r"(static func emitText\(_ node: KayaNode, _ text: String\) \{\n)",
                 r"\1        KayaHost.emitSubmitted(node, text)\n")
watched("a SwiftUI text change echoing as a submit", {**REAL, SWIFT: n2},
        "outside a gesture door")
n3 = gate.doctor("the mac doCommandBy submits guard cut", REAL[SWIFT],
                 r"guard let node, node\.submits else \{ return false \}\n"
                 r"(\s*if selector == #selector\(NSResponder\.insertNewline)",
                 r"guard let node else { return false }\n\1")
watched("a SwiftUI mac textarea submitting whether or not it asked to", {**REAL, SWIFT: n3},
        "mac textarea's Return emit is not dominated by submits")
n4 = gate.doctor("the mac insertLineBreak arm cut", REAL[SWIFT],
                 r"if selector == #selector\(NSResponder\.insertLineBreak\(_:\)\) \{\n"
                 r'\s*textView\.insertText\("\\n", replacementRange: '
                 r"textView\.selectedRange\(\)\)\n\s*return true\n\s*\}\n", "")
watched("a SwiftUI mac textarea whose Shift+Return is no newline", {**REAL, SWIFT: n4},
        "Shift+Return stopped being the newline")
n5 = gate.doctor("the iOS returnKeyType no longer keyed on submits", REAL[SWIFT],
                 r"view\.returnKeyType = node\.submits \? \.send : \.default",
                 "view.returnKeyType = .default")
watched("an iOS textarea whose phone key never says Send", {**REAL, SWIFT: n5},
        "phone key must say Send")
n6 = gate.doctor("the iOS shouldChangeTextIn submits guard cut", REAL[SWIFT],
                 r'if let node, node\.submits, replacement == "\\n" \{',
                 'if let node, replacement == "\\n" {')
watched("an iOS textarea submitting whether or not it asked to", {**REAL, SWIFT: n6},
        "shouldChangeTextIn emit is not dominated by submits")

# GTK
n7 = gate.doctor("the gtk entry activate emit cut", REAL[GTK],
                 r"entry\.connect_activate\(move \|e\| \{\n\s*submit_sink\.send_submitted_tag\("
                 r"&submit_tag, &lf\(e\.text\(\)\.to_string\(\)\)\);\n\s*\}\);",
                 "let _ = (submit_sink, submit_tag);")
watched("a GTK entry whose Return submits nothing", {**REAL, GTK: n7},
        "the entry arm's `activate` does not emit")
n8 = gate.doctor("the gtk textarea submits gate cut", REAL[GTK],
                 r"if !is_return \|\| !submits\.borrow\(\)\.contains\(&wid\) \{",
                 "if !is_return {")
watched("a GTK textarea submitting whether or not it asked to", {**REAL, GTK: n8},
        "textarea's Return emit is not dominated by submits")
n9 = gate.doctor("the gtk Shift arm cut", REAL[GTK],
                 r"if state\.contains\(gtk4::gdk::ModifierType::SHIFT_MASK\) \{\n"
                 r'\s*submit_buffer\.insert_at_cursor\("\\n"\);\n'
                 r"\s*return glib::Propagation::Stop;\n\s*\}\n", "")
watched("a GTK textarea whose Shift+Return is no newline", {**REAL, GTK: n9},
        "Shift+Return stopped being the newline")
n10 = gate.doctor("the gtk key controller moved to the bubble phase", REAL[GTK],
                  r"keys\.set_propagation_phase\(gtk4::PropagationPhase::Capture\);",
                  "keys.set_propagation_phase(gtk4::PropagationPhase::Bubble);")
watched("a GTK textarea whose controller sees Return after the view", {**REAL, GTK: n10},
        "not in the capture phase")
n11 = gate.doctor("an emit planted in the entry's changed handler", REAL[GTK],
                  r"(entry\.connect_changed\(move \|e\| \{\n)",
                  r'\1sink.send_submitted_tag(&tag, "");\n')
watched("a GTK text change echoing as a submit", {**REAL, GTK: n11},
        "outside a gesture door")

# WINUI
n12 = gate.doctor("the winui SUBMITS gate cut", REAL[WINUI],
                  r"if !SUBMITS\.with_borrow\(\|set\| set\.contains\(&id\)\) \|\| "
                  r"modifier_down\(VK_SHIFT\) \{",
                  "if modifier_down(VK_SHIFT) {")
watched("a WinUI textarea submitting whether or not it asked to", {**REAL, WINUI: n12},
        "not dominated by submits")
n13 = gate.doctor("the winui Shift read cut", REAL[WINUI],
                  r"if !SUBMITS\.with_borrow\(\|set\| set\.contains\(&id\)\) \|\| "
                  r"modifier_down\(VK_SHIFT\) \{",
                  "if !SUBMITS.with_borrow(|set| set.contains(&id)) {")
watched("a WinUI textarea whose Shift+Enter is no newline", {**REAL, WINUI: n13},
        "Shift+Enter stopped being the newline")
n14 = gate.doctor("the winui textarea wired ungated", REAL[WINUI],
                  r"submit_on_enter\(Editable::Textarea\(field\.clone\(\)\), tag\.clone\(\), "
                  r"core\.occurrences\.clone\(\), Some\(id\.0\)\)",
                  "submit_on_enter(Editable::Textarea(field.clone()), tag.clone(), "
                  "core.occurrences.clone(), None)")
watched("a WinUI textarea arm that submits without asking the prop", {**REAL, WINUI: n14},
        "GATED on its own id")
n15 = gate.doctor("the winui SetHandled cut", REAL[WINUI],
                  r"(sink\.send_submitted_tag\(&tag, &text\);)\n\s*args\.SetHandled\(true\)\?;",
                  r"\1")
watched("a WinUI Enter that submits and still inserts", {**REAL, WINUI: n15},
        "this one inserts")
n16 = gate.doctor("an emit planted outside submit_on_enter", REAL[WINUI],
                  r"\nfn submit_on_enter\(",
                  '\nfn kaya_planted(sink: OccSink, tag: Vec<u8>) '
                  '{ sink.send_submitted_tag(&tag, ""); }'
                  "\nfn submit_on_enter(")
watched("a WinUI emit from a path that is not the KeyDown door", {**REAL, WINUI: n16},
        "outside a gesture door")

# COMPOSE
n17 = gate.doctor("the compose Send action cut", REAL[COMPOSE],
                  r"\} else if \(!singleLine && node\.submits\) \{\n\s*"
                  r"KeyboardOptions\(imeAction = ImeAction\.Send\)\n\s*\} else \{",
                  "} else {")
watched("a Compose textarea whose phone key never says Send", {**REAL, COMPOSE: n17},
        "phone key must say Send")
n18 = gate.doctor("the compose Shift read cut", REAL[COMPOSE],
                  r"\(singleLine \|\| \(node\.submits && !event\.isShiftPressed\)\)",
                  "(singleLine || node.submits)")
watched("a Compose textarea whose Shift+Return is no newline", {**REAL, COMPOSE: n18},
        "Shift+Return stopped being the newline")
n19 = gate.doctor("the compose hardware Return submits guard cut", REAL[COMPOSE],
                  r"\(singleLine \|\| \(node\.submits && !event\.isShiftPressed\)\)",
                  "(singleLine || !event.isShiftPressed)")
watched("a Compose textarea submitting whether or not it asked to", {**REAL, COMPOSE: n19},
        "not dominated by submits and Shift")
n22 = gate.doctor("the compose single-line Return arm cut", REAL[COMPOSE],
                  r"\(singleLine \|\| \(node\.submits && !event\.isShiftPressed\)\)",
                  "(node.submits && !event.isShiftPressed)")
watched("a Compose entry whose hardware Return submits nothing", {**REAL, COMPOSE: n22},
        "single-line field's hardware Return no longer publishes")
n23 = gate.doctor("the winui door moved back to the bubbling KeyDown", REAL[WINUI],
                  r"element\.PreviewKeyDown\(&KeyEventHandler::new\(",
                  "element.KeyDown(&KeyEventHandler::new(")
watched("a WinUI textarea whose Enter the TextBox handles first", {**REAL, WINUI: n23},
        "tunnelling PreviewKeyDown")
n20 = gate.doctor("the compose Send branch performing the default too", REAL[COMPOSE],
                  r"(\} else if \(node\.submits\) \{\n\s*KayaPresent\.emitSubmitted\("
                  r"node\.tag, kayaLf\(node\.textState\.text\.toString\(\)\)\)\n)",
                  r"\1performDefaultAction()\n")
watched("a Compose Send that submits and still inserts", {**REAL, COMPOSE: n20},
        "this one inserts")
n21 = gate.doctor("an emit planted on the apply arm", REAL[COMPOSE],
                  r"(PROP_SUBMITS ->\n\s*KayaSceneModel\.nodes\[id\]!!\.submits = readBool\(b\))",
                  r'\1.also { KayaPresent.emitSubmitted(KayaSceneModel.nodes[id]!!.tag, "") }')
watched("a Compose apply echoing as a submit", {**REAL, COMPOSE: n21},
        "outside a gesture door")

# THE NUMBER FIELD
n24 = gate.doctor("a commit planted on the number field's text binding", REAL[SWIFT],
                  r"(set: \{ newValue in\n\s*if newValue == node\.text \{ return \}\n)",
                  r"\1                    kayaNumberCommit(node)\n")
watched("a SwiftUI number field committing per keystroke", {**REAL, SWIFT: n24},
        "a keystroke commits")
n25 = gate.doctor("the number field's onSubmit cut out", REAL[SWIFT],
                  r"\n\s*\.onSubmit \{ kayaNumberCommit\(node\) \}", "")
watched("a SwiftUI number field whose Return commits nothing", {**REAL, SWIFT: n25},
        "Return commits nothing")
n26 = gate.doctor("the number field's focus-loss commit cut", REAL[SWIFT],
                  r"if wasFocused && !newValue \{\n\s*kayaNumberCommit\(node\)\n",
                  "if wasFocused && !newValue {\n")
watched("a SwiftUI number field whose focus loss commits nothing", {**REAL, SWIFT: n26},
        "focus loss does not commit")
n27 = gate.doctor("settle emitting whether or not the value moved", REAL[SWIFT],
                  r"(\n\s*kayaUserWrite \{ node\.text = "
                  r"kayaNumberText\(node\.value, node\.step\) \})",
                  r"\n    KayaHost.emitValueCommitted(node.tag, node.value)\1")
watched("a SwiftUI number field firing on an unchanged commit", {**REAL, SWIFT: n27},
        "an unchanged commit fires nothing")
n28 = gate.doctor("the harness's unfocus committing past the door", REAL[SWIFT],
                  r'(case "unfocus", "nudge":\n)',
                  r"\1                DispatchQueue.main.sync { "
                  r"kayaNumberCommit(kayaScene.numberFields[0]) }\n")
watched("a verb that commits without the user's door", {**REAL, SWIFT: n28},
        "kayaNumberCommit( is called")
withheld = {rel: row for rel, row in NUMBER_ROWS.items() if rel != GTK}
print(f"check-submit: self-test the GTK number row withheld, "
      f"{len(NUMBER_ROWS) - len(withheld)} row(s) out of the table")
gate.negative("a GTK number field arm with no row in this gate",
              lambda: census(REAL, withheld), want="has no row for its commit doors")
n30 = gate.doctor("a commit planted on the spin button's changed handler", REAL[GTK],
                  r"(EditableExt::connect_changed\(&spin, move \|_\| \{\n)",
                  r"\1number_committed(&field, &quiet, &sink, &tag, 0.0);\n")
watched("a GTK number field committing per keystroke", {**REAL, GTK: n30},
        "a keystroke commits")
n31 = gate.doctor("the value-changed door's quiet guard cut", REAL[GTK],
                  r"(spin\.connect_value_changed\(move \|sb\| \{\n)\s*if quiet\.get\(\) \{\n"
                  r"\s*return;\n\s*\}\n",
                  r"\1")
watched("a GTK number field whose app write echoes", {**REAL, GTK: n31},
        "an app write echoes")
n32 = gate.doctor("number_committed emitting whether or not the value moved", REAL[GTK],
                  r"(\n\s*if let Commit::Moved\(moved\) = settled \{)",
                  r"\n    sink.send_value_committed_tag(tag, shown);\1")
watched("a GTK number field firing on an unchanged commit", {**REAL, GTK: n32},
        "an unchanged commit fires nothing")
n33 = gate.doctor("the input handler reading the text for itself", REAL[GTK],
                  r"Some\(Ok\(match crate::number_field::commit\(",
                  "Some(Ok(match own_parse(")
watched("a GTK number field whose parse is the platform's", {**REAL, GTK: n33},
        "the platform's parse decides")
n34 = gate.doctor("the value-changed door cut", REAL[GTK],
                  r"number_committed\(&committed, &quiet, &sink, &tag, sb\.value\(\)\);",
                  "let _ = sb;")
watched("a GTK number field whose steps and Return commit nothing", {**REAL, GTK: n34},
        "nothing calls number_committed")

# COMPOSE
n35 = gate.doctor("a commit planted in the number field's text collector", REAL[COMPOSE],
                  r"(snapshotFlow \{ node\.textState\.text\.toString\(\) \}\.collect \{ )"
                  r"node\.text = it \}",
                  r"\1node.text = it; kayaNumberCommit(node) }")
watched("a Compose number field committing per keystroke", {**REAL, COMPOSE: n35},
        "a keystroke commits")
n36 = gate.doctor("the number field's keyboard-action commit cut", REAL[COMPOSE],
                  r"(onKeyboardAction = \{ performDefaultAction ->\n)\s*kayaNumberCommit\(node\)\n",
                  r"\1")
watched("a Compose number field whose Done commits nothing", {**REAL, COMPOSE: n36},
        "Done commits nothing")
n37 = gate.doctor("the number field's hardware Return commit cut", REAL[COMPOSE],
                  r"(\(event\.key == Key\.Enter \|\| event\.key == Key\.NumPadEnter\)\n"
                  r"\s*\) \{\n)\s*kayaNumberCommit\(node\)\n",
                  r"\1")
watched("a Compose number field whose hardware Return commits nothing",
        {**REAL, COMPOSE: n37}, "hardware Return does not commit")
n38 = gate.doctor("the number field's focus-loss commit cut", REAL[COMPOSE],
                  r"(if \(wasFocused && !state\.isFocused\) \{\n\s*wasFocused = false\n)"
                  r"\s*kayaNumberCommit\(node\)\n",
                  r"\1")
watched("a Compose number field whose focus loss commits nothing", {**REAL, COMPOSE: n38},
        "focus loss does not commit")
n39 = gate.doctor("kayaNumberSettle emitting whether or not the value moved", REAL[COMPOSE],
                  r"(\n\s*kayaWriteText\(node, KayaPresent\.numberText\(node\.value, "
                  r"node\.step\)\)\n\})",
                  r"\n    KayaPresent.emitValueCommitted(node.tag, node.value)\1")
watched("a Compose number field firing on an unchanged commit", {**REAL, COMPOSE: n39},
        "an unchanged commit fires nothing")
n40 = gate.doctor("the harness's unfocus committing past the door", REAL[COMPOSE],
                  r'(\n\s*"unfocus" -> \{\n)',
                  r"\1                        onUi(activity) { "
                  r"kayaNumberCommit(KayaSceneModel.numberFields[0]) }\n")
watched("a Compose verb that commits without the user's door", {**REAL, COMPOSE: n40},
        "kayaNumberCommit( is called")

n_gtk_focus = gate.doctor("GTK's own focus-out controller left in place", REAL[GTK],
                          r"\n\s*spin\.remove_controller\(controller\);", "")
watched("a GTK number field committing when its window loses the keyboard",
        {**REAL, GTK: n_gtk_focus}, "GTK's own focus-out door is left")
n_gtk_tab = gate.doctor("the focus door's commit cut", REAL[GTK],
                        r"if !inside \{\n\s*spin\.update\(\);\n", "if !inside {\n")
watched("a GTK number field whose Tab away commits nothing", {**REAL, GTK: n_gtk_tab},
        "Tab away commits nothing")

# WINUI's number field
withheld_winui = {rel: row for rel, row in NUMBER_ROWS.items() if rel != WINUI}
print(f"check-submit: self-test the WinUI number row withheld, "
      f"{len(NUMBER_ROWS) - len(withheld_winui)} row(s) out of the table")
gate.negative("a WinUI number field arm with no row in this gate",
              lambda: census(REAL, withheld_winui), want="has no row for its commit doors")
n_win_quiet = gate.doctor("the ValueChanged door's quiet guard cut", REAL[WINUI],
                          r"(move \|sender, args\| \{\n)\s*if quiet\.load\("
                          r"std::sync::atomic::Ordering::Relaxed\) \{\n\s*return Ok\(\(\)\);\n"
                          r"\s*\}\n",
                          r"\1")
watched("a WinUI number field whose app write echoes", {**REAL, WINUI: n_win_quiet},
        "an app write echoes")
n_win_moved = gate.doctor("winui_number_settle emitting whether or not the value moved",
                          REAL[WINUI], r"(\n\s*if let Commit::Moved\(v\) = answer \{)",
                          r"\n    sink.send_value_committed_tag(&cell.tag, shown);\1")
watched("a WinUI number field firing on an unchanged commit", {**REAL, WINUI: n_win_moved},
        "an unchanged commit fires nothing")
n_win_parse = gate.doctor("KayaNumberText reading the text for itself", REAL[WINUI],
                          r"crate::fmt::parse_number\(text\.to_string\(\)\.trim\(\)\)",
                          "text.to_string().trim().parse().ok()")
watched("a WinUI number field whose parse is its own", {**REAL, WINUI: n_win_parse},
        "reads the text for itself")
n_win_text = gate.doctor("the NumberBox left with the platform's formatter", REAL[WINUI],
                         r"KayaNumberText \{ cell: cell\.clone\(\) \}\.into\(\)",
                         "DecimalFormatter::new()?.cast()?")
watched("a WinUI number field whose text is the platform's", {**REAL, WINUI: n_win_text},
        "not given kaya's own formatter")
n_win_verb = gate.doctor("the harness's nudge committing past the door", REAL[WINUI],
                         r"(\n(\s*)FrameworkElementAutomationPeer::CreatePeerForElement\(&button\)\?)",
                         r"\n\2winui_number_settle(&field, todo!(), todo!(), 0.0)?;\1")
watched("a WinUI verb that commits without the user's door", {**REAL, WINUI: n_win_verb},
        "winui_number_settle is called")

gate.negatives_ran(48)

for line in census(REAL):
    gate.finding(line)

gate.verdict("submitted publishes through the gesture's door alone on every backend, "
             "and a number field commits through its own")
