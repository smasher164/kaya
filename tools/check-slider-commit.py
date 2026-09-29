#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# A SLIDER COMMITS ONCE PER GESTURE, AND NO LANE CAN SEE IT
# (docs/slider-plan.md S2, §6). `set_value` is the only slider drive any
# scene has and it is ONE finished gesture by construction, so a backend
# that published `value_committed` on EVERY movement of a real drag passes
# tools/scenes/sliders.steps byte for byte — measured 2026-09-04, when this
# arm's first draft did exactly that and the whole windows lane stayed
# green. A drag is pixels and a pointer; the shared scenes have neither.
# So, like the native-undo pair and the table card, a static gate is the
# only wall available.
#
# THE RULE, one sentence for every backend: the per-movement event carries
# the LIVE value and is final only when no pointer is driving, and the
# gesture's own end — whatever the toolkit calls it — is what publishes the
# committed one.
#
# THE TABLE GROWS BY ITSELF: a backend still refusing the two props through
# `depth_stub("sliders")` has no arm to hold, and the moment its stub goes
# this gate demands a row. That is the half nobody has to remember.
#
# THE COLOUR PICKER IS THE SAME RULE (docs/color-picker-plan.md §3 rule 2,
# §7): `set_color` is one settled choice by construction, so a SwiftUI arm
# committing on every drag event in the shared panel passes
# tools/scenes/colorpicker.steps byte for byte. The mac door is measured
# (§4.1): the panel's mouse down opens a gesture and a DEFAULT-mode perform
# closes it after the tracking loop.

import re

WINUI = "crates/kaya/src/winui/mod.rs"
GTK = "crates/kaya/src/gtk.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

# Every backend that lowers a slider, and how to tell its arm has landed.
BACKENDS = [
    (WINUI, r'depth_stub\("sliders"\)'),
    (GTK, r'depth_stub\("sliders"\)'),
    (COMPOSE, r'depthStub\("sliders"\)'),
]

gate = Gate("check-slider-commit")


def block_after(text, anchor):
    """The brace-balanced block that follows `anchor`, or "" when absent.

    Brace depth rather than a line pattern: the ValueChanged handler's
    commit call is eight lines below its own `if let Some(sender)` and the
    two handlers in the arm are spelled alike, so a line-oriented reader
    would answer for whichever it met first.
    """
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


def winui_findings(source):
    """The WinUI arm's three commit sites and the two events behind them."""
    out = []
    # The commit path exists and is called from exactly three places: the
    # per-movement event, the gesture's end, and the harness's drive.
    calls = len(re.findall(r"winui_slider_committed\(", source))
    if calls != 4:  # one definition + three calls
        out.append(
            f"{WINUI}: winui_slider_committed appears {calls} time(s); the arm "
            f"is one definition plus exactly three calls — the ValueChanged "
            f"handler, the PointerCaptureLost handler and set_value")

    moved = block_after(source, "RangeBaseValueChangedEventHandler::new(")
    if not moved:
        out.append(
            f"{WINUI}: no RangeBaseValueChangedEventHandler block — the "
            f"per-movement arm this gate reads is gone or renamed")
    else:
        final = re.search(
            r"winui_slider_committed\(\s*&slider,\s*&\w+,\s*&\w+,\s*&\w+,\s*"
            r"(.+?),?\s*\)\?;", moved, re.S)
        if final is None:
            out.append(
                f"{WINUI}: the ValueChanged handler does not call "
                f"winui_slider_committed")
        elif final.group(1).strip() != "!pointer_button_down()":
            out.append(
                f"{WINUI}: the ValueChanged handler commits with "
                f"`{final.group(1).strip()}` — a per-movement event is final "
                f"ONLY when no pointer is driving (!pointer_button_down()), "
                f"or a real drag publishes one value_committed per pixel and "
                f"no lane can see it")

    end = block_after(source, "slider.PointerCaptureLost(&PointerEventHandler::new(")
    if not end:
        out.append(
            f"{WINUI}: the Slider registers no PointerCaptureLost handler — "
            f"WinUI raises no finished event and marks its own "
            f"PointerPressed/PointerReleased handled (measured 2026-09-04), "
            f"so this is the ONLY end a drag has")
    else:
        final = re.search(
            r"winui_slider_committed\(\s*&slider,\s*&\w+,\s*&\w+,\s*&\w+,\s*"
            r"(.+?),?\s*\)\?;", end, re.S)
        if final is None or final.group(1).strip() != "true":
            got = final.group(1).strip() if final else "no call at all"
            out.append(
                f"{WINUI}: the PointerCaptureLost handler ends the gesture "
                f"with `{got}` — the released thumb IS the commit")

    # The discriminator itself, defined once and read only there.
    if not re.search(r"\nfn pointer_button_down\(\) -> bool \{", source):
        out.append(
            f"{WINUI}: pointer_button_down() is gone — the arm has no way "
            f"left to tell a drag's own movements from a key's")
    return out


def call_args(inner):
    """A call's arguments, the trailing comma rustfmt leaves dropped."""
    return [a.strip() for a in inner.rstrip().rstrip(",").split(",") if a.strip()]


def gtk_findings(source):
    """The GTK arm: value-changed is live while a pointer button is down,
    and the release — read off the raw event stream, since GtkRange's own
    gesture claims the sequence (docs/traps.md) — is the commit."""
    out = []
    calls = len(re.findall(r"\bslider_committed\(", source))
    if calls != 3:  # one definition + the value-changed handler + the release
        out.append(
            f"{GTK}: slider_committed appears {calls} time(s); the arm is one "
            f"definition plus exactly two calls — the value-changed handler "
            f"and the pointer release (set_value drives the scale and lets "
            f"value-changed run)")
    moved = block_after(source, "scale.connect_value_changed(move |sc| {")
    if not moved:
        out.append(f"{GTK}: no value-changed handler on the scale — the "
                   f"per-movement arm this gate reads is gone or renamed")
    else:
        settled = re.search(r"let settled = (.+?);", moved)
        call = re.search(r"slider_committed\((.*?)\);", moved, re.S)
        args = call_args(call.group(1)) if call else []
        if settled is None or settled.group(1).strip() != "!committed.state.get().dragging":
            got = settled.group(1).strip() if settled else "no `settled` at all"
            out.append(
                f"{GTK}: the value-changed handler settles with `{got}` — a "
                f"per-movement event is final ONLY when no pointer is driving "
                f"(!committed.state.get().dragging), or a real drag publishes "
                f"one value_committed per pixel and no lane can see it")
        elif not args or args[-1] != "settled":
            out.append(f"{GTK}: the value-changed handler does not pass "
                       f"`settled` to slider_committed")
    release = block_after(source, "pointer.connect_event(move |_, event| {")
    if not release or "EventType::ButtonRelease" not in release:
        out.append(
            f"{GTK}: the scale's capture-phase EventControllerLegacy has no "
            f"ButtonRelease arm — a GestureClick never sees a scale's release "
            f"(measured 2026-09-04), so this is the ONLY end a drag has")
    else:
        arm = release[release.index("EventType::ButtonRelease"):]
        call = re.search(r"slider_committed\((.*?)\);", arm, re.S)
        args = call_args(call.group(1)) if call else []
        if not args or args[-1] != "true":
            got = args[-1] if args else "no call at all"
            out.append(f"{GTK}: the release arm ends the gesture with `{got}` "
                       f"— the released thumb IS the commit")
    if "state.dragging = true" not in (release or ""):
        out.append(f"{GTK}: nothing marks the pointer DOWN on the scale, so "
                   f"every movement would read as settled")
    return out


def compose_findings(source):
    """The Compose arm: Material's onValueChange is the live event and
    onValueChangeFinished the gesture's end; no pointer read is needed,
    since the toolkit itself tells the two apart."""
    out = []
    calls = len(re.findall(r"\bkayaSliderCommitted\(", source))
    if calls != 4:  # one definition + onValueChange + onValueChangeFinished + set_value
        out.append(
            f"{COMPOSE}: kayaSliderCommitted appears {calls} time(s); the arm "
            f"is one definition plus exactly three calls — onValueChange, "
            f"onValueChangeFinished and the set_value verb")
    surface = block_after(source, "private fun KayaSliderSurface(")
    if not surface:
        out.append(f"{COMPOSE}: no KayaSliderSurface — the arm this gate "
                   f"reads is gone or renamed")
        return out
    moved = re.search(r"onValueChange = \{ kayaSliderCommitted\((.*?)\) \}", surface, re.S)
    if moved is None or not moved.group(1).rstrip().endswith("final = false"):
        got = moved.group(1).strip() if moved else "no call at all"
        out.append(
            f"{COMPOSE}: onValueChange commits with `{got}` — a per-movement "
            f"event is final ONLY when the gesture is over (final = false "
            f"here), or a real drag publishes one value_committed per pixel")
    finished = re.search(
        r"onValueChangeFinished = \{ kayaSliderCommitted\((.*?)\) \}", surface, re.S)
    if finished is None or not finished.group(1).rstrip().endswith("final = true"):
        got = finished.group(1).strip() if finished else "no onValueChangeFinished at all"
        out.append(f"{COMPOSE}: the gesture's end is `{got}` — Material's "
                   f"onValueChangeFinished IS the commit (final = true)")
    return out


ROWS = {WINUI: winui_findings, GTK: gtk_findings, COMPOSE: compose_findings}


def census(sources, rows=ROWS):
    """Every backend with a landed arm answers for its commit rule."""
    out = []
    for path, stub in BACKENDS:
        source = sources[path]
        if re.search(stub, source):
            continue
        reader = rows.get(path)
        if reader is None:
            out.append(
                f"{path}: the slider arm has landed (no {stub} left) and this "
                f"gate has no row for it — add one beside winui_findings, "
                f"naming this backend's per-movement event and its gesture "
                f"end (docs/slider-plan.md S2)")
            continue
        out.extend(reader(source))
    return out


SWIFTUI = "swift/KayaSwiftUI.swift"


def swiftui_color_findings(source):
    """Every colour commit sits behind the gesture's end or a closed surface."""
    out = []
    commit = block_after(source, "func kayaColorCommitted(")
    if not commit:
        return [f"{SWIFTUI}: func kayaColorCommitted is gone — the one commit "
                f"path this clause holds every door to"]
    emits = len(re.findall(r"KayaHost\.emitColorChanged\(", source))
    if emits != 1 or "KayaHost.emitColorChanged(" not in commit:
        out.append(f"{SWIFTUI}: KayaHost.emitColorChanged is called {emits} time(s); "
                   f"the one call belongs inside kayaColorCommitted, so no path "
                   f"publishes a colour past the doors")
    if "if packed == node.color { return }" not in commit:
        out.append(f"{SWIFTUI}: kayaColorCommitted commits a colour equal to the "
                   f"held one — a choice that changes nothing emits nothing (§2)")
    door = block_after(source, "func kayaColorDoorInstall()")
    for piece in (".leftMouseDown", "NSColorPanel.shared",
                  "RunLoop.main.perform(inModes: [.default])", "kayaColorGestureEnded()"):
        if piece not in door:
            out.append(f"{SWIFTUI}: the mac door lacks `{piece}` — the panel's mouse "
                       f"down opens the gesture and only a .default-mode perform "
                       f"runs after its tracking loop (§4.1)")
    changed = block_after(source, "@objc func changed(_ sender: NSColorWell)")
    if not re.search(r"if kayaColorGesture \{\s*kayaColorPending\[node\.id\] = packed\s*"
                     r"\} else \{\s*kayaColorCommitted\(node, packed\)", changed):
        out.append(f"{SWIFTUI}: the well's action commits without asking whether a "
                   f"panel gesture is open — a drag in the panel then publishes one "
                   f"color_changed per event (§4.1: two actions per drag event)")
    select = block_after(source, "didSelect color: UIColor, continuously: Bool")
    if "guard !continuously" not in select:
        out.append(f"{SWIFTUI}: the iOS picker's select commits a continuous "
                   f"selection — only the noncontinuous one ends the gesture (§4.2)")
    ios_drive = block_after(source, "func kayaDriveColor(_ node: KayaNode, _ well: UIColorWell")
    for where, block in (("the iOS picker's select", select), ("set_color's iOS drive", ios_drive)):
        if "opaque: !node.alpha" not in block:
            out.append(f"{SWIFTUI}: {where} does not strip alpha on an opaque picker — "
                       f"UIKit holds no colour opaque, so the arm must (§4.2)")
    doors = [changed, block_after(source, "func kayaColorGestureEnded()"), select]
    at = 0
    while True:
        at = source.find("func kayaDriveColor(", at)
        if at < 0:
            break
        doors.append(block_after(source[at:], "func kayaDriveColor("))
        at += 1
    calls = len(re.findall(r"(?<!func )kayaColorCommitted\(", source))
    inside = sum(len(re.findall(r"kayaColorCommitted\(", d)) for d in doors)
    if calls != inside:
        out.append(f"{SWIFTUI}: kayaColorCommitted is called {calls} time(s) and "
                   f"{inside} of them sit in a door (the well's action outside a "
                   f"gesture, the gesture's end, the iOS noncontinuous select, "
                   f"set_color's drive) — a commit anywhere else is a drag's")
    return out


