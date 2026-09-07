#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# THE SEARCH FIELD'S TWO RULES NO SCENE CAN SEE (docs/search-plan.md S5,
# S7). S5: clearing is ONE act — the field's affordance, Escape on a
# desktop and the harness's clear_search empty the text through one path,
# so each reaches the app as text_changed("") with the focus kept. The
# shared scene drives clear_search, which on every backend takes the
# affordance's door or Escape's; an Escape arm that stopped clearing, or
# a verb that started writing the text itself and stopped exercising the
# key's path, passes tools/scenes/search.steps byte for byte. S7: each
# backend gives its assistive reader the identity its platform has
# (AXSearchField and the isSearchField trait, GTK's SEARCH_BOX role,
# Compose's prompt as the content description) while the shared verdict
# stays `field`, so a backend that dropped its identity reads identically
# to one that kept it. Beside them S6 on GTK, the one platform with a
# timer: the arm wires `changed`, never the 150 ms `search-changed`.
#
# THE TABLE GROWS BY ITSELF, check-slider-commit's shape: a backend still
# holding the kind off through `depth_stub("search")` has no arm to read,
# and the moment its stub goes this gate demands a row.

import re

SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

BACKENDS = [
    (SWIFT, r'kayaDepthStub\("search"'),
    (GTK, r'depth_stub\("search"\)'),
    (WINUI, r'depth_stub\("search"\)'),
    (COMPOSE, r'depthStub\("search"\)'),
]

gate = Gate("check-search")


def block_after(text, anchor):
    """The brace-balanced block that follows `anchor`, or "" when absent."""
    at = text.find(anchor)
    if at < 0:
        return ""
    start = text.find("{", at)
    if start < 0:
        return ""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def swift_findings(source):
    out = []
    view = block_after(source, "struct KayaSearch: View {")
    if not view:
        out.append(f"{SWIFT}: no `struct KayaSearch: View` block — the arm this gate reads is gone "
            f"or renamed")
        return out
    # S5: one clear path, called from the button, both Escape arms and the verb.
    if not re.search(r"\nfunc kayaSearchClear\(_ node: KayaNode\) \{", source):
        out.append(f"{SWIFT}: kayaSearchClear is gone — the one clear path the button, Escape and "
            f"clear_search share")
    body = block_after(source, "func kayaSearchClear(_ node: KayaNode)")
    if 'KayaHost.emitText(node, "")' not in body or "kayaScene.focusedId = node.id" not in body:
        out.append(f"{SWIFT}: kayaSearchClear must emit text_changed(\"\") and keep the focus — "
            f"S5's one act")
    if not re.search(r"\.onExitCommand \{ kayaSearchClear\(node\) \}", view):
        out.append(f"{SWIFT}: the Mac's Escape arm (onExitCommand) does not call kayaSearchClear — "
            f"Escape stopped clearing, and no scene can see it")
    escape_ios = block_after(view, ".onKeyPress(.escape)")
    if "kayaSearchClear(node)" not in escape_ios:
        out.append(f"{SWIFT}: the iOS hardware-keyboard Escape arm (onKeyPress(.escape)) does not "
            f"call kayaSearchClear")
    if not re.search(r"Button\(action: \{ kayaSearchClear\(node\) \}\)", view):
        out.append(f"{SWIFT}: the clear button does not take the shared clear path")
    verb = source[source.find('case "clear_search":'):source.find('case "expect_placeholder":')]
    if "kayaSearchClear(node)" not in verb:
        out.append(f"{SWIFT}: the clear_search verb arm does not take the shared clear path — the "
            f"lane stops exercising what the user gets")
    # S7: the trait, on the text field alone (docs/traps.md, the identifier on a row).
    a11y = block_after(source, "struct KayaSearchA11y: ViewModifier {")
    if ".accessibilityAddTraits(.isSearchField)" not in a11y:
        out.append(f"{SWIFT}: KayaSearchA11y no longer adds the isSearchField trait — the platform "
            f"identity S7 gives the reader")
    if ".modifier(KayaSearchA11y(node: node))" not in view:
        out.append(f"{SWIFT}: KayaSearch does not route its accessibility props through "
            f"KayaSearchA11y — they land on the row and reach the clear button too")
    if "if node.kind == kindSearch && !leaf {" not in source:
        out.append(f"{SWIFT}: kayaA11y no longer keeps the search row's props off the row (the "
            f"`leaf` routing)")
    # S8: the phone keyboard.
    for want in (".textInputAutocapitalization(.never)", ".submitLabel(.search)"):
        if want not in view:
            out.append(f"{SWIFT}: KayaSearch lost `{want}` — S8's phone keyboard")
    return out


