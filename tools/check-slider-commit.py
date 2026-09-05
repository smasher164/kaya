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


ROWS = {WINUI: winui_findings}


def census(sources):
    """Every backend with a landed arm answers for its commit rule."""
    out = []
    for path, stub in BACKENDS:
        source = sources[path]
        if re.search(stub, source):
            continue
        reader = ROWS.get(path)
        if reader is None:
            out.append(
                f"{path}: the slider arm has landed (no {stub} left) and this "
                f"gate has no row for it — add one beside winui_findings, "
                f"naming this backend's per-movement event and its gesture "
                f"end (docs/slider-plan.md S2)")
            continue
        out.extend(reader(source))
    return out


REAL = {path: gate.read(path) for path, _ in BACKENDS}
gate.counted("backend arms read", len(REAL), floor=3)


def watched(label, sources, fragment):
    """The negative: the gate's OWN census over doctored input, red demanded."""
    if not gate.negative(label, lambda: census(sources), want=fragment):
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
#    self-maintaining half, watched on the backend whose arm is the next
#    to land.
landed = gate.doctor(
    "the gtk stub removal", REAL[GTK],
    r'crate::depth_stub\("sliders"\)', "()")
watched("a GTK slider arm with no row in this gate",
        {**REAL, GTK: landed}, "this gate has no row for it")

for line in census(REAL):
    gate.finding(line)

gate.verdict("the commit rule holds on every landed slider arm")
