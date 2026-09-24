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


def census(texts):
    out = []
    for rel, row in ROWS.items():
        out.extend(row(texts[rel]))
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

gate.negatives_ran(23)

for line in census(REAL):
    gate.finding(line)

gate.verdict("submitted publishes through the gesture's door alone on every backend")