def gtk_findings(source):
    out = []
    arm = block_after(source, "WidgetKind::Search => {")
    if not arm:
        out.append(f"{GTK}: no `WidgetKind::Search` create arm to read")
        return out
    if "gtk4::SearchEntry::new()" not in arm:
        out.append(f"{GTK}: the search arm does not build a gtk4::SearchEntry — GTK's own search "
            f"box, whose SEARCH_BOX role is S7's identity")
    # S6: every keystroke reports; search-changed waits 150 ms by default.
    if "connect_search_changed" in arm:
        out.append(f"{GTK}: the search arm wires `search-changed`, which fires `search-delay` ms "
            f"after the last keystroke (150 by default) — S6 says every keystroke reports; wire "
            f"`changed`")
    if "connect_changed" not in arm:
        out.append(f"{GTK}: the search arm has no `changed` handler — no keystroke reaches the app")
    # S5: Escape's signal writes the empty text, the verb raises the signal.
    stop = block_after(arm, "connect_stop_search(")
    if 'set_text(e, "")' not in stop:
        out.append(f"{GTK}: the stop-search (Escape) handler does not write the empty text — GTK's "
            f"signal clears nothing by itself, so Escape stopped clearing and no scene can see it")
    verb = block_after(source, "fn clear_search(&self, target: crate::harness::Target)")
    if "emit_stop_search()" not in verb:
        out.append(f"{GTK}: clear_search does not raise stop-search — the verb must take Escape's "
            f"door, since GTK's clear icon cannot be clicked from code")
    if "set_text(" in verb:
        out.append(f"{GTK}: clear_search writes the text itself — the verb then stops exercising "
            f"the key's path")
    # S7: the bus role the arm expects, and its fold to `field`.
    role_arm = block_after(source, "if w.is::<gtk4::SearchEntry>() {")
    if not role_arm or "atspi::Role::Entry" not in role_arm:
        out.append(f"{GTK}: atspi_role_of no longer reads GtkSearchEntry as the bus's `entry` role "
            f"— the search box is its own ordinal family (docs/traps.md)")
    # S3: the prompt on all three text kinds.
    for kind in ("Entry(entry)", "Search(search)", "Textarea(_, view)"):
        if f"(NativeWidget::{kind}, Prop::Placeholder, Value::Str(s))" not in source:
            out.append(f"{GTK}: no Prop::Placeholder apply arm for NativeWidget::{kind}")
    return out


