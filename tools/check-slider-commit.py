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

for line in census(REAL):
    gate.finding(line)
for line in swiftui_color_findings(SWIFT_SOURCE):
    gate.finding(line)

gate.verdict("the commit rule holds on every landed slider arm and the SwiftUI colour picker")