REAL = {path: gate.read(path) for path, _ in BACKENDS}
gate.counted("backend arms read", len(REAL), floor=3)
SWIFT_SOURCE = gate.read(SWIFTUI)
gate.counted("swiftui colour commit calls read",
             len(re.findall(r"(?<!func )kayaColorCommitted\(", SWIFT_SOURCE)), floor=4)


def watched(label, sources, fragment, rows=ROWS):
    """The negative: the gate's OWN census over doctored input, red demanded."""
    if not gate.negative(label, lambda: census(sources, rows), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# 1. THE MOVEMENT COMMITS — the shipped-shape defect, and the one the
#    measurement caught in this arm's first draft.
per_movement = gate.doctor(
    "the winui per-movement commit", REAL[WINUI],
    r"&sink,\n                                    !pointer_button_down\(\),",
    "&sink,\n                                    true,")
watched("a WinUI arm committing on every drag movement",
        {**REAL, WINUI: per_movement}, "a per-movement event is final ONLY")

# 2. THE GESTURE HAS NO END.
no_end = gate.doctor(
    "the winui capture-lost removal", REAL[WINUI],
    r"slider\.PointerCaptureLost\(&PointerEventHandler::new\(",
    "slider.PointerEntered(&PointerEventHandler::new(")
watched("a WinUI slider with no PointerCaptureLost",
        {**REAL, WINUI: no_end}, "registers no PointerCaptureLost")

# 3. THE END STOPS ENDING — present but not final, which a presence check
#    passes.
soft_end = gate.doctor(
    "the winui non-final capture loss", REAL[WINUI],
    r"&released_sink,\n                                    true,",
    "&released_sink,\n                                    false,")
watched("a WinUI capture loss that publishes nothing",
        {**REAL, WINUI: soft_end}, "ends the gesture with `false`")

# 4. THE DISCRIMINATOR ITSELF DELETED.
no_reader = gate.doctor(
    "the winui pointer-read removal", REAL[WINUI],
    r"\nfn pointer_button_down\(\) -> bool \{", "\nfn pointer_button_held() -> bool {")
watched("a WinUI arm whose pointer read was renamed away",
        {**REAL, WINUI: no_reader}, "pointer_button_down() is gone")

# 5. A BACKEND THAT LANDED ITS ARM AND NEVER JOINED THIS TABLE — the
#    self-maintaining half: every stub is gone now, so the table itself is
#    the thing perturbed.
watched("a GTK slider arm with no row in this gate", REAL,
        "this gate has no row for it", rows={WINUI: winui_findings, COMPOSE: compose_findings})

# 6. GTK: EVERY MOVEMENT SETTLES — the pointer read replaced by a constant.
gtk_always = gate.doctor(
    "the gtk per-movement settle", REAL[GTK],
    r"let settled = !committed\.state\.get\(\)\.dragging;", "let settled = true;")
watched("a GTK arm settling on every drag movement",
        {**REAL, GTK: gtk_always}, "final ONLY when no pointer is driving")

# 7. GTK: THE RELEASE STOPS ENDING.
gtk_soft = gate.doctor(
    "the gtk non-final release", REAL[GTK],
    r"committed\.scale\.value\(\),\n(\s+)true,", r"committed.scale.value(),\n\1false,")
watched("a GTK release that publishes nothing",
        {**REAL, GTK: gtk_soft}, "ends the gesture with `false`")

# 8. GTK: NO RELEASE ARM AT ALL.
gtk_no_release = gate.doctor(
    "the gtk release arm removal", REAL[GTK],
    r"gdk::EventType::ButtonRelease\n", "gdk::EventType::Scroll\n")
watched("a GTK scale whose controller never sees the release",
        {**REAL, GTK: gtk_no_release}, "no\nButtonRelease arm".replace("\n", " "))

# 9. COMPOSE: THE MOVEMENT COMMITS.
compose_always = gate.doctor(
    "the compose per-movement commit", REAL[COMPOSE],
    r"onValueChange = \{ kayaSliderCommitted\(node, it\.toDouble\(\), final = false\) \}",
    "onValueChange = { kayaSliderCommitted(node, it.toDouble(), final = true) }")
watched("a Compose arm committing on every drag movement",
        {**REAL, COMPOSE: compose_always}, "final ONLY when the gesture is over")

# 10. COMPOSE: THE GESTURE HAS NO END.
compose_no_end = gate.doctor(
    "the compose finished-callback removal", REAL[COMPOSE],
    r"onValueChangeFinished = \{ kayaSliderCommitted\(",
    "onValueChangeStarted = { kayaSliderCommitted(")
watched("a Compose slider with no onValueChangeFinished",
        {**REAL, COMPOSE: compose_no_end}, "no onValueChangeFinished at all")


def color_watched(label, source, fragment):
    if not gate.negative(label, lambda: swiftui_color_findings(source), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# 11. THE MAC DOOR CLOSES IN THE TRACKING MODE — the block would run between
#     two drag events.
color_watched("a colour door closing in the common modes", gate.doctor(
    "the colour door's mode", SWIFT_SOURCE,
    r"RunLoop\.main\.perform\(inModes: \[\.default\]\)",
    "RunLoop.main.perform(inModes: [.common])"), "only a .default-mode perform")

# 12. THE WELL'S ACTION IGNORES THE GESTURE.
color_watched("a well committing every panel drag event", gate.doctor(
    "the gesture check", SWIFT_SOURCE,
    r"if kayaColorGesture \{\n(\s*)kayaColorPending\[node\.id\] = packed\n(\s*)\} else \{",
    r"if false {\n\1kayaColorPending[node.id] = packed\n\2} else {"),
    "one color_changed per event")

# 13. iOS: THE CONTINUOUS SELECT COMMITS.
color_watched("an iOS picker committing continuous selections", gate.doctor(
    "the continuous guard", SWIFT_SOURCE,
    r"guard !continuously, let packed", "guard let packed"),
    "commits a continuous")

# 14. AN EMIT PAST THE COMMIT PATH.
color_watched("a colour emitted outside kayaColorCommitted", gate.doctor(
    "a second emit", SWIFT_SOURCE,
    r"(@objc func changed\(_ sender: NSColorWell\) \{\n)",
    r"\1            KayaHost.emitColorChanged(node.tag, 0)\n"),
    "is called 2 time(s)")

# 15. A COMMIT OUTSIDE EVERY DOOR.
color_watched("a colour committed from the surface's apply", gate.doctor(
    "a commit in apply", SWIFT_SOURCE,
    r"(            well\.supportsAlpha = node\.alpha\n)",
    r"\1            kayaColorCommitted(node, node.color)\n"),
    "sit in a door")

# 16. THE SAME COLOUR COMMITS AGAIN.
color_watched("a commit of the held colour", gate.doctor(
    "the same-value return", SWIFT_SOURCE,
    r"    if packed == node\.color \{ return \}\n", ""),
    "equal to the held one")

# 16a. iOS: THE SELECT KEEPS A TRANSLUCENT CHOICE ON AN OPAQUE PICKER.
color_watched("an iOS select keeping alpha", gate.doctor(
    "the select's alpha strip", SWIFT_SOURCE,
    r"kayaColorOf\(color, opaque: !node\.alpha\)", "kayaColorOf(color, opaque: false)"),
    "the iOS picker's select does not strip alpha")

# 16b. iOS: set_color's DRIVE KEEPS IT.
color_watched("an iOS drive keeping alpha", gate.doctor(
    "the drive's alpha strip", SWIFT_SOURCE,
    r"kayaColorOf\(kayaUIColor\(packed\), opaque: !node\.alpha\)",
    "kayaColorOf(kayaUIColor(packed), opaque: false)"),
    "set_color's iOS drive does not strip alpha")

def compose_color_findings(source):
    """Compose's synthesized sheet (docs/color-picker-plan.md §6): the one
    emit is in kayaColorCommitted, which only the sheet's door calls, and the
    door opens only on the sheet's dismissal, its Done and set_color — never
    in a slider's onValueChange or the hex field's."""
    out = []
    commit = block_after(source, "internal fun kayaColorCommitted(")
    if not commit:
        return [f"{COMPOSE}: internal fun kayaColorCommitted is gone — the one "
                f"commit path this clause holds every door to"]
    emits = len(re.findall(r"KayaPresent\.emitColorChanged\(", source))
    if emits != 1 or "KayaPresent.emitColorChanged(" not in commit:
        out.append(f"{COMPOSE}: KayaPresent.emitColorChanged is called {emits} "
                   f"time(s); the one call belongs inside kayaColorCommitted")
    if "if (packed == node.color) return" not in commit:
        out.append(f"{COMPOSE}: kayaColorCommitted commits a colour equal to the "
                   f"held one — a choice that changes nothing emits nothing (§2)")
    sheet = block_after(source, "fun KayaColorSheet()")
    grid = block_after(sheet, "for (shade in 0 until 5)")
    if not (re.search(r"val current = kayaColorDraftPacked\(draft\)", sheet)
            and re.search(r"val chosen = \(entry or 0xFFL\) == \(current or 0xFFL\)", grid)
            and re.search(r"selectable\(selected = chosen\b", grid)
            and re.search(r"if \(chosen\) \{\s*Icon\(\s*Icons\.Filled\.Check,", grid)):
        out.append(f"{COMPOSE}: the sheet's palette does not mark the entry equal to the "
                   f"quantized draft with a selected Check (docs/deferred.md, the "
                   f"colour picker flyout entry)")
    tiers = (
        ("kayaColorCommitted", [block_after(source, "internal fun kayaColorSheetClosed(")],
         "the sheet's door, kayaColorSheetClosed"),
        ("kayaColorSheetClosed", [block_after(source, "internal fun kayaColorSheetDismissed("),
                                  block_after(source, '"set_color" -> {')],
         "the shown sheet's dismissal and set_color's drive"),
        ("kayaColorSheetDismissed", [block_after(sheet, "onDismissRequest = "),
                                     block_after(sheet, ".invokeOnCompletion")],
         "the sheet's onDismissRequest and Done's hide completion"),
    )
    for name, doors, where in tiers:
        calls = len(re.findall(rf"(?<!fun ){name}\(", source))
        inside = sum(len(re.findall(rf"{name}\(", d)) for d in doors)
        if calls != inside or any(name + "(" not in d for d in doors):
            out.append(f"{COMPOSE}: {name} is called {calls} time(s) and {inside} "
                       f"of them sit in a door ({where}) — a commit from a "
                       f"slider's or the hex field's onValueChange is a drag's")
    return out


gate.counted("compose colour door calls read",
             len(re.findall(r"(?<!fun )kayaColorSheet(?:Closed|Dismissed)\(", REAL[COMPOSE])),
             floor=4)


def compose_color_watched(label, source, fragment):
    if not gate.negative(label, lambda: compose_color_findings(source), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# 17. COMPOSE: A SLIDER'S MOVEMENT COMMITS.
compose_color_watched("a Compose hue slider committing", gate.doctor(
    "a commit in the hue slider", REAL[COMPOSE],
    r"(                draft\.hue = it\n)",
    r"\1                kayaColorCommitted(node, kayaColorDraftPacked(draft))\n"),
    "kayaColorCommitted is called")

# 18. COMPOSE: THE HEX FIELD'S TYPING COMMITS.
compose_color_watched("a Compose hex field committing per keystroke", gate.doctor(
    "a door in the hex field", REAL[COMPOSE],
    r"onValueChange = \{ draft\.typed\(it\) \}",
    "onValueChange = { draft.typed(it); kayaColorSheetClosed(node, draft) }"),
    "kayaColorSheetClosed is called")

# 19. COMPOSE: A SLIDER CLOSES THE SHEET.
compose_color_watched("a Compose brightness slider dismissing", gate.doctor(
    "a dismissal in the brightness slider", REAL[COMPOSE],
    r"(                draft\.brightness = it\n)",
    r"\1                kayaColorSheetDismissed(node, draft)\n"),
    "kayaColorSheetDismissed is called")

# 20. COMPOSE: DONE HIDES WITHOUT THE DOOR.
compose_color_watched("a Compose Done that commits nothing", gate.doctor(
    "Done's door removed", REAL[COMPOSE],
    r"\.invokeOnCompletion \{\n(\s*)kayaColorSheetDismissed\(node, draft\)\n",
    r".invokeOnCompletion {\n\1KayaSceneModel.colorSheetFor = null\n"),
    "kayaColorSheetDismissed is called")

# 21. COMPOSE: A SECOND EMIT.
compose_color_watched("a Compose colour emitted outside kayaColorCommitted", gate.doctor(
    "a second compose emit", REAL[COMPOSE],
    r"(                draft\.saturation = it\n)",
    r"\1                KayaPresent.emitColorChanged(node.tag, node.color)\n"),
    "is called 2 time(s)")

# 22b. COMPOSE: THE PALETTE MARKS NOTHING.
compose_color_watched("a Compose palette that never reads the current colour", gate.doctor(
    "the palette's current compare", REAL[COMPOSE],
    r"val chosen = \(entry or 0xFFL\) == \(current or 0xFFL\)", "val chosen = false"),
    "does not mark the entry")

# 22. COMPOSE: THE SAME COLOUR COMMITS AGAIN.
compose_color_watched("a Compose commit of the held colour", gate.doctor(
    "the compose same-value return", REAL[COMPOSE],
    r"    if \(packed == node\.color\) return\n", ""),
    "equal to the held one")

def winui_color_findings(source):
    """WinUI's flyout (docs/color-picker-plan.md §4.4, §6): the one emit is in
    winui_color_commit, which only the flyout's Closed and set_color call; a
    ColorChanged registration fires for an app's own write (measured), so it
    exists only behind the quiet guard."""
    out = []
    commit = block_after(source, "fn winui_color_commit(")
    if not commit:
        return [f"{WINUI}: fn winui_color_commit is gone — the one commit path "
                f"this clause holds every door to"]
    emits = len(re.findall(r"\.send_color_tag\(", source))
    if emits != 1 or ".send_color_tag(" not in commit:
        out.append(f"{WINUI}: send_color_tag is called {emits} time(s); the one "
                   f"call belongs inside winui_color_commit")
    if not re.search(r"if cell\.held\.swap\(packed, [^)]*\) != packed \{", commit):
        out.append(f"{WINUI}: winui_color_commit commits a colour equal to the held "
                   f"one — a choice that changes nothing emits nothing (§5)")
    if not re.search(r"!cell\.alpha\.load\([^)]*\) && color\.a != 0xFF \{\s*color\.a = 0xFF;",
                     commit):
        out.append(f"{WINUI}: winui_color_commit no longer lands a translucent choice "
                   f"opaque on an opaque picker (§5 AMENDED)")
    swatch = block_after(source, "impl ColorSwatch {")
    if "flyout.SetShouldConstrainToRootBounds(false)?;" not in swatch:
        out.append(f"{WINUI}: the colour flyout is constrained to the window, so the "
                   f"picker's channel boxes fall off a short window's edge "
                   f"(docs/deferred.md, the colour picker flyout entry)")
    arm = block_after(source, "WidgetKind::ColorPicker => {")
    if "swatch.flyout.Closed(&closed)" not in arm:
        out.append(f"{WINUI}: the colour picker's door is not the flyout's Closed — "
                   f"the dismissal is the settled choice (§4.4)")
    doors = [block_after(arm, "EventHandler::<windows_core::IInspectable>::new("),
             block_after(source, "fn set_color(")]
    calls = len(re.findall(r"(?<!fn )winui_color_commit\(", source))
    inside = sum(len(re.findall(r"winui_color_commit\(", d)) for d in doors)
    if calls != inside or any("winui_color_commit(" not in d for d in doors):
        out.append(f"{WINUI}: winui_color_commit is called {calls} time(s) and "
                   f"{inside} of them sit in a door (the flyout's Closed, set_color's "
                   f"drive) — a commit anywhere else is a drag's or an echo")
    at = 0
    while True:
        at = source.find(".ColorChanged(", at)
        if at < 0:
            break
        handler = block_after(source[at:], "::new(")
        if not re.match(r"\{\s*if quiet\.load\(", handler):
            out.append(f"{WINUI}: a ColorChanged handler does not open on the quiet "
                       f"guard — the event fires for the app's own write (§4.4)")
        at += 1
    return out


gate.counted("winui colour door calls read",
             len(re.findall(r"(?<!fn )winui_color_commit\(", REAL[WINUI])), floor=2)


def winui_color_watched(label, source, fragment):
    if not gate.negative(label, lambda: winui_color_findings(source), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# 23. WINUI: A SECOND EMIT.
winui_color_watched("a WinUI colour emitted outside winui_color_commit", gate.doctor(
    "a second winui emit", REAL[WINUI],
    r"(            swatch\.picker\.SetColor\(winui_ui_color\(color\)\)\?;\n"
    r"            winui_color_commit)",
    r"            core.occurrences.send_color_tag(&cell.tag, 0);\n\1"),
    "is called 2 time(s)")

# 24. WINUI: A COMMIT FROM THE APPLY ARM.
winui_color_watched("a WinUI colour committed from the apply arm", gate.doctor(
    "a commit in the alpha arm", REAL[WINUI],
    r"(                    swatch\.picker\.SetIsAlphaEnabled\(on\)\?;\n)",
    r"\1                    winui_color_commit(swatch, cell, &core.occurrences)?;\n"),
    "sit in a door")

# 25. WINUI: THE SAME COLOUR COMMITS AGAIN.
winui_color_watched("a WinUI commit of the held colour", gate.doctor(
    "the winui held compare", REAL[WINUI],
    r"if cell\.held\.swap\(packed, std::sync::atomic::Ordering::Relaxed\) != packed \{",
    "if { cell.held.store(packed, std::sync::atomic::Ordering::Relaxed); true } {"),
    "equal to the held one")

# 26. WINUI: THE DOOR IS THE FLYOUT'S OPENING.
winui_color_watched("a WinUI picker committing when its flyout opens", gate.doctor(
    "the winui door event", REAL[WINUI],
    r"swatch\.flyout\.Closed\(&closed\)", "swatch.flyout.Opened(&closed)"),
    "not the flyout's Closed")

# 27. WINUI: AN UNGUARDED ColorChanged.
winui_color_watched("a WinUI ColorChanged handler with no quiet guard", gate.doctor(
    "an unguarded ColorChanged", REAL[WINUI],
    r"(                    swatch\.flyout\.Closed\(&closed\)\?;\n)",
    r"\1                    swatch.picker.ColorChanged(&TypedEventHandler::<ColorPicker, "
    r"ColorChangedEventArgs>::new(move |_, _| {\n                        Ok(())\n"
    r"                    }))?;\n"),
    "does not open on the quiet")

# 28. WINUI: A TRANSLUCENT CHOICE ON AN OPAQUE PICKER STAYS TRANSLUCENT.
winui_color_watched("a WinUI opaque picker committing a translucent choice", gate.doctor(
    "the winui opaque landing", REAL[WINUI],
    r"(&& color\.a != 0xFF \{\n)(\s*)color\.a = 0xFF;\n", r"\1"),
    "lands a translucent choice")

# 29. WINUI: THE FLYOUT STOPS AT THE WINDOW'S EDGE.
winui_color_watched("a WinUI colour flyout constrained to the window", gate.doctor(
    "the flyout's bounds line", REAL[WINUI],
    r"        flyout\.SetShouldConstrainToRootBounds\(false\)\?;\n", ""),
    "constrained to the window")

def gtk_color_findings(source):
    """GTK's colour button (docs/color-picker-plan.md §4.3): the dialog's
    Select and a colour dropped on the swatch both end in the button's own
    set_rgba, so `notify::rgba` outside the quiet guard is the one door, and
    every programmatic set_rgba sits under the guard — the harness's
    set_color alone, which stands for the user."""
    out = []
    commit = block_after(source, "fn color_committed(")
    if not commit:
        return [f"{GTK}: fn color_committed is gone — the one commit path this "
                f"clause holds every door to"]
    emits = len(re.findall(r"\.send_color_tag\(", source))
    if emits != 1 or ".send_color_tag(" not in commit:
        out.append(f"{GTK}: send_color_tag is called {emits} time(s); the one call "
                   f"belongs inside color_committed")
    if not re.search(r"if picked == field\.held\.get\(\) \{\s*return;", commit):
        out.append(f"{GTK}: color_committed commits a colour equal to the held one — "
                   f"a choice that changes nothing emits nothing (§2)")
    if not re.search(r"if !field\.dialog\.is_with_alpha\(\) \{\s*picked\.a = 0xFF;", commit):
        out.append(f"{GTK}: color_committed no longer holds an opaque picker opaque — "
                   f"the button never reads with-alpha, so a translucent drop or "
                   f"set_color stays translucent (§4.3, §5 AMENDED)")
    arm = block_after(source, "WidgetKind::ColorPicker => {")
    door = block_after(arm, "connect_rgba_notify(")
    if not re.match(r"\{\s*if quiet\.get\(\) \{\s*return;\s*\}\s*color_committed\(", door):
        out.append(f"{GTK}: the colour button's notify::rgba handler does not open on "
                   f"the quiet guard — the notify fires for the app's own set_rgba (§4.3)")
    calls = len(re.findall(r"(?<!fn )color_committed\(", source))
    inside = len(re.findall(r"color_committed\(", door))
    if calls != 1 or inside != 1:
        out.append(f"{GTK}: color_committed is called {calls} time(s) and {inside} of "
                   f"them sit in the notify::rgba door — a commit anywhere else is "
                   f"an echo")
    drive = block_after(source, "fn set_color(&self")
    if ".set_rgba(" not in drive or "apply_quiet" in drive:
        out.append(f"{GTK}: set_color does not move the button's rgba outside the quiet "
                   f"guard — it must reach the notify door a Select reaches (§5)")
    lines = source.split("\n")
    for i, line in enumerate(lines):
        if ".set_rgba(" not in line or "core.color_pickers[i].button.set_rgba(" in line:
            continue
        before = "\n".join(lines[max(0, i - 2):i])
        if "replace(true)" not in before or ".set(was)" not in lines[i + 1]:
            out.append(f"{GTK}:{i + 1}: a set_rgba not under the quiet guard — the app's "
                       f"write would echo as a color_changed (§2)")
    return out


gate.counted("gtk colour set_rgba sites read",
             len(re.findall(r"\.set_rgba\(", REAL[GTK])), floor=4)


def gtk_color_watched(label, source, fragment):
    if not gate.negative(label, lambda: gtk_color_findings(source), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# G1. GTK: A SECOND EMIT.
gtk_color_watched("a GTK colour emitted outside color_committed", gate.doctor(
    "a second gtk emit", REAL[GTK],
    r"(                    field\.dialog\.set_with_alpha\(on\);\n)",
    r"\1                    core.occurrences.send_color_tag(&[], 0);\n"),
    "is called 2 time(s)")

# G2. GTK: THE APP'S WRITE WITHOUT THE QUIET GUARD.
gtk_color_watched("a GTK colour write with the quiet guard cut", gate.doctor(
    "the apply arm's guard", REAL[GTK],
    r"(                        field\.held\.set\(color\);\n)"
    r"\s*let was = core\.apply_quiet\.replace\(true\);\n",
    r"\1"),
    "a set_rgba not under the quiet guard")

# G3. GTK: THE NOTIFY DOOR WITHOUT ITS GUARD.
gtk_color_watched("a GTK notify::rgba handler with no quiet check", gate.doctor(
    "the notify door's guard", REAL[GTK],
    r"(connect_rgba_notify\(move \|_\| \{\n)\s*if quiet\.get\(\) \{\n\s*return;\n\s*\}\n",
    r"\1"),
    "does not open on the quiet guard")

# G4. GTK: A COMMIT FROM THE APPLY ARM.
gtk_color_watched("a GTK colour committed from the alpha arm", gate.doctor(
    "a commit in the alpha arm", REAL[GTK],
    r"(                    field\.dialog\.set_with_alpha\(on\);\n)",
    r"\1                    color_committed(field, &core.apply_quiet, &core.occurrences, &[]);\n"),
    "sit in the notify::rgba door")

# G5. GTK: THE SAME COLOUR COMMITS AGAIN.
gtk_color_watched("a GTK commit of the held colour", gate.doctor(
    "the gtk held compare", REAL[GTK],
    r"if picked == field\.held\.get\(\) \{", "if false {"),
    "equal to the held one")

# G6. GTK: AN OPAQUE PICKER KEEPS A TRANSLUCENT CHOICE.
gtk_color_watched("a GTK opaque picker committing a translucent choice", gate.doctor(
    "the gtk opaque landing", REAL[GTK],
    r"(if !field\.dialog\.is_with_alpha\(\) \{\n)(\s*)picked\.a = 0xFF;\n", r"\1"),
    "no longer holds an opaque picker opaque")

# G7. GTK: set_color UNDER THE GUARD, SO IT NEVER REACHES THE DOOR.
gtk_color_watched("a GTK set_color written quietly", gate.doctor(
    "the drive under the guard", REAL[GTK],
    r"(\s*)core\.color_pickers\[i\]\.button\.set_rgba\(&rgba_of\(color\)\);",
    r"\1core.apply_quiet.set(true);\1core.color_pickers[i].button.set_rgba(&rgba_of(color));"),
    "set_color does not move")

# THE RANGE IS THE SAME RULE TWICE (docs/range-plan.md §3 rules 2, 3, 8):
# `set_value range#0 low 3.2` is one finished gesture by construction, so an
# arm committing the pair on every drag event, or skipping the clamp on a
# path the scene never drives (a drag, VoiceOver's adjust), passes
# tools/scenes/range.steps byte for byte. The mac assistive set arrives as
# the thumb's action (measured §4.2), so the action's target is that door.
def swiftui_range_findings(source):
    out = []
    moved = block_after(source, "func kayaRangeMoved(")
    if not moved:
        return [f"{SWIFTUI}: func kayaRangeMoved is gone — the one commit path "
                f"this clause holds both thumbs' doors to"]
    if "KayaHost.rangeClamp(" not in moved or "if v != raw { restore(v) }" not in moved:
        out.append(f"{SWIFTUI}: kayaRangeMoved no longer clamps through the core and "
                   f"writes the answer back — a thumb could rest past the other (§3 rule 2)")
    emits = len(re.findall(r"KayaHost\.emitRange\(", source))
    if emits != 2 or moved.count("KayaHost.emitRange(") != 2:
        out.append(f"{SWIFTUI}: KayaHost.emitRange is called {emits} time(s); both calls "
                   f"belong inside kayaRangeMoved, so no path publishes a pair past it")
    settled = block_after(
        moved, "if final && (lo != node.committedLow || hi != node.committedHigh)")
    if "committed: true" not in settled:
        out.append(f"{SWIFTUI}: kayaRangeMoved commits a pair equal to the last settled one, "
                   f"or commits without a finished gesture (§2)")
    changed = block_after(source, "@objc func changed(_ sender: KayaRangeThumb)")
    if "let final = type != .leftMouseDown && type != .leftMouseDragged" not in changed:
        out.append(f"{SWIFTUI}: the mac thumb's action no longer tells a drag from its end — "
                   f"a drag would commit on every event")
    if "thumb.action = #selector(changed(_:))" not in source:
        out.append(f"{SWIFTUI}: the mac thumbs' action is not the range's changed — the "
                   f"assistive set, which arrives as that action (§4.2), would skip the clamp")
    thumb_ios = block_after(source, "final class KayaRangeThumbSlider: UISlider")
    for piece in ("override func accessibilityIncrement() { range?.nudge(self, by: 1) }",
                  "override func accessibilityDecrement() { range?.nudge(self, by: -1) }"):
        if piece not in thumb_ios:
            out.append(f"{SWIFTUI}: the iOS thumb lacks `{piece}` — VoiceOver's adjust "
                       f"would move the UISlider past the clamp and commit nothing (§3 rules 3, 8)")
    # §3 rule 9, measured §4.2 2026-09-29: an empty track IMAGE turns UIKit's
    # Liquid Glass thumb back into the legacy round knob, so the native track
    # is hidden by a clear TINT and nothing in the arm sets an image or a
    # thumb tint. No scene can see a knob's shape.
    track_ios = "".join(block_after(source, a) for a in (
        "final class KayaRangeTrack: UIView", "final class KayaRangeThumbSlider: UISlider"))
    for piece in ("thumb.minimumTrackTintColor = .clear", "thumb.maximumTrackTintColor = .clear"):
        if piece not in track_ios:
            out.append(f"{SWIFTUI}: the iOS range no longer hides its thumbs' track with "
                       f"`{piece}` — the native track would draw under kaya's (§3 rule 9)")
    hit = re.search(r"set(?:Minimum|Maximum)TrackImage|setThumbImage|thumbTintColor", track_ios)
    if hit:
        out.append(f"{SWIFTUI}: the iOS range arm calls `{hit.group(0)}` — an image or thumb tint "
                   f"restyles the platform's thumb (the legacy knob, measured §4.2)")
    doors = [changed, thumb_ios]
    for anchor in ("@objc func moved(_ sender: KayaRangeThumbSlider)",
                   "@objc func released(_ sender: KayaRangeThumbSlider)"):
        doors.append(block_after(source, anchor))
    for anchor in ("func nudge(_ thumb: KayaRangeThumb, by direction: Double)",
                   "func nudge(_ thumb: KayaRangeThumbSlider, by direction: Double)"):
        doors.append(block_after(source, anchor))
    at = 0
    while True:
        at = source.find("func kayaDriveThumb(", at)
        if at < 0:
            break
        doors.append(block_after(source[at:], "func kayaDriveThumb("))
        at += 1
    calls = len(re.findall(r"(?<!func )kayaRangeMoved\(", source))
    inside = sum(len(re.findall(r"kayaRangeMoved\(", d)) for d in doors)
    if calls != inside:
        out.append(f"{SWIFTUI}: kayaRangeMoved is called {calls} time(s) and {inside} of "
                   f"them sit in a door (the mac action, the iOS move and release, a key, "
                   f"set_value's drive) — a move anywhere else is no user's")
    return out


gate.counted("swiftui range commit-path calls read",
             len(re.findall(r"(?<!func )kayaRangeMoved\(", SWIFT_SOURCE)), floor=7)


def range_watched(label, source, fragment):
    if not gate.negative(label, lambda: swiftui_range_findings(source), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# R1. A PAIR COMMITTED AGAIN, or at every movement.
range_watched("a range committing the settled pair again", gate.doctor(
    "the settled-pair compare", SWIFT_SOURCE,
    r"if final && \(lo != node\.committedLow \|\| hi != node\.committedHigh\) \{",
    "if final {"), "equal to the last settled one")

# R2. THE MAC ACTION CALLS EVERY DRAG EVENT FINAL.
range_watched("a mac thumb committing every drag event", gate.doctor(
    "the drag test", SWIFT_SOURCE,
    r"(@objc func changed\(_ sender: KayaRangeThumb\) \{\n(?:.*\n){2})"
    r"(\s*)let final = type != \.leftMouseDown && type != \.leftMouseDragged\n",
    r"\1\2let final = true\n"), "tells a drag from its end")

# R3. AN EMIT PAST THE COMMIT PATH.
range_watched("a range pair emitted outside kayaRangeMoved", gate.doctor(
    "a third emit", SWIFT_SOURCE,
    r"(@objc func changed\(_ sender: KayaRangeThumb\) \{\n)",
    r"\1            if let node { KayaHost.emitRange(node.tag, node.low, node.high, "
    r"committed: true) }\n"),
    "is called 3 time(s)")

# R4. THE CLAMP'S ANSWER NOT WRITTEN BACK.
range_watched("a clamp whose answer stays out of the control", gate.doctor(
    "the write-back", SWIFT_SOURCE,
    r"    if v != raw \{ restore\(v\) \}\n(    let \(lo, hi\) = low)", r"\1"),
    "writes the answer back")

# R5. THE iOS ASSISTIVE ADJUST LEFT TO UIKIT.
range_watched("an iOS thumb whose VoiceOver increment skips the clamp", gate.doctor(
    "the assistive increment", SWIFT_SOURCE,
    r"        override func accessibilityIncrement\(\) \{ range\?\.nudge\(self, by: 1\) \}\n", ""),
    "VoiceOver's adjust")

# R6. THE MAC THUMBS' ACTION ROUTED AWAY, taking the assistive set with it.
range_watched("a mac thumb whose action is not the range's", gate.doctor(
    "the thumbs' action", SWIFT_SOURCE,
    r"thumb\.action = #selector\(changed\(_:\)\)", "thumb.action = nil"),
    "the assistive set")

# R9. THE iOS TRACK HIDDEN BY AN EMPTY IMAGE, the shipped depth shape.
range_watched("an iOS range hiding its track with an empty image", gate.doctor(
    "the clear minimum tint", SWIFT_SOURCE,
    r"thumb\.minimumTrackTintColor = \.clear",
    "thumb.setMinimumTrackImage(UIImage(), for: .normal)"), "restyles the platform's thumb")

# R7. A MOVE OUTSIDE EVERY DOOR.
range_watched("a range moved from the surface's apply", gate.doctor(
    "a move in apply", SWIFT_SOURCE,
    r"(            high\.doubleValue = node\.high\n)",
    r"\1            kayaRangeMoved(node, low: true, node.low, final: true) { _ in }\n"),
    "sit in a door")

# THE WINUI RANGE (docs/range-plan.md §3 rules 2, 3, 8, §6): both thumbs are
# the slider arm's own door twice — ValueChanged, final only with no button
# down, and PointerCaptureLost — into ONE path, winui_range_moved, which clamps
# through the core, writes the answer back into the thumb's slider and sends
# the pair. UIA's RangeValue.SetValue (Narrator) arrives as ValueChanged, so
# the handler IS the assistive door; `set_value` drives one finished gesture,
# so none of this is visible to tools/scenes/range.steps.
def winui_range_findings(source):
    out = []
    moved = block_after(source, "fn winui_range_moved(")
    if not moved:
        return [f"{WINUI}: fn winui_range_moved is gone — the one commit path this "
                f"clause holds both thumbs' doors to"]
    if not re.search(r"let v = crate::range::clamp_thumb\(", moved) or not re.search(
            r"if v != raw \{\s*quiet\.store\(true[^;]*;\s*let write = slider\.SetValue\(v\);",
            moved):
        out.append(f"{WINUI}: winui_range_moved no longer clamps through the core and "
                   f"writes the answer back into the thumb's slider — a thumb could rest "
                   f"past the other (§3 rules 2, 8)")
    if not re.search(r"write\?;\s*winui_range_relay_thumb\(slider, v, raw, quiet\);", moved):
        out.append(f"{WINUI}: winui_range_moved writes the clamp back without re-laying the "
                   f"thumb — the Slider draws a write-back made inside ValueChanged at the "
                   f"raised value (docs/traps.md, measured 2026-09-29)")
    emits = len(re.findall(r"\.send_range_tag\(", source))
    if emits != 2 or moved.count(".send_range_tag(") != 2:
        out.append(f"{WINUI}: send_range_tag is called {emits} time(s); both calls belong "
                   f"inside winui_range_moved, so no path publishes a pair past it")
    if not re.search(r"let settled = final_\s*&& \(nlo, nhi\)\s*!= \(SliderCell::get\("
                     r"&cell\.committed_low\), SliderCell::get\(&cell\.committed_high\)\);",
                     moved):
        out.append(f"{WINUI}: winui_range_moved commits a pair equal to the last committed "
                   f"one, or commits without a finished gesture (§2)")
    pair = block_after(source, "impl RangePair {")
    changed = block_after(pair, "thumb.ValueChanged(&RangeBaseValueChangedEventHandler::new(")
    released = block_after(pair, "thumb.PointerCaptureLost(&PointerEventHandler::new(")
    for door, name, final in ((changed, "ValueChanged", "!pointer_button_down()"),
                              (released, "PointerCaptureLost", "true")):
        if not door:
            out.append(f"{WINUI}: a range thumb registers no {name} handler — "
                       f"{'every move, UIA included,' if final != 'true' else 'a drag'} "
                       f"would never reach the clamp")
            continue
        if not re.match(r"\{\s*if \w+\.load\(std::sync::atomic::Ordering::Relaxed\) \{\s*"
                        r"return Ok\(\(\)\);", door):
            out.append(f"{WINUI}: the range's {name} handler does not open on the quiet "
                       f"guard — the app's own write and the clamp's write-back would commit")
        call = re.search(r"winui_range_moved\(\s*&slider,\s*&cell,\s*low,\s*&\w+,\s*&\w+,\s*"
                         r"(.+?),?\s*\)\?;", door, re.S)
        if call is None or call.group(1).strip() != final:
            got = call.group(1).strip() if call else "no call at all"
            out.append(f"{WINUI}: the range's {name} handler moves the thumb with `{got}` — "
                       f"it must be `{final}`, or a drag commits on every movement or its "
                       f"release commits nothing")
    step = block_after(source, "fn arrow_step(")
    if "PostMessageW(site, WM_KEYDOWN" not in step or "keybd_event" in step:
        out.append(f"{WINUI}: the slider's arrow step does not post its key to the focus "
                   f"window — a key on the system input queue goes to whichever pooled "
                   f"guest holds the foreground (docs/traps.md, measured 2026-09-29)")
    doors = [changed, released, block_after(source, "fn set_thumb(")]
    calls = len(re.findall(r"(?<!fn )winui_range_moved\(", source))
    inside = sum(len(re.findall(r"winui_range_moved\(", d)) for d in doors)
    if calls != inside:
        out.append(f"{WINUI}: winui_range_moved is called {calls} time(s) and {inside} of "
                   f"them sit in a door (a thumb's ValueChanged, its PointerCaptureLost, "
                   f"set_value's drive) — a move anywhere else is no user's")
    return out


gate.counted("winui range door calls read",
             len(re.findall(r"(?<!fn )winui_range_moved\(", REAL[WINUI])), floor=3)


def winui_range_watched(label, source, fragment):
    if not gate.negative(label, lambda: winui_range_findings(source), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# W1. THE CLAMP'S ANSWER NOT WRITTEN BACK.
winui_range_watched("a WinUI clamp whose answer stays out of the slider", gate.doctor(
    "the winui range write-back", REAL[WINUI],
    r"let write = slider\.SetValue\(v\);(?=[^}]*\}\s*if moved \{\s*sink\.send_range_tag)",
    "let write = slider.SetValue(raw);"),
    "writes the answer back")
# W2. THE PAIR COMMITTED AGAIN.
winui_range_watched("a WinUI range committing the settled pair again", gate.doctor(
    "the winui settled-pair compare", REAL[WINUI],
    r"(let settled = final_)\s*&& \(nlo, nhi\)\s*!= \(SliderCell::get\(&cell\.committed_low\), "
    r"SliderCell::get\(&cell\.committed_high\)\);", r"\1;"),
    "equal to the last committed")
# W3. A DRAG'S EVERY MOVEMENT FINAL.
winui_range_watched("a WinUI range thumb committing every drag event", gate.doctor(
    "the winui range drag test", REAL[WINUI],
    r"(&moved_sink,\s*)!pointer_button_down\(\),", r"\1true,"),
    "ValueChanged handler moves the thumb with `true`")
# W4. A MOVE FROM THE APP'S OWN WRITE.
winui_range_watched("a WinUI range moved from the apply arm", gate.doctor(
    "a move in winui_range_write", REAL[WINUI],
    r"(    let write = pair\.slider\(low\)\.SetValue\(value\);\n)",
    r"\1    winui_range_moved(pair.slider(low), &pair.cell, low, quiet, &sink, true)?;\n"),
    "sit in a door")
# W5. THE QUIET GUARD CUT from a thumb's ValueChanged.
winui_range_watched("a WinUI range ValueChanged with no quiet guard", gate.doctor(
    "the winui range quiet guard", REAL[WINUI],
    r"(move \|sender, _: windows_core::Ref<'_, RangeBaseValueChangedEventArgs>\| \{\n)"
    r"\s*if moved_quiet\.load\([^)]*\) \{\n"
    r"\s*return Ok\(\(\)\);\n\s*\}\n", r"\1"),
    "does not open on the quiet")
# W7. THE THUMB LEFT WHERE THE RAISED VALUE WAS.
winui_range_watched("a WinUI write-back with no thumb re-lay", gate.doctor(
    "the winui range re-lay", REAL[WINUI],
    r"\n\s*winui_range_relay_thumb\(slider, v, raw, quiet\);", ""),
    "without re-laying the thumb")
# W8. THE ARROW BACK ON THE SYSTEM QUEUE.
winui_range_watched("a WinUI arrow step typed on the system input queue", gate.doctor(
    "the winui range arrow route", REAL[WINUI],
    r"PostMessageW\(site, WM_KEYDOWN, key, ([^;]*)\);",
    r"keybd_event(key as u8, 0, 0, 0);"),
    "does not post its key to the focus")
# W6. A THIRD SEND.
winui_range_watched("a WinUI range pair sent outside winui_range_moved", gate.doctor(
    "a third winui range send", REAL[WINUI],
    r"(    SliderCell::set\(held, value\);\n)",
    r"\1    sink.send_range_tag(&cell.tag, value, value, true);\n"),
    "is called 3 time(s)")

# THE COMPOSE RANGE (docs/range-plan.md §3 rules 2, 3, 8, §6): Material's own
# RangeSlider hands every value back through onValueChange, a drag's, a tap's
# and an assistive setProgress's alike, and calls onValueChangeFinished at a
# gesture's end and after setProgress (measured §4). So every onValueChange
# goes through kayaRangeMoved, which clamps through the core's JNI and holds
# the answer in the node the control draws from, and the ONE commit is
# kayaRangeSettled behind onValueChangeFinished. The scene's set_value takes
# the setProgress door, so a drag committing per movement passes it.
def compose_range_findings(source):
    out = []
    moved = block_after(source, "internal fun kayaRangeMoved(")
    settled = block_after(source, "internal fun kayaRangeSettled(")
    changed = block_after(source, "internal fun kayaRangeChanged(")
    surface = block_after(source, "private fun KayaRangeSurface(")
    if not (moved and settled and changed and surface):
        return [f"{COMPOSE}: kayaRangeMoved, kayaRangeSettled, kayaRangeChanged or "
                f"KayaRangeSurface is gone — the one path this clause holds is not there"]
    if not re.search(r"val v = KayaPresent\.rangeClamp\(", moved) or not re.search(
            r"node\.low = lo\s+node\.high = hi", moved):
        out.append(f"{COMPOSE}: kayaRangeMoved no longer clamps through the core and holds "
                   f"the answer in the node — a thumb could rest past the other (§3 rule 2)")
    if "value = node.low.toFloat()..node.high.toFloat()," not in surface:
        out.append(f"{COMPOSE}: the RangeSlider no longer draws the clamped pair from the "
                   f"node — the clamp's answer never reaches the control (the write-back)")
    emits = re.findall(r"KayaPresent\.emitRange\(([^\n]*)\)", source)
    live = [e for e in emits if e.endswith("false")]
    final = [e for e in emits if e.endswith("true")]
    if (len(emits) != 2 or len(live) != 1 or len(final) != 1
            or "KayaPresent.emitRange(node.tag, lo, hi, false)" not in moved
            or "KayaPresent.emitRange(node.tag, node.low, node.high, true)" not in settled):
        out.append(f"{COMPOSE}: KayaPresent.emitRange is called {len(emits)} time(s); the live "
                   f"one belongs in kayaRangeMoved and the committed one in kayaRangeSettled, "
                   f"so no path publishes a pair past them")
    if not re.search(r"if \(node\.low != node\.committedLow \|\| "
                     r"node\.high != node\.committedHigh\)", settled):
        out.append(f"{COMPOSE}: kayaRangeSettled commits a pair equal to the last settled "
                   f"one (§2)")
    for name, door, where in (
            ("kayaRangeChanged", "onValueChange = { kayaRangeChanged(node, it) },",
             "the RangeSlider's onValueChange"),
            ("kayaRangeSettled", "onValueChangeFinished = { kayaRangeSettled(node) },",
             "the RangeSlider's onValueChangeFinished")):
        calls = len(re.findall(rf"(?<!fun ){name}\(", source))
        if door not in surface or calls != 1:
            out.append(f"{COMPOSE}: {name} is called {calls} time(s) and must be called once, "
                       f"from {where} — anything else is a commit or a move no user made")
    calls = len(re.findall(r"(?<!fun )kayaRangeMoved\(", source))
    if calls != 2 or changed.count("kayaRangeMoved(") != 2:
        out.append(f"{COMPOSE}: kayaRangeMoved is called {calls} time(s); both calls belong in "
                   f"kayaRangeChanged, the onValueChange every value arrives through")
    return out


gate.counted("compose range door calls read",
             len(re.findall(r"(?<!fun )kayaRange(?:Moved|Settled|Changed)\(", REAL[COMPOSE])),
             floor=4)


def compose_range_watched(label, source, fragment):
    if not gate.negative(label, lambda: compose_range_findings(source), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# K1. THE PAIR COMMITTED AGAIN.
compose_range_watched("a Compose range committing the settled pair again", gate.doctor(
    "the compose settled-pair compare", REAL[COMPOSE],
    r"if \(node\.low != node\.committedLow \|\| node\.high != node\.committedHigh\) \{",
    "if (true) {"), "equal to the last settled")
# K2. EVERY MOVEMENT COMMITTED.
compose_range_watched("a Compose range committing on every movement", gate.doctor(
    "a commit in kayaRangeMoved", REAL[COMPOSE],
    r"(        KayaPresent\.emitRange\(node\.tag, lo, hi, false\)\n)",
    r"\1        KayaPresent.emitRange(node.tag, lo, hi, true)\n"),
    "emitRange is called 3 time(s)")
# K3. THE CLAMP SKIPPED.
compose_range_watched("a Compose range move skipping the core's clamp", gate.doctor(
    "the compose clamp", REAL[COMPOSE],
    r"val v = KayaPresent\.rangeClamp\(", "val v = raw; listOf("),
    "no longer clamps through the core")
# K4. THE CLAMP'S ANSWER NOT WHAT THE CONTROL DRAWS.
compose_range_watched("a Compose RangeSlider drawing the committed pair", gate.doctor(
    "the compose write-back", REAL[COMPOSE],
    r"value = node\.low\.toFloat\(\)\.\.node\.high\.toFloat\(\),",
    "value = node.committedLow.toFloat()..node.committedHigh.toFloat(),"),
    "draws the clamped pair")
# K5. A COMMIT FROM onValueChange.
compose_range_watched("a Compose range committing from onValueChange", gate.doctor(
    "a commit in onValueChange", REAL[COMPOSE],
    r"onValueChange = \{ kayaRangeChanged\(node, it\) \},",
    "onValueChange = { kayaRangeChanged(node, it); kayaRangeSettled(node) },"),
    "kayaRangeSettled is called 2 time(s)")
# K6. A VALUE PAST THE CLAMP.
compose_range_watched("a Compose onValueChange writing the node itself", gate.doctor(
    "onValueChange past the path", REAL[COMPOSE],
    r"onValueChange = \{ kayaRangeChanged\(node, it\) \},",
    "onValueChange = { node.low = it.start.toDouble() },"),
    "kayaRangeChanged is called 0 time(s)")
# K7. AN APP WRITE ECHOED.
compose_range_watched("a Compose app write echoing as a move", gate.doctor(
    "an echo in the low prop arm", REAL[COMPOSE],
    r"(                            node\.committedLow = node\.low\n)",
    r"\1                            kayaRangeMoved(node, low = true, raw = node.low)\n"),
    "kayaRangeMoved is called 3 time(s)")

# THE GTK RANGE (docs/range-plan.md §3 rules 2, 3, 8, §4 MEASURED): each
# thumb's `value-changed` is the door every path reaches — a drag, a press on
# the track, a key, an AT-SPI Value set (Orca's route, measured arriving
# there) — and it moves the pair through ONE path, range_moved, settled only
# while no pointer is down; the capture-phase release is the drag's commit,
# the slider's door. set_value drives one finished gesture, so none of this
# is visible to tools/scenes/range.steps.
def gtk_range_findings(source):
    out = []
    moved = block_after(source, "fn range_moved(")
    if not moved:
        return [f"{GTK}: fn range_moved is gone — the one commit path this clause holds "
                f"both thumbs' doors to"]
    if not re.search(r"let v = crate::range::clamp_thumb\(", moved) or not re.search(
            r"if v != raw \{\s*let was = quiet\.replace\(true\);\s*thumb\.set_value\(v\);"
            r"\s*quiet\.set\(was\);", moved):
        out.append(f"{GTK}: range_moved no longer clamps through the core and writes the "
                   f"answer back into the thumb's scale under the quiet guard — a thumb "
                   f"could rest past the other (§3 rules 2, 8)")
    sends = len(re.findall(r"\.send_range_tag\(", source))
    if sends != 2 or moved.count(".send_range_tag(") != 2:
        out.append(f"{GTK}: send_range_tag is called {sends} time(s); both calls belong "
                   f"inside range_moved, so no path publishes a pair past it")
    settled = block_after(
        moved, "if settled && (lo, hi) != (st.committed_low, st.committed_high)")
    if not re.search(r"gtk_user_range_committed\(tag, lo, hi\);\s*"
                     r"sink\.send_range_tag\(tag, lo, hi, true\);", settled):
        out.append(f"{GTK}: range_moved commits a pair equal to the last committed one, "
                   f"commits without a finished gesture, or sends it before the core's "
                   f"pair follows the user (§2, §3 rule 11)")
    arm = block_after(source, "WidgetKind::Range => {")
    changed = block_after(arm, "thumb.connect_value_changed(")
    released = block_after(arm, "pointer.connect_event(")
    if not re.search(r"\{\s*pair\.group\.queue_allocate\(\);\s*if quiet\.get\(\) \{\s*"
                     r"return;\s*\}", changed):
        out.append(f"{GTK}: a range thumb's value-changed handler does not open on the "
                   f"quiet guard — the app's own write and the clamp's write-back would "
                   f"commit")
    if not re.search(r"let settled = !pair\.state\.get\(\)\.dragging;\s*"
                     r"range_moved\(&pair, low, &quiet, &sink, &tag, settled\);", changed):
        out.append(f"{GTK}: a range thumb's value-changed no longer moves the pair settled "
                   f"only while no pointer is down — a drag would commit on every movement")
    if not re.search(r"gdk::EventType::ButtonRelease[^}]*state\.dragging = false;[^}]*"
                     r"range_moved\(&pair, low, &quiet, &sink, &tag, true\);", released):
        out.append(f"{GTK}: a range thumb's release no longer commits the pair — a drag "
                   f"would never commit")
    doors = [changed, released]
    calls = len(re.findall(r"(?<!fn )range_moved\(", source))
    inside = sum(len(re.findall(r"range_moved\(", d)) for d in doors)
    if calls != inside:
        out.append(f"{GTK}: range_moved is called {calls} time(s) and {inside} of them "
                   f"sit in a door (a thumb's value-changed, its release) — a move "
                   f"anywhere else is no user's")
    drive = block_after(source, "fn set_thumb(&self")
    if (not re.search(r"scale\.set_value\(value\);\s*scale\.emit_by_name::<\(\)>"
                      r"\(\"value-changed\", &\[\]\);", drive) or "apply_quiet" in drive):
        out.append(f"{GTK}: set_value on a range no longer moves the thumb's scale outside "
                   f"the quiet guard — it must reach the door a user's move reaches (§5)")
    write = block_after(source, "(NativeWidget::Range(pair), Prop::High, Value::F64(v)) =>")
    if not re.search(r"let was = core\.apply_quiet\.replace\(true\);\s*"
                     r"pair\.thumb\(low\)\.set_value\(v\);\s*core\.apply_quiet\.set\(was\);",
                     write):
        out.append(f"{GTK}: the app's low/high write does not move the thumb under the quiet "
                   f"guard — it would echo as a user's move (§2)")
    return out


gate.counted("gtk range door calls read",
             len(re.findall(r"(?<!fn )range_moved\(", REAL[GTK])), floor=2)


def gtk_range_watched(label, source, fragment):
    if not gate.negative(label, lambda: gtk_range_findings(source), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# T1. THE CLAMP'S ANSWER NOT WRITTEN BACK.
gtk_range_watched("a GTK clamp whose answer stays out of the scale", gate.doctor(
    "the gtk range write-back", REAL[GTK],
    r"(if v != raw \{\s*let was = quiet\.replace\(true\);\s*)thumb\.set_value\(v\);",
    r"\1thumb.set_value(raw);"),
    "writes the answer back")
# T2. THE PAIR COMMITTED AGAIN.
gtk_range_watched("a GTK range committing the settled pair again", gate.doctor(
    "the gtk settled-pair compare", REAL[GTK],
    r"if settled && \(lo, hi\) != \(st\.committed_low, st\.committed_high\) \{",
    "if settled {"),
    "equal to the last committed")
# T3. THE CORE'S PAIR LEFT BEHIND THE USER (§3 rule 11).
gtk_range_watched("a GTK commit sent before the core's pair follows", gate.doctor(
    "the gtk user_range_committed call", REAL[GTK],
    r"        gtk_user_range_committed\(tag, lo, hi\);\n", ""),
    "follows the user")
# T4. A DRAG'S EVERY MOVEMENT FINAL.
gtk_range_watched("a GTK range thumb committing every drag event", gate.doctor(
    "the gtk range drag test", REAL[GTK],
    r"let settled = !pair\.state\.get\(\)\.dragging;", "let settled = true;"),
    "settled only while no pointer is down")
# T5. THE QUIET GUARD CUT from a thumb's value-changed.
gtk_range_watched("a GTK range value-changed with no quiet guard", gate.doctor(
    "the gtk range quiet guard", REAL[GTK],
    r"(pair\.group\.queue_allocate\(\);\n)\s*if quiet\.get\(\) \{\n\s*return;\n\s*\}\n"
    r"(?=(?:\s*//[^\n]*\n)*\s*let settled = !pair)",
    r"\1"),
    "does not open on the quiet guard")
# T6. THE RELEASE NO LONGER COMMITS.
gtk_range_watched("a GTK range whose release commits nothing", gate.doctor(
    "the gtk range release commit", REAL[GTK],
    r"range_moved\(&pair, low, &quiet, &sink, &tag, true\);",
    "let _ = (&pair, &quiet, &sink, &tag);"),
    "release no longer commits")
# T7. A MOVE FROM THE APP'S OWN WRITE.
gtk_range_watched("a GTK range moved from the apply arm", gate.doctor(
    "a move in the range's low/high arm", REAL[GTK],
    r"(                    pair\.thumb\(low\)\.set_value\(v\);\n)",
    r"\1                    range_moved(pair, low, &core.apply_quiet, &core.occurrences, "
    r"&[], true);\n"),
    "sit in a door")
# T8. THE APP'S WRITE ECHOING.
gtk_range_watched("a GTK range low/high write outside the quiet guard", gate.doctor(
    "the gtk range apply guard", REAL[GTK],
    r"let was = core\.apply_quiet\.replace\(true\);\n(\s*pair\.thumb\(low\)\.set_value\(v\);)"
    r"\n\s*core\.apply_quiet\.set\(was\);", r"\1"),
    "under the quiet guard")
# T9. set_value WRITTEN QUIETLY, SO IT NEVER REACHES THE DOOR.
gtk_range_watched("a GTK set_thumb under the quiet guard", gate.doctor(
    "the gtk drive under the guard", REAL[GTK],
    r"(let scale = core\.ranges\[i\]\.thumb\(thumb == crate::harness::Thumb::Low\)\.clone\(\);)"
    r"(\s*)scale\.set_value\(value\);",
    r"\1\2core.apply_quiet.set(true);\2scale.set_value(value);"),
    "outside the quiet guard")

# A PRESS GOES TO A THUMB BY GEOMETRY, NEVER BY Z-ORDER (docs/range-plan.md
# §3 rule 4; the survey's most reported failure, docs/probes/
# range-sliders-2026-09-29.md). No scene can see it: set_value drives a
# thumb's control directly, so an arm routing by whichever slider is on top
# passes tools/scenes/range.steps byte for byte. One row per STACKED backend
# (two native sliders over one drawn track), each naming:
#   split  — the anchor of the block that decides which thumb a press takes,
#            and the regexes that block must hold: both thumbs' positions,
#            their MIDPOINT, and the tie's own branch;
#   press  — the anchor chain to the PRESS-DOWN site (the tie is decided
#            there, when a native slider starts tracking, never on a move),
#            and the regexes it must hold: the split called with both
#            thumbs' positions read at that moment;
#   arm    — the anchors of every block of the range arm, none of which may
#            name one of `zorder`'s APIs (reordering the two sliders is the
#            forbidden route, whatever the toolkit calls it).
SWIFT_ZORDER = [r"bringSubviewToFront", r"sendSubviewToBack", r"exchangeSubview",
                r"insertSubview\([^)]*\b(?:above|below|aboveSubview|belowSubview)\b",
                r"addSubview\([^)]*positioned:", r"sortSubviews", r"zPosition",
                r"\.zIndex\("]
SWIFT_SPLIT = ("func kayaRangeLowTakes(",
               [(r"lowCentre", "the low thumb's position"),
                (r"highCentre", "the high thumb's position"),
                (r"\(lowCentre \+ highCentre\) / 2", "their midpoint"),
                (r"if abs\(highCentre - lowCentre\) < 0\.5 \{ return ", "the tie's branch"),
                (r"lowCentre < highCentre \? x < mid : x > mid",
                 "which side of the midpoint the low thumb is on (mirrored under RTL)")])
ROUTING = {
    "SwiftUI macOS": {
        "path": SWIFTUI,
        "split": SWIFT_SPLIT,
        "press": (("final class KayaRangeView: NSView", "override func hitTest("),
                  [(r"kayaRangeLowTakes\(", "the split"),
                   (r"lowCentre: centre\(low\)\.x", "the low knob's centre"),
                   (r"highCentre: centre\(high\)\.x", "the high knob's centre"),
                   (r"minAtLeft: low\.userInterfaceLayoutDirection == \.leftToRight",
                    "the slider's own direction")]),
        "arm": ["final class KayaRangeView: NSView", "final class KayaRangeThumb: NSSlider",
                "struct KayaRangeSurface: NSViewRepresentable"],
        "zorder": SWIFT_ZORDER,
    },
    "SwiftUI iOS": {
        "path": SWIFTUI,
        "split": SWIFT_SPLIT,
        "press": (("final class KayaRangeTrack: UIView", "override func hitTest("),
                  [(r"kayaRangeLowTakes\(", "the split"),
                   (r"lowCentre: low\.centreX", "the low thumb's centre"),
                   (r"highCentre: high\.centreX", "the high thumb's centre"),
                   (r"minAtLeft: low\.effectiveUserInterfaceLayoutDirection == \.leftToRight",
                    "the slider's own direction")]),
        "arm": ["final class KayaRangeTrack: UIView", "final class KayaRangeThumbSlider: UISlider",
                "struct KayaRangeSurface: UIViewRepresentable"],
        "zorder": SWIFT_ZORDER,
    },
    # WinUI routes by CLIPPING each slider to its half (measured 2026-09-29,
    # docs/range-plan.md §4): hit testing honours UIElement.Clip, so the clip
    # set after every layout IS the press-down decision. Its coordinates are
    # the slider's own, which flow right to left with it (measured), so the
    # split needs no direction of its own.
    "WinUI": {
        "path": WINUI,
        "split": ("fn winui_range_split(",
                  [(r"low_centre", "the low thumb's position"),
                   (r"high_centre", "the high thumb's position"),
                   (r"\(low_centre \+ high_centre\) / 2\.0", "their midpoint"),
                   (r"if \(high_centre - low_centre\)\.abs\(\) < 0\.5 \{\s*low_centre",
                    "the tie's branch")]),
        "press": (("fn winui_range_layout(",),
                  [(r"winui_range_split\(lx \+ lw / 2\.0, hx \+ hw / 2\.0\)", "the split"),
                   (r"let within: UIElement = pair\.low\.cast\(\)\?;\s*"
                    r"let \(lx, _, lw, _\) = box_in\(&low_thumb, &within\)\?;",
                    "the low thumb's box in the slider's own space"),
                   (r"let \(hx, _, hw, _\) = box_in\(&high_thumb, &within\)\?;\s*let split",
                    "the high thumb's box in the slider's own space"),
                   (r"let low_width = if tied \{ width \} else \{ split \};\s*"
                    r"for \(slider, x, w\) in \[\(&pair\.low, 0\.0, low_width\), "
                    r"\(&pair\.high, split, width - split\)\]",
                    "each thumb's own side of the split (low whole under high's half at a tie)"),
                   (r"slider\.SetClip\(&clip\)\?;", "the clip that hit testing honours")]),
        "arm": ["impl RangePair {", "fn winui_range_shape(", "fn winui_range_write(",
                "fn winui_range_moved(", "fn winui_range_layout("],
        "zorder": [r"ZIndex", r"\.Move\(", r"\.InsertAt\(", r"\.RemoveAt\(",
                   r"\.IndexOf\("],
    },
    # GTK routes at the PICK (measured 2026-09-29, docs/range-plan.md §4): a
    # thumb's `contains` answers its own half, which GTK asks only because the
    # thumb's own parts are untargetable (gtk_range_parts_findings holds that
    # half). A press's pick is at press-down, a mouse's through the last
    # motion's pick at the same point, a touch's at TOUCH_BEGIN.
    "GTK": {
        "path": GTK,
        "split": ("fn range_low_takes(",
                  [(r"low_centre", "the low thumb's position"),
                   (r"high_centre", "the high thumb's position"),
                   (r"\(low_centre \+ high_centre\) / 2\.0", "their midpoint"),
                   (r"if \(high_centre - low_centre\)\.abs\(\) < 0\.5 \{\s*return ",
                    "the tie's branch"),
                   (r"if low_centre < high_centre \{ x < mid \} else \{ x > mid \}",
                    "which side of the midpoint the low thumb is on (mirrored under RTL)")]),
        "press": (("impl WidgetImpl for KayaRangeThumbInner {", "fn contains("),
                  [(r"range_low_takes\(x, low_centre, high_centre, min_at_left\) == low",
                    "the split"),
                   (r"knob_centre\(scale, within\)", "its own knob's centre"),
                   (r"knob_centre\(&other, within\)", "the other knob's centre"),
                   (r"let min_at_left = scale\.direction\(\) != gtk4::TextDirection::Rtl;",
                    "the scale's own direction"),
                   (r"if !self\.parent_contains\(x, y\) \{\s*return false;",
                    "its own bounds, which GTK's pick trusts contains for")]),
        "arm": ["mod range_view {", "WidgetKind::Range => {", "fn range_moved(",
                "fn range_shape("],
        "zorder": [r"\.insert_after\(", r"\.insert_before\(", r"reorder_child_after",
                   r"reorder_overlay", r"\.snapshot_child\(", r"set_can_target\(true"],
    },
}


def gtk_range_parts_findings(source):
    """§4 MEASURED: GTK's pick asks children before `contains`, so without
    this a thumb's own trough answers every press and the split is never
    asked — every press went to the top scale in the probe."""
    out = []
    body = block_after(source, "fn thumb_parts_untargetable(")
    if not re.search(r"c\.set_can_target\(false\);", body):
        out.append("GTK: thumb_parts_untargetable no longer makes a thumb's own parts "
                   "untargetable — its trough picks first and the midpoint split is "
                   "never asked (§4 MEASURED)")
    for anchor, what in (("pub fn build() -> (KayaRangeGroup", "each thumb built"),
                         ("fn range_shape(", "the marks GtkScale adds")):
        if "thumb_parts_untargetable(" not in block_after(source, anchor):
            out.append(f"GTK: {what} is not made untargetable (`{anchor}`) — a part "
                       f"answering a press bypasses the split")
    return out


def chain(source, anchors):
    """The block reached by following `anchors` in turn, "" when any is absent."""
    block = source
    for a in anchors:
        block = block_after(block, a)
    return block


def routing_findings(sources, rows=ROUTING):
    out = []
    for name, row in rows.items():
        src = sources[row["path"]]
        anchor, needs = row["split"]
        split = block_after(src, anchor)
        if not split:
            out.append(f"{name}: {row['path']} has no `{anchor}` block — the press split "
                       f"this row holds is gone (§3 rule 4)")
        for pat, what in needs:
            if split and not re.search(pat, split):
                out.append(f"{name}: the press split `{anchor}` no longer reads {what} — a "
                           f"press is no longer routed by the midpoint between the thumbs "
                           f"(§3 rule 4)")
        anchors, reads = row["press"]
        press = chain(src, anchors)
        if not press:
            out.append(f"{name}: no press-down site at {' > '.join(anchors)} — the tie is "
                       f"decided at press-down or not at all (§3 rule 4)")
        for pat, what in reads:
            if press and not re.search(pat, press):
                out.append(f"{name}: the press-down site {' > '.join(anchors)} no longer "
                           f"reads {what} — a press would go to whichever slider is on top")
        arm = "".join(block_after(src, a) for a in row["arm"])
        missing = [a for a in row["arm"] if not block_after(src, a)]
        if missing:
            out.append(f"{name}: the range arm's blocks {missing} are gone — the z-order "
                       f"census would read nothing")
        for pat in row["zorder"]:
            hit = re.search(pat, arm)
            if hit:
                out.append(f"{name}: the range arm names the z-order API `{hit.group(0)}` — "
                           f"reordering the two sliders is the forbidden route (§3 rule 4)")
    return out


ROUTING_SOURCES = {SWIFTUI: SWIFT_SOURCE, **REAL}
gate.counted("stacked range rows read", len(ROUTING), floor=4)


def routing_watched(label, sources, fragment):
    if not gate.negative(label, lambda: routing_findings(sources), want=fragment):
        return
    print(f"check-slider-commit: watched refusing: {label}")


# G1. THE MIDPOINT CUT out of the shared SwiftUI split: both rows refuse.
no_mid = gate.doctor("the swiftui midpoint", SWIFT_SOURCE,
                     r"let mid = \(lowCentre \+ highCentre\) / 2",
                     "let mid = highCentre")
routing_watched("a SwiftUI split with no midpoint (macOS row)",
                {**ROUTING_SOURCES, SWIFTUI: no_mid}, "SwiftUI macOS: the press split")
routing_watched("a SwiftUI split with no midpoint (iOS row)",
                {**ROUTING_SOURCES, SWIFTUI: no_mid}, "SwiftUI iOS: the press split")
# G2. THE TIE'S BRANCH CUT.
routing_watched("a SwiftUI split with no tie branch", {**ROUTING_SOURCES, SWIFTUI: gate.doctor(
    "the swiftui tie", SWIFT_SOURCE,
    r"    if abs\(highCentre - lowCentre\) < 0\.5 \{ return [^\n]*\n", "")},
    "reads the tie's branch")
# G7. THE SPLIT BLIND TO A MIRRORED PAIR (right to left puts low at the right).
routing_watched("a SwiftUI split that assumes low is at the left", {
    **ROUTING_SOURCES, SWIFTUI: gate.doctor(
        "the swiftui mirrored side", SWIFT_SOURCE,
        r"return lowCentre < highCentre \? x < mid : x > mid", "return x < mid")},
    "which side of the midpoint the low thumb is on")
# G3. THE MAC PRESS READING ONE THUMB.
routing_watched("a mac hitTest that stopped reading the high knob", {
    **ROUTING_SOURCES, SWIFTUI: gate.doctor(
        "the mac high centre", SWIFT_SOURCE,
        r"highCentre: centre\(high\)\.x", "highCentre: bounds.maxX")},
    "SwiftUI macOS: the press-down site")
# G4. THE iOS PRESS READING ONE THUMB.
routing_watched("an iOS hitTest that stopped reading the low thumb", {
    **ROUTING_SOURCES, SWIFTUI: gate.doctor(
        "the ios low centre", SWIFT_SOURCE,
        r"lowCentre: low\.centreX", "lowCentre: 0")},
    "SwiftUI iOS: the press-down site")
# G5. A Z-ORDER SWAP PLANTED in the mac arm.
routing_watched("a mac range reordering its sliders", {
    **ROUTING_SOURCES, SWIFTUI: gate.doctor(
        "a planted mac addSubview positioned", SWIFT_SOURCE,
        r"(        @objc func changed\(_ sender: KayaRangeThumb\) \{\n)",
        r"\1            addSubview(sender, positioned: .above, relativeTo: nil)\n")},
    "SwiftUI macOS: the range arm names the z-order API")
# G6. A Z-ORDER SWAP PLANTED in the iOS arm.
routing_watched("an iOS range reordering its sliders", {
    **ROUTING_SOURCES, SWIFTUI: gate.doctor(
        "a planted ios bringSubviewToFront", SWIFT_SOURCE,
        r"(        @objc func moved\(_ sender: KayaRangeThumbSlider\) \{\n)",
        r"\1            bringSubviewToFront(sender)\n")},
    "SwiftUI iOS: the range arm names the z-order API")

# G8. WINUI: THE MIDPOINT CUT out of the split.
routing_watched("a WinUI split with no midpoint", {**ROUTING_SOURCES, WINUI: gate.doctor(
    "the winui midpoint", REAL[WINUI],
    r"\(low_centre \+ high_centre\) / 2\.0", "high_centre")},
    "WinUI: the press split")
# G9. WINUI: THE TIE'S BRANCH CUT.
routing_watched("a WinUI split with no tie branch", {**ROUTING_SOURCES, WINUI: gate.doctor(
    "the winui tie", REAL[WINUI],
    r"if \(high_centre - low_centre\)\.abs\(\) < 0\.5 \{\s*low_centre\s*\} else \{\s*"
    r"(\(low_centre \+ high_centre\) / 2\.0)\s*\}", r"\1")},
    "WinUI: the press split `fn winui_range_split(` no longer reads the tie's branch")
# G10. WINUI: THE CLIP READING ONE THUMB.
routing_watched("a WinUI clip that stopped reading the high thumb", {
    **ROUTING_SOURCES, WINUI: gate.doctor(
        "the winui high box", REAL[WINUI],
        r"let \(hx, _, hw, _\) = box_in\(&high_thumb, &within\)\?;(\s*let split)",
        r"let (hx, hw) = (width, 0.0);\1")},
    "WinUI: the press-down site")
# G11. WINUI: THE CLIP GONE — whichever slider is on top takes every press.
routing_watched("a WinUI range whose sliders are not clipped", {
    **ROUTING_SOURCES, WINUI: gate.doctor(
        "the winui clip", REAL[WINUI], r"        slider\.SetClip\(&clip\)\?;\n", "")},
    "the clip that hit testing honours")
# G12. WINUI: A Z-ORDER SWAP PLANTED in the arm (the ledger's superseded
# "z-order set on PointerMoved").
routing_watched("a WinUI range raising the pressed slider", {
    **ROUTING_SOURCES, WINUI: gate.doctor(
        "a planted winui ZIndex", REAL[WINUI],
        r"(    let raw = slider\.Value\(\)\?;\n    let \(lo, hi\))",
        r"    Canvas::SetZIndex(slider, 1)?;\n\1")},
    "WinUI: the range arm names the z-order API `ZIndex`")

# G13. GTK: THE MIDPOINT CUT out of the split.
routing_watched("a GTK split with no midpoint", {**ROUTING_SOURCES, GTK: gate.doctor(
    "the gtk midpoint", REAL[GTK],
    r"let mid = \(low_centre \+ high_centre\) / 2\.0;", "let mid = high_centre;")},
    "GTK: the press split")
# G14. GTK: THE TIE'S BRANCH CUT.
routing_watched("a GTK split with no tie branch", {**ROUTING_SOURCES, GTK: gate.doctor(
    "the gtk tie", REAL[GTK],
    r"    if \(high_centre - low_centre\)\.abs\(\) < 0\.5 \{\n[^\n]*\n    \}\n", "")},
    "GTK: the press split `fn range_low_takes(` no longer reads the tie's branch")
# G15. GTK: THE PRESS READING ONE THUMB.
routing_watched("a GTK contains that stopped reading the other knob", {
    **ROUTING_SOURCES, GTK: gate.doctor(
        "the gtk other knob", REAL[GTK],
        r"super::super::knob_centre\(&other, within\),", "Some(0.0),")},
    "GTK: the press-down site")
# G16. GTK: THE SPLIT BLIND TO THE DIRECTION (a tie in Arabic went the wrong way
# in the probe's first RTL run).
routing_watched("a GTK contains that assumes left to right", {
    **ROUTING_SOURCES, GTK: gate.doctor(
        "the gtk direction", REAL[GTK],
        r"let min_at_left = scale\.direction\(\) != gtk4::TextDirection::Rtl;",
        "let min_at_left = true;")},
    "the scale's own direction")
# G17. GTK: A Z-ORDER SWAP PLANTED in the arm.
routing_watched("a GTK range raising the pressed thumb", {
    **ROUTING_SOURCES, GTK: gate.doctor(
        "a planted gtk insert_after", REAL[GTK],
        r"(    let raw = thumb\.value\(\);\n)",
        r"    thumb.insert_after(&pair.group, Some(pair.thumb(!low)));\n\1")},
    "GTK: the range arm names the z-order API")
# G18. GTK: THE THUMB'S PARTS LEFT TARGETABLE.
if gate.negative("a GTK thumb whose parts still answer presses",
                 lambda: gtk_range_parts_findings(gate.doctor(
                     "the gtk untargetable parts", REAL[GTK],
                     r"c\.set_can_target\(false\);", "c.set_can_target(c.can_target());")),
                 want="never asked"):
    print("check-slider-commit: watched refusing: a GTK thumb whose parts still answer presses")
# G19. GTK: THE MARKS' NEW CHILDREN LEFT TARGETABLE.
if gate.negative("a GTK range whose marks answer presses",
                 lambda: gtk_range_parts_findings(gate.doctor(
                     "the gtk marks untargetable", REAL[GTK],
                     r"(\s*)thumb_parts_untargetable\(thumb\.upcast_ref\(\)\);\n(\s*\}\n\s*quiet\.set)",
                     r"\n\2")),
                 want="the marks GtkScale adds"):
    print("check-slider-commit: watched refusing: a GTK range whose marks answer presses")

# THE CORE'S PAIR FOLLOWS THE USER (docs/range-plan.md §3 rule 11): every
# committed range reaches `Scene::user_range_committed` before it is sent, or
# the next app write is judged against a pair the user already moved and
# lands crossed. The scene's own step clamps it; nothing on a lane can tell a
# door that skipped the record, since set_value moves the control either way
# and only a later app write shows it (tools/scenes/range.steps' `late`).
# The widget backends record through a helper that queues when CORE is
# borrowed, so every drain of the transaction channel must empty that queue
# before it applies, or a queued commit is judged after the write it preceded.
CAPI = "crates/kaya/src/capi.rs"
RECORDERS = {GTK: "gtk_user_range_committed", WINUI: "winui_user_range_committed"}


def fn_body(text, name):
    m = re.search(r"\n(?:pub(?:\([a-z]+\))? )?(?:unsafe )?(?:extern \"C\" )?fn "
                  + re.escape(name) + r"\b", text)
    if not m:
        return None
    return block_after(text, text[m.start():m.start() + 1 + text[m.start() + 1:].index("{") + 1])


def commit_record_findings(sources):
    out = []
    capi = fn_body(sources[CAPI], "kaya_emit_range")
    if capi is None:
        out.append("capi: kaya_emit_range is gone, so no interpreter's commit is recorded")
    elif not re.search(r"user_range_committed\([^)]*\)[\s\S]*send_range_tag", capi):
        out.append("capi: kaya_emit_range sends a committed pair without "
                   "`scene.user_range_committed` first")
    for path, helper in RECORDERS.items():
        text = sources[path]
        name = path.split("/")[-2] if path.endswith("mod.rs") else path.split("/")[-1]
        body = fn_body(text, helper)
        if body is None or "core.scene.user_range_committed(" not in body \
                or "RANGE_SETTLED" not in body:
            out.append(f"{name}: `{helper}` no longer records into the scene "
                       "or queues into RANGE_SETTLED")
        drain = fn_body(text, "drain_range_settled")
        if drain is None or "core.scene.user_range_committed(" not in drain:
            out.append(f"{name}: `drain_range_settled` no longer empties the queue into the scene")
        sends = re.findall(r"send_range_tag\([^;]*?,\s*true\)", text)
        recorded = re.findall(re.escape(helper) + r"\([^;]*\);\s*\n\s*"
                              r"sink\.send_range_tag\([^;]*?,\s*true\)", text)
        if not sends or len(recorded) != len(sends):
            out.append(f"{name}: {len(sends)} committed range send(s), {len(recorded)} "
                       f"right after `{helper}`")
        if re.search(r"Occurrence::(?:Instance)?RangeCommitted", text):
            out.append(f"{name}: builds a RangeCommitted occurrence itself, past the recorder")
        applies = len(re.findall(r"core\.scene\.apply\(tx\)", text))
        drained = len(re.findall(r"drain_range_settled\(core\);\s*\n\s*"
                                 r"(?:for op in )?core\.scene\.apply\(tx\)", text))
        if applies == 0 or drained != applies:
            out.append(f"{name}: {applies} transaction apply site(s), {drained} "
                       "draining RANGE_SETTLED first")
    return out


RECORD_SOURCES = {CAPI: gate.read(CAPI), GTK: REAL[GTK], WINUI: REAL[WINUI]}
gate.counted("committed range sends read",
             sum(len(re.findall(r"send_range_tag\([^;]*?,\s*true\)", RECORD_SOURCES[p]))
                 for p in RECORDERS), floor=2)


def record_watched(label, path, fragment, pattern, repl):
    doctored = {**RECORD_SOURCES, path: gate.doctor(label, RECORD_SOURCES[path], pattern, repl)}
    if gate.negative(label, lambda: commit_record_findings(doctored), want=fragment):
        print(f"check-slider-commit: watched refusing: {label}")


# U1. THE INTERPRETERS' DOOR SKIPPING THE RECORD.
record_watched("a capi range commit never recorded", CAPI, "kaya_emit_range sends",
               r"scene\.user_range_committed\(tag, low, high\);", "let _ = scene;")
# U2/U3. A WIDGET BACKEND'S COMMIT SENT WITHOUT ITS RECORDER.
record_watched("a GTK range commit never recorded", GTK, "right after `gtk_user_range_committed`",
               r"gtk_user_range_committed\(tag, lo, hi\);\n", "")
record_watched("a WinUI range commit never recorded", WINUI,
               "right after `winui_user_range_committed`",
               r"winui_user_range_committed\(&cell\.tag, nlo, nhi\);\n", "")
# U4/U5. A DRAIN THAT APPLIES BEFORE THE QUEUED COMMITS (gtk's harness drain
# was the second copy that missed it, found writing this clause).
record_watched("a GTK harness drain skipping the queue", GTK, "draining RANGE_SETTLED first",
               r"(\n *)drain_range_settled\(core\);"
               r"(\n *for op in"
               r" core\.scene\.apply\(tx\) \{\n *apply\(core, op\);\n *\}\n *for occ)",
               r"\2")
record_watched("a WinUI drain skipping the queue", WINUI, "draining RANGE_SETTLED first",
               r"\n *drain_range_settled\(core\);(?=\n *for op in core\.scene\.apply)", "")

# THE THUMB ON TOP WEARS AN OUTLINE AT A TIE (docs/range-plan.md §3 rule 4),
# in the platform's own outline token. No scene can see it: the tie lines read
# values, fractions and the hit test, all identical with the outline gone, and
# a literal colour draws the same picture in the appearance it was picked in.
# One row per arm, each naming the block that draws the outline and the token
# it strokes with, the tie test that shows it on the HIGH thumb (the one drawn
# on top), and the order that puts it above both thumbs.
LITERAL_COLOURS = [r"#[0-9A-Fa-f]{3,8}\b", r"\brgba?\(", r"NSColor\((?:red|srgbRed|calibratedRed|"
                   r"deviceRed|white|calibratedWhite)", r"UIColor\((?:red|white)",
                   r"NSColor\.(?:black|white|gray|lightGray|darkGray)\b",
                   r"UIColor\.(?:black|white|gray|lightGray|darkGray)\b", r"Color\(0x",
                   r"Colors\.", r"Color\.(?:Black|White|Gray)\b"]
TIE_OUTLINE = {
    "SwiftUI macOS": {
        "path": SWIFTUI,
        "draws": ("final class KayaRangeTieRing: NSView", [
            (r"NSColor\.separatorColor\.setStroke\(\)", "the separator token")]),
        "shown": ("final class KayaRangeView: NSView", [
            (r"let tied = abs\(centre\(high\)\.x - centre\(low\)\.x\) < 0\.5",
             "the tie test"),
            (r"tie\.ring = tied \? convert\(high\.knobRect, from: high\) : nil",
             "the high knob, the one drawn on top"),
            (r"addSubview\(thumb\)\n\s*\}\n\s*addSubview\(tie\)",
             "the ring added after both thumbs")]),
    },
    "SwiftUI iOS": {
        "path": SWIFTUI,
        "draws": ("final class KayaRangeTieRing: UIView", [
            (r"UIColor\.separator\.setStroke\(\)", "the separator token"),
            (r"isUserInteractionEnabled = false", "a ring no touch reaches")]),
        "shown": ("final class KayaRangeTrack: UIView", [
            (r"let tied = abs\(high\.centreX - low\.centreX\) < 0\.5", "the tie test"),
            (r"let knob = high\.thumbRect\(", "the high knob, the one drawn on top"),
            (r"tie\.isHidden = !tied", "the ring hidden off a tie"),
            (r"addSubview\(thumb\)\n\s*\}\n\s*tie\.isHidden = true\n\s*addSubview\(tie\)",
             "the ring added after both thumbs")]),
    },
    "GTK": {
        "path": GTK,
        "draws": ("const RANGE_CSS: &str", [
            (r"\.kaya-range-tie \{ border: [0-9.]+px solid @borders;", "Adwaita's border token")]),
        "shown": ("impl WidgetImpl for KayaRangeGroupInner {", [
            (r"let tied = \(hc - lc\)\.abs\(\) < 0\.5;", "the tie test"),
            (r"high_knob\.compute_bounds\(group\)", "the high knob, the one drawn on top"),
            (r"tie\.set_child_visible\(tied\)", "the ring hidden off a tie"),
            (r"if trough\.imp\(\)\.span\.replace\(span\) != span \{\s*trough\.queue_allocate\(\);",
             "the fill re-laid when the thumbs move (a stale fill showed beside a tie)")]),
        "order": ("pub fn build() -> (KayaRangeGroup", r"thumb\.set_parent\(&group\);[\s\S]*"
                  r"tie\.set_parent\(&group\);", "the ring parented after both thumbs"),
    },
    "WinUI": {
        "path": WINUI,
        "draws": ("const RANGE_RING_XAML: &str", [
            (r'Stroke=\\"\{ThemeResource ControlStrongStrokeColorDefaultBrush\}\\"',
             "the strong-stroke token"),
            (r'IsHitTestVisible=\\"False\\"', "a ring no press reaches")]),
        "shown": ("fn winui_range_layout(", [
            (r"let tied = \(hc - lc\)\.abs\(\) < 0\.5;", "the tie test"),
            (r"place_if_moved\(&pair\.ring, hx - 1\.0, hy - 1\.0, hw \+ 2\.0, hh \+ 2\.0\)",
             "the high thumb's box, the one drawn on top"),
            (r"if tied \{ Visibility::Visible \} else \{ Visibility::Collapsed \}",
             "the ring hidden off a tie")]),
        "order": ("impl RangePair {", r"pair\.root\.Children\(\)\?\.Append\(thumb\)\?;[\s\S]*"
                  r"pair\.root\.Children\(\)\?\.Append\(&pair\.ring\)\?;",
                  "the ring appended after both sliders"),
    },
    # Material's RangeSlider places the track, the start thumb and then the end
    # thumb (javap of material3 1.3.1's RangeSliderImpl), so the END is on top.
    "Compose": {
        "path": COMPOSE,
        "draws": ("private fun KayaSliderThumb(", [
            (r"drawRoundRect\(\s*outline,[\s\S]*style = Stroke\(", "the outline stroked")]),
        "shown": ("endThumb = {", [
            (r"outline = if \(node\.low == node\.high\) "
             r"MaterialTheme\.colorScheme\.outline else null",
             "Material's outline token on the end thumb, at a tie only")]),
        "not": ("startThumb = {", r"outline =", "the start thumb, drawn underneath"),
    },
}


def tie_outline_findings(sources, rows=TIE_OUTLINE):
    out = []
    for name, row in rows.items():
        src = sources[row["path"]]
        for key in ("draws", "shown"):
            anchor, needs = row[key]
            if key == "draws" and anchor.startswith("const "):
                at = src.find(anchor)
                block = src[at:src.find("\n\n", at)] if at >= 0 else ""
            else:
                block = block_after(src, anchor)
            if not block:
                out.append(f"{name}: no `{anchor}` block — the tie's outline this row holds is "
                           f"gone (§3 rule 4)")
                continue
            for pat, what in needs:
                if not re.search(pat, block):
                    out.append(f"{name}: `{anchor}` no longer holds {what} — the thumb on top "
                               f"at a tie loses its outline or takes a colour no token names "
                               f"(§3 rule 4)")
            if key == "draws":
                for pat in LITERAL_COLOURS:
                    hit = re.search(pat, block)
                    if hit:
                        out.append(f"{name}: the tie's outline names the literal colour "
                                   f"`{hit.group(0)}` — it takes the platform's token (§3 rule 4)")
        if "order" in row:
            anchor, pat, what = row["order"]
            if not re.search(pat, block_after(src, anchor)):
                out.append(f"{name}: `{anchor}` no longer has {what} — the outline would draw "
                           f"under a thumb")
        if "not" in row:
            anchor, pat, what = row["not"]
            block = block_after(src, anchor)
            if not block or re.search(pat, block):
                out.append(f"{name}: {what} wears the tie's outline, or its block is gone")
    return out


TIE_SOURCES = {SWIFTUI: SWIFT_SOURCE, **REAL}
gate.counted("tie outline rows read", len(TIE_OUTLINE), floor=5)


def tie_watched(label, path, pattern, repl, fragment):
    doctored = {**TIE_SOURCES, path: gate.doctor(label, TIE_SOURCES[path], pattern, repl)}
    if gate.negative(label, lambda: tie_outline_findings(doctored), want=fragment):
        print(f"check-slider-commit: watched refusing: {label}")


# O1-O5. EACH ARM'S TOKEN SWAPPED FOR A LITERAL.
tie_watched("a mac tie ring stroked in a literal", SWIFTUI,
            r"NSColor\.separatorColor\.setStroke\(\)",
            "NSColor(white: 0.5, alpha: 1).setStroke()", "SwiftUI macOS: the tie's outline names")
tie_watched("an iOS tie ring stroked in a literal", SWIFTUI,
            r"UIColor\.separator\.setStroke\(\)", "UIColor.gray.setStroke()",
            "SwiftUI iOS: the tie's outline names")
tie_watched("a GTK tie ring bordered in a literal", GTK,
            r"(\.kaya-range-tie \{ border: 1\.5px solid )@borders;", r"\1#808080;",
            "GTK: the tie's outline names")
tie_watched("a WinUI tie ring stroked in a literal", WINUI,
            r"\{ThemeResource ControlStrongStrokeColorDefaultBrush\}", "#FF808080",
            "WinUI: the tie's outline names")
tie_watched("a Compose tie outline in a literal", COMPOSE,
            r"MaterialTheme\.colorScheme\.outline else null", "Color(0xFF808080) else null",
            "Compose: `endThumb = {` no longer holds")
# O6-O10. EACH ARM'S RING PUT ON THE LOW THUMB, UNDERNEATH, OR NEVER SHOWN.
tie_watched("a mac ring on the low knob", SWIFTUI,
            r"tied \? convert\(high\.knobRect, from: high\)",
            "tied ? convert(low.knobRect, from: low)",
            "SwiftUI macOS: `final class KayaRangeView: NSView` no longer holds the high knob")
tie_watched("an iOS ring never hidden", SWIFTUI, r"tie\.isHidden = !tied", "tie.isHidden = false",
            "SwiftUI iOS: `final class KayaRangeTrack: UIView` no longer holds the ring hidden")
tie_watched("a GTK ring parented under the thumbs", GTK,
            r"(        let mut thumbs = Vec::new\(\);\n)([\s\S]*?)"
            r"        tie\.set_parent\(&group\);\n",
            r"        tie.set_parent(&group);\n\1\2",
            "GTK: `pub fn build() -> (KayaRangeGroup` no longer has the ring parented")
tie_watched("a GTK fill left where the thumbs were", GTK,
            r"(if trough\.imp\(\)\.span\.replace\(span\) != span \{\n)"
            r"\s*trough\.queue_allocate\(\);\n",
            r"\1", "no longer holds the fill re-laid")
tie_watched("a WinUI ring on the low thumb", WINUI,
            r"place_if_moved\(&pair\.ring, hx - 1\.0, hy - 1\.0, hw \+ 2\.0, hh \+ 2\.0\)",
            "place_if_moved(&pair.ring, lx - 1.0, hy - 1.0, lw + 2.0, hh + 2.0)",
            "WinUI: `fn winui_range_layout(` no longer holds the high thumb's box")
tie_watched("a Compose outline on the start thumb", COMPOSE,
            r"(startThumb = \{\n(?:.*\n){4}\s*Modifier\.onGloballyPositioned "
            r"\{ kayaThumbCoords\[node\.id to 1\] = it \},\n)",
            r"\1                        outline = MaterialTheme.colorScheme.outline,\n",
            "Compose: the start thumb, drawn underneath wears the tie's outline")

for line in routing_findings(ROUTING_SOURCES):
    gate.finding(line)
for line in tie_outline_findings(TIE_SOURCES):
    gate.finding(line)
for line in commit_record_findings(RECORD_SOURCES):
    gate.finding(line)
for line in gtk_range_parts_findings(REAL[GTK]):
    gate.finding(line)
for line in gtk_range_findings(REAL[GTK]):
    gate.finding(line)
for line in gtk_color_findings(REAL[GTK]):
    gate.finding(line)
for line in census(REAL):
    gate.finding(line)
for line in winui_color_findings(REAL[WINUI]):
    gate.finding(line)
for line in swiftui_color_findings(SWIFT_SOURCE):
    gate.finding(line)
for line in swiftui_range_findings(SWIFT_SOURCE):
    gate.finding(line)
for line in winui_range_findings(REAL[WINUI]):
    gate.finding(line)
for line in compose_color_findings(REAL[COMPOSE]):
    gate.finding(line)
for line in compose_range_findings(REAL[COMPOSE]):
    gate.finding(line)

gate.verdict("the commit rule holds on every landed slider arm, every colour picker arm, "
             "every range arm and the core's record of the user's pair; every range arm "
             "outlines the thumb on top at a tie in its platform's token")