def compose_findings(source):
    out = []
    if not re.search(r"\ninternal fun kayaSearchClear\(node: KayaNode\) \{", source):
        out.append(f"{COMPOSE}: kayaSearchClear is gone — the one clear path the button, Escape "
            f"and clear_search share")
        return out
    clear = block_after(source, "internal fun kayaSearchClear(node: KayaNode)")
    if 'kayaWriteText(node, "")' not in clear or "KayaSceneModel.focusedId = node.id" not in clear:
        out.append(f"{COMPOSE}: kayaSearchClear must write the empty text and keep the focus — "
            f"S5's one act")
    escape = block_after(source, "Modifier.onPreviewKeyEvent { event ->")
    if "Key.Escape" not in escape or "kayaSearchClear(node)" not in escape:
        out.append(f"{COMPOSE}: the hardware-keyboard Escape arm (onPreviewKeyEvent) does not call "
            f"kayaSearchClear")
    if "onClick = { kayaSearchClear(node) }" not in source:
        out.append(f"{COMPOSE}: the clear IconButton does not take the shared clear path")
    verb = block_after(source, '"clear_search" -> {')
    if "kayaSearchClear(" not in verb:
        out.append(f"{COMPOSE}: the clear_search verb arm does not take the shared clear path")
    # S7: no search role exists, so the prompt is the field's name when the app authored none.
    if "if (node.kind == KayaCompose.KIND_SEARCH) node.placeholder else \"\"" not in source:
        out.append(f"{COMPOSE}: the a11y name fallback no longer speaks the search field's "
            f"placeholder — Compose has no search role, so that IS the identity")
    # S8: the phone keyboard.
    for want in ("imeAction = ImeAction.Search", "KeyboardCapitalization.None"):
        if want not in source:
            out.append(f"{COMPOSE}: `{want}` is gone — S8's phone keyboard")
    return out


def winui_findings(source):
    out = []
    arm = block_after(source, "WidgetKind::Search => {")
    if not arm:
        out.append(f"{WINUI}: no `WidgetKind::Search` create arm to read")
        return out
    # S5: the template's DeleteButton is the one clear path; Escape's KeyDown
    # arm and the verb both take it.
    if not re.search(r"\nfn search_clear\(field: &TextBox\)", source):
        out.append(f"{WINUI}: search_clear is gone — the one clear path the DeleteButton, "
                   f"Escape and clear_search share")
    if '"DeleteButton"' not in source:
        out.append(f"{WINUI}: nothing finds the TextBox template's DeleteButton — the "
                   f"platform's own clear affordance (docs/measurements/"
                   f"search-winui-2026-09-06.md)")
    key = block_after(arm, "field.KeyDown(&KeyEventHandler::new(")
    if "VirtualKey::Escape" not in key or "search_clear(" not in key:
        out.append(f"{WINUI}: the KeyDown Escape arm does not call search_clear — Escape "
                   f"stopped clearing, and no scene can see it")
    verb = block_after(source, "fn clear_search(&self, t: crate::harness::Target)")
    if "search_clear(" not in verb:
        out.append(f"{WINUI}: the clear_search Stage arm does not take search_clear — the lane "
                   f"stops exercising the affordance the user gets")
    # S7: UIA has no search type; the props land on the FIELD and the glyph is
    # hidden from the assistive tree.
    if not re.search(r"\n\s+fn identity_element\(&self\)", source):
        out.append(f"{WINUI}: identity_element is gone — the a11y props, AutomationId and "
                   f"focus must land on the field, not the glyph's host")
    if "AutomationProperties::SetAccessibilityView(" not in arm:
        out.append(f"{WINUI}: the search arm no longer hides its glyph from the assistive tree")
    # S3: the prompt on all three text kinds.
    for kind in ("Entry(field)", "Textarea(field)", "Search { field, .. }"):
        if f"(NativeWidget::{kind}, Prop::Placeholder, Value::Str(s))" not in source:
            out.append(f"{WINUI}: no Prop::Placeholder apply arm for NativeWidget::{kind}")
    return out


ROWS = {SWIFT: swift_findings, GTK: gtk_findings, WINUI: winui_findings,
        COMPOSE: compose_findings}


def census(texts, rows=ROWS):
    out = []
    landed = 0
    for rel, stub in BACKENDS:
        text = texts[rel]
        if re.search(stub, text):
            continue
        landed += 1
        row = rows.get(rel)
        if row is None:
            out.append(f"{rel}: landed its search arm and this gate has no row for it — add one "
                f"holding S5's one clear path and S7's identity")
            continue
        out.extend(row(text))
    if landed == 0:
        out.append("no backend has landed a search arm — the census read nothing")
    return out


REAL = {rel: gate.read(rel) for rel, _ in BACKENDS}


def watched(label, texts, want, rows=ROWS):
    gate.negative(label, lambda: census(texts, rows), want=want)


