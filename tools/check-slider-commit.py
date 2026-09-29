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
    r"onValueChangeFinished = \{", "onValueChangeStarted = {")
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

for line in gtk_color_findings(REAL[GTK]):
    gate.finding(line)
for line in census(REAL):
    gate.finding(line)
for line in winui_color_findings(REAL[WINUI]):
    gate.finding(line)
for line in swiftui_color_findings(SWIFT_SOURCE):
    gate.finding(line)
for line in compose_color_findings(REAL[COMPOSE]):
    gate.finding(line)

gate.verdict("the commit rule holds on every landed slider arm and every colour picker arm")