# 1. SWIFT: THE MAC'S ESCAPE ARM STOPS CLEARING.
no_exit = gate.doctor("the mac onExitCommand clear cut out", REAL[SWIFT],
                      r"\.onExitCommand \{ kayaSearchClear\(node\) \}",
                      ".onExitCommand { }")
watched("a SwiftUI search field whose Escape clears nothing",
        {**REAL, SWIFT: no_exit}, "Escape stopped clearing")

# 2. SWIFT: THE TRAIT GOES.
no_trait = gate.doctor("the isSearchField trait removed", REAL[SWIFT],
                       r"content\.accessibilityAddTraits\(\.isSearchField\)", "content")
watched("a SwiftUI search field with no search trait",
        {**REAL, SWIFT: no_trait}, "isSearchField trait")

# 3. GTK: ESCAPE'S SIGNAL WRITES NOTHING.
gtk_no_clear = gate.doctor("the gtk stop-search write cut out", REAL[GTK],
                           r'search\.connect_stop_search\(\|e\| \{\n\s*'
                           r'gtk4::prelude::EditableExt::set_text\(e, ""\);',
                           "search.connect_stop_search(|e| {\n let _ = e;")
watched("a GTK search field whose Escape clears nothing",
        {**REAL, GTK: gtk_no_clear}, "Escape stopped clearing")

# 4. GTK: THE VERB WRITES THE TEXT ITSELF.
gtk_verb_writes = gate.doctor("the gtk verb bypassing stop-search", REAL[GTK],
                              r"core\.searches\[i\]\.emit_stop_search\(\);",
                              'gtk4::prelude::EditableExt::set_text(&core.searches[i], "");')
watched("a GTK clear_search that stops exercising the key's path",
        {**REAL, GTK: gtk_verb_writes}, "does not raise stop-search")

# 5. GTK: THE DEBOUNCED SIGNAL COMES BACK.
gtk_debounced = gate.doctor("the gtk changed handler renamed to search-changed", REAL[GTK],
                            r"EditableExt::connect_changed\(&search, move \|e\| \{",
                            "SearchEntryExt::connect_search_changed(&search, move |e| {")
watched("a GTK search field on the 150 ms search-changed signal",
        {**REAL, GTK: gtk_debounced}, "search-delay")

# 6. COMPOSE: THE ESCAPE ARM STOPS CLEARING.
compose_no_escape = gate.doctor("the compose Escape clear cut out", REAL[COMPOSE],
                                r"event\.key == Key\.Escape &&", "event.key == Key.F1 &&")
watched("a Compose search field whose Escape clears nothing",
        {**REAL, COMPOSE: compose_no_escape}, "Escape arm")

# 7. COMPOSE: THE IDENTITY FALLBACK GOES.
compose_no_name = gate.doctor("the compose prompt-as-name fallback cut out", REAL[COMPOSE],
                              r'if \(node\.kind == KayaCompose\.KIND_SEARCH\) '
                              r'node\.placeholder else ""',
                              '""')
watched("a Compose search field that speaks no identity",
        {**REAL, COMPOSE: compose_no_name}, "no search role")

# 8. A BACKEND THAT LANDED ITS ARM AND NEVER JOINED THIS TABLE.
watched("a landed Compose arm with no row in this gate", REAL,
        "this gate has no row for it",
        rows={k: v for k, v in ROWS.items() if k != COMPOSE})

# 9. WINUI: THE ESCAPE ARM STOPS CLEARING.
winui_no_escape = gate.doctor("the winui KeyDown Escape test cut out", REAL[WINUI],
                              r"if args\.Key\(\)\? != VirtualKey::Escape \{",
                              "if args.Key()? != VirtualKey::F1 {")
watched("a WinUI search field whose Escape clears nothing",
        {**REAL, WINUI: winui_no_escape}, "Escape stopped clearing")

gate.negatives_ran(9)

for line in census(REAL):
    gate.finding(line)

gate.verdict("one clear path and the platform's identity on every landed search arm")
