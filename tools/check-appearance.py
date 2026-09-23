#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
import re

from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()


# THE APPEARANCE OVERRIDE IS INERT UNLESS ASKED FOR, AND HONEST WHEN IT
# IS (CLAUDE.md's gate list;
# docs/measurements/canvas-palette-look-2026-08-27.txt, whose
# `-AppleInterfaceStyle Dark` attempt is what this replaces).
#   A. INERT WHEN UNSET: every install site sits behind a reader that
#      answers "nothing" for an absent variable. NO LANE can see one
#      stop being guarded — every lane machine is light, which is what
#      an unguarded default also produces.
#   B. THE BACKEND STILL READS THE PLATFORM BACK: reporting the variable
#      straight into `set_presentation` makes the dark leg
#      SELF-FULFILLING, the exact bug it exists to catch. So no file
#      that reports a presentation may name the variable or its reader.

MAC = "swift/KayaSwiftUI.swift"
ENTRY = "swift/KayaSwiftUIEntry.swift"
CANVAS = "crates/kaya/src/canvas.rs"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

FILES = [MAC, ENTRY, CANVAS, GTK, WINUI, COMPOSE]

# One dark leg per lane: the runner, the spelling that wires it, and the
# lane's own name for the leg. A runner missing from this table is a lane
# whose dark arm nobody asserts.
LEGS = [
    # The mac roster is DATA (tools/lib/lanes/mac.py); the dark leg's
    # spelling there is its quoted name.
    ("tools/lib/lanes/mac.py", '"canvasdark-rust-swiftui"', "mac"),
    ("tools/linux/run-suites.sh", "canvasdark-rust", "linux"),
    # The ios roster is DATA (tools/lib/lanes/ios.py); the dark leg's
    # spelling there is its quoted name.
    ("tools/lib/lanes/ios.py", '"canvasdark-swift"', "ios"),
    # The android roster is DATA (tools/lib/lanes/android.py); the dark
    # leg's spelling there is its quoted name.
    ("tools/lib/lanes/android.py", '"canvasdark-compose"', "android"),
    # The windows roster is DATA (tools/lib/lanes/win.py); the leg's
    # spelling there is its quoted name.
    ("tools/lib/lanes/win.py", '"canvasdark_rust"', "windows"),
]

# THE PATTERNS ARE CALL-SHAPED AND READ COMMENT-STRIPPED TEXT, both
# learned from this gate's own negatives: `setApplicationNightMode` and
# `kayaAppearanceOverride()` each appear in PROSE in the file that calls
# them, so N3 and N4 first passed with the call deleted — the bare-name
# trap that let three of check-tx-liveness's clauses pass with the guard
# gone (CLAUDE.md invariant 3).
# THE ASKED FUNCTION dominates every install since 2026-09-07 (docs/tasks-s2b-plan.md
# R3): the app's `appearance` prop first, the knob second, nothing third —
# and nothing puts the platform's own default back, which is inert.
GUARD_SWIFT = r"guard let mode = kayaAppearanceAsked\(\) else \{"
GUARD_RUST = r"crate::canvas::appearance_asked\(\)"
GUARD_KT = r'System\.getenv\("KAYA_APPEARANCE"\) \?: return'
# Compose's window-background half installs what the asked function answers
# at both its call sites, and null is an install too (the system's own back).
GUARD_KT_ASKED = r"installAppearanceBackground\(\w+, appearanceAsked\(\)\)"
# KayaAppearance's own early-out, the composition half's inert clause.
GUARD_KT_UI = r"if \(want == null\) \{"
# KayaCompliance's, the two compliance knobs' inert clause.
GUARD_KT_COMPLIANCE = r"if \(scale == null && locale == null\) \{"

# How far a guard may sit above the call it dominates. The character
# window is only a cap; what actually holds "same function" is
# FUNCTION_START below — a guard cannot vouch for a call in another body,
# and counting characters alone made that a magic number that the Compose
# half (which resolves a theme between its guard and its call) broke.
WINDOW = 1600
FUNCTION_START = re.compile(r"^\s*(?:private |internal |public |pub )?"
                            r"(?:fun|func|fn) \w", re.M)

# Every install site: the file, the call that installs the override, and
# the guard that must dominate it. The guard is what makes clause A true.
INSTALLS = [
    (ENTRY, r"kayaApplyAppearance\(\)", None,
     "macOS installs the override before its first window"),
    (MAC, r"NSApp\.appearance = NSAppearance\(named:", GUARD_SWIFT,
     "the macOS arm sets NSApp's own appearance"),
    (MAC, r"window\.overrideUserInterfaceStyle = style", GUARD_SWIFT,
     "the iOS arm sets the window's own style"),
    (GTK, r"\.set_color_scheme\(", GUARD_RUST,
     "GTK forces libadwaita's colour scheme"),
    (WINUI, r"element\.SetRequestedTheme\(", GUARD_RUST,
     "WinUI sets the content root's RequestedTheme"),
    # BOTH HALVES, separately, because either alone is the measured
    # half-dark app: the window background comes from the MANIFEST theme
    # and isSystemInDarkTheme() from LocalConfiguration, and nothing on
    # Android moves both without relaunching the activity (which kills the
    # process — see KayaCompose.applyAppearanceOverride).
    (COMPOSE, r"activity\.window\.setBackgroundDrawable\(", None,
     "Compose moves the WINDOW BACKGROUND half"),
    (COMPOSE, GUARD_KT_ASKED, None,
     "Compose's background half is fed by the asked function"),
    (COMPOSE, r"CompositionLocalProvider\(LocalConfiguration provides forced",
     GUARD_KT_UI,
     "Compose moves the isSystemInDarkTheme half"),
    # THE TEXT SCALE, the appearance's twin (docs/compliance-plan.md §2.1):
    # the knob's asked function dominates the one iOS install, and the
    # report beside it is unconditional — it carries the TOOLKIT's factor
    # whichever way the scale was set.
    (ENTRY, r"kayaApplyTextScale\(\)", None,
     "macOS reports the text scale before its first window"),
    (MAC, r"window\.traitOverrides\.preferredContentSizeCategory = category",
     r"if let factor = kayaTextScaleOverride\(\) \{",
     "the iOS arm sets the window's own content size category"),
    (GTK, r"settings\.set_gtk_xft_dpi\(\(96\.0 \* 1024\.0 \* factor\) as i32\)",
     r"if let Some\(factor\) = crate::fmt::text_scale_override\(\) \{",
     "GTK writes the knob's factor into the toolkit's own dpi"),
    # COMPOSE'S THREE HALVES, one composable (KayaCompliance, docs/
    # compliance-plan.md §2.1, §2.2): the forced Configuration carries the
    # font scale and the locale, the Density carries the scale every sp
    # converts through, and the layout direction rides beside them since
    # Compose takes it from the view; the one early-out is the inert clause.
    (COMPOSE, r"LocalConfiguration provides compliant,", GUARD_KT_COMPLIANCE,
     "Compose forces the configuration's fontScale and locales"),
    (COMPOSE, r"LocalDensity provides compliantDensity,", GUARD_KT_COMPLIANCE,
     "Compose's text-scale half moves the Density every sp reads"),
    (COMPOSE, r"LocalLayoutDirection provides direction,", GUARD_KT_COMPLIANCE,
     "Compose's direction half moves LocalLayoutDirection"),
]

# The text-scale READ-BACK may not derive its factor from the knob
# (clause B's twin): a read that echoed KAYA_TEXT_SCALE would make the
# tasksbig leg self-fulfilling with every label still at 17pt.
TEXT_SCALE_READERS = [
    (MAC, "func kayaTextScaleFactor", ("KAYA_TEXT_SCALE", "kayaTextScaleOverride")),
    (COMPOSE, '"expect_text_scale" ->',
     ("KAYA_TEXT_SCALE", "textScaleOverride", "textScaleAsked")),
    (GTK, "fn text_scale(&self) -> f64 {", ("KAYA_TEXT_SCALE", "text_scale_override")),
    (WINUI, "fn text_scale(&self) -> f64 {", ("KAYA_TEXT_SCALE", "text_scale_override")),
]

# And the direction and locale readers beside it, on the two toolkits that
# read a root's own property back: never the knob, never the door's latch.
LOCALE_READERS = [
    (COMPOSE, '"expect_direction" ->', ("KAYA_LOCALE", "localeOverride", "localeAsked")),
    (COMPOSE, '"expect_locale" ->', ("KAYA_LOCALE", "localeOverride", "localeAsked")),
    (WINUI, "fn direction(&self) -> String {", ("KAYA_LOCALE", "install_locale", "fmt::locale()")),
    (WINUI, "fn platform_locale(&self) -> String {",
     ("KAYA_LOCALE", "install_locale", "fmt::locale()")),
]

# The files that REPORT a presentation. None of them may name the knob
# outside its own install site — clause B.
REPORTERS = [
    (GTK, "presentation_report"),
    (WINUI, "presentation_report"),
    (COMPOSE, "KayaPresent.presentation"),
]


def uncommented(text):
    """Code only: `/* … */` and `//…` removed.

    Swift, Rust and Kotlin share both spellings. A `//` inside a string
    literal (WinUI's XAML namespace URLs) loses the rest of its line, which
    is harmless here — no needle this gate looks for lives in one.
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def census(src):
    """Every finding, as strings. The negatives run THIS over doctored src."""
    out = []
    code = {p: uncommented(t) for p, t in src.items()}

    # --- A1. Every install site is present, and guarded. ----------------
    for path, call, guard, what in INSTALLS:
        text = code[path]
        hit = re.search(call, text)
        if not hit:
            out.append(
                f"{path}: no `{call}` in code — {what} is gone, so "
                f"KAYA_APPEARANCE does nothing on that platform and its dark "
                f"leg asserts the light palette under a light window"
            )
            continue
        if guard is None:
            continue
        # THE GUARD MUST DOMINATE THE CALL, not merely share the file: the
        # reader's own definition and the prose about it both name it, so
        # "appears somewhere" is satisfied by a file whose install is
        # unconditional.
        window = text[max(0, hit.start() - WINDOW):hit.start()]
        found = list(re.finditer(guard, window))
        # The NEAREST guard above, and nothing may open a new function
        # between it and the call — that is the real "dominates".
        same_body = bool(found) and not FUNCTION_START.search(
            window[found[-1].end():]
        )
        if not same_body:
            out.append(
                f"{path}: `{call}` is not guarded by `{guard}` within "
                f"{WINDOW} characters above it in the same function body — "
                f"the override would be "
                f"installed with KAYA_APPEARANCE unset, and no lane can see "
                f"that (every lane host is light, which is what an unguarded "
                f"default also produces)"
            )

    # --- A2. Each reader answers "nothing" when the variable is absent. --
    swift = code[MAC]
    if not re.search(
        r'guard let want = ProcessInfo\.processInfo\.environment\["KAYA_APPEARANCE"\]'
        r"\s*else \{ return nil \}",
        swift,
    ):
        out.append(
            f"{MAC}: kayaAppearanceOverride() no longer returns nil for an "
            f"absent KAYA_APPEARANCE — the unset case must install nothing"
        )
    rust = code[CANVAS]
    if 'std::env::var("KAYA_APPEARANCE").ok()?' not in rust:
        out.append(
            f"{CANVAS}: appearance_override() no longer returns None for an "
            f"absent KAYA_APPEARANCE — the unset case must install nothing"
        )
    # AND THE ASKED FUNCTION FALLS THROUGH TO THE KNOB when the app chose
    # `system` (0): an asked function that answered the choice alone would
    # take the dark canvas legs' knob away with every lane still light.
    if not re.search(r"default: return kayaAppearanceOverride\(\)", swift):
        out.append(
            f"{MAC}: kayaAppearanceAsked() no longer falls through to "
            f"kayaAppearanceOverride() for the system choice — the knob would "
            f"be dead on every dark leg"
        )
    if not re.search(r"_ => appearance_override\(\),", rust):
        out.append(
            f"{CANVAS}: appearance_asked() no longer falls through to "
            f"appearance_override() for the system choice — the knob would be "
            f"dead on every dark leg"
        )
    if not re.search(r"else -> appearanceOverride", code[COMPOSE]):
        out.append(
            f"{COMPOSE}: appearanceAsked() no longer falls through to the knob "
            f"for the system choice — the knob would be dead on the dark leg"
        )
    if 'System.getenv("KAYA_APPEARANCE") ?: return' not in code[COMPOSE]:
        out.append(
            f"{COMPOSE}: applyAppearanceOverride no longer returns early for "
            f"an absent KAYA_APPEARANCE — the unset case must install nothing"
        )

    # --- A3. A value that is neither word is refused, never ignored. -----
    # A silently ignored typo runs the whole leg under the host's palette
    # and freezes a wrong string, which is the failure that costs a night.
    for path, needle in (
        (MAC, "is not a mode; use light or dark"),
        (CANVAS, "is not a mode; use light or dark"),
        (COMPOSE, "is not a mode; use light or dark"),
    ):
        if needle not in code[path]:
            out.append(
                f"{path}: a KAYA_APPEARANCE that is neither light nor dark is "
                f"no longer refused — a typo would run the leg under the "
                f"host's palette and freeze a wrong string"
            )

    # --- A2. The text-scale read-back reads the toolkit, never the knob. --
    for path, needle, banned in TEXT_SCALE_READERS:
        start = code[path].find(needle)
        if start < 0:
            out.append(f"{path}: no `{needle}` — the text-scale read-back is gone")
            continue
        body = code[path][start:start + 1200]
        if any(word in body for word in banned):
            out.append(
                f"{path}: `{needle}` derives its factor from the knob — the read-back "
                f"must ask the toolkit, or the scale leg is self-fulfilling"
            )
    for path, needle, banned in LOCALE_READERS:
        start = code[path].find(needle)
        if start < 0:
            out.append(f"{path}: no `{needle}` — the locale read-back is gone")
            continue
        body = code[path][start:start + 900]
        if any(word in body for word in banned):
            out.append(
                f"{path}: `{needle}` derives its answer from the knob — the "
                f"read-back must ask the toolkit, or the Arabic leg is "
                f"self-fulfilling"
            )

    # --- B. No reporter may report the ENV instead of the platform. ------
    for path, fn in REPORTERS:
        text = code[path]
        start = text.find(f"fn {fn}") if path != COMPOSE else -1
        if path == COMPOSE:
            # Compose's report is a LaunchedEffect, not a function: the
            # rule is that the value it sends is isSystemInDarkTheme()'s.
            if "KayaPresent.presentation(presentationScale, presentationDark)" not in text:
                out.append(
                    f"{path}: the presentation report no longer sends the "
                    f"value read from isSystemInDarkTheme() — a report taken "
                    f"from KAYA_APPEARANCE makes the dark leg self-fulfilling"
                )
            if re.search(r"presentationDark\s*=\s*[^i\n]*KAYA_APPEARANCE", text):
                out.append(
                    f"{path}: the reported appearance is derived from "
                    f"KAYA_APPEARANCE — the report must read the platform back"
                )
            continue
        if start < 0:
            out.append(f"{path}: no `fn {fn}` — this clause is blind")
            continue
        body = text[start:start + 3000]
        for banned in ("appearance_override", "KAYA_APPEARANCE"):
            # WinUI installs INSIDE its reporter, so the install line is
            # legitimate there; what may never happen is the reported MODE
            # being computed from it.
            if re.search(
                r"(?:let|var)\s+mode\s*=.*" + re.escape(banned), body, re.S
            ):
                out.append(
                    f"{path}: {fn}'s reported mode is computed from "
                    f"`{banned}` — the override must move the toolkit and "
                    f"the report must then read the TOOLKIT back, or the "
                    f"dark leg passes with the window still light"
                )

    # --- B3. The expect_appearance readers answer the TOOLKIT, never the
    # prop or the knob (docs/tasks-s2b-plan.md R4): a reader that echoed
    # what the app asked for would pass with the window unmoved.
    for path, needle, banned in (
        (GTK, "fn appearance(&self) -> String {",
         ("appearance_asked", "APPEARANCE_CHOICE", "KAYA_APPEARANCE", "appearance_override")),
        (WINUI, "fn appearance(&self) -> String {",
         ("appearance_asked", "APPEARANCE_CHOICE", "KAYA_APPEARANCE", "appearance_override")),
        (MAC, 'case "expect_appearance":',
         ("kayaAppearanceChoice", "kayaAppearanceAsked", "KAYA_APPEARANCE",
          "kayaAppearanceOverride")),
        (COMPOSE, '"expect_appearance" ->',
         ("appearanceAsked", "appearanceChoice", "KAYA_APPEARANCE",
          "appearanceOverride")),
    ):
        text = code[path]
        start = text.find(needle)
        if start < 0:
            out.append(f"{path}: no `{needle}` — the appearance read-back is gone")
            continue
        body = text[start:start + 700]
        # The arm ends at the next case/fn; 700 characters covers each.
        for word in banned:
            if word in body:
                out.append(
                    f"{path}: the expect_appearance reader names `{word}` — it "
                    f"must read the toolkit back, never what the app asked for"
                )

    # --- B4. The SOURCE word reads the toolkit's override SLOT, so a scene
    # that chose System holds on a host that is dark at night (the mac's
    # auto-switch, 2026-09-08): an empty slot is "system".
    for path, needle, slot in (
        (GTK, "fn appearance(&self) -> String {", "color_scheme()"),
        (WINUI, "fn appearance(&self) -> String {", "RequestedTheme()"),
        (MAC, 'case "expect_appearance":', "NSApp.appearance == nil"),
        (COMPOSE, '"expect_appearance" ->', "UI_MODE_NIGHT_MASK"),
    ):
        text = code[path]
        start = text.find(needle)
        if start < 0:
            continue  # B3 named the missing reader
        body = text[start:start + 1200]
        if slot not in body:
            out.append(
                f"{path}: the expect_appearance reader answers no source word — "
                f"it must read the toolkit's override slot (`{slot}`) and say "
                f"system or override"
            )

    # --- A4. The relaunching mechanism may not come back. ----------------
    # setApplicationNightMode changes the app's resource configuration,
    # which RELAUNCHES the activity; onCreate then runs twice in one
    # process and the second mount dies on a duplicate widget id. Measured
    # on the android lane 2026-08-27.
    if re.search(r"\.setApplicationNightMode\(", code[COMPOSE]):
        out.append(
            f"{COMPOSE}: setApplicationNightMode is back — it relaunches the "
            f"activity, onCreate runs twice in one process, and the second "
            f"mount panics on a duplicate widget id (the leg dies at ~63s "
            f"with no verdict)"
        )

    # --- A5. The ink verb reads the SURFACE's mode, never the ambient. ---
    # `UITraitCollection.current` is defined only inside a trait callback
    # or a view update, and kayaCanvasAppearance runs on the HARNESS
    # thread: measured on the ios lane 2026-08-27 it read the SYSTEM's
    # light while the raster was dark, per-boot stable. The file's two
    # other ambient reads are legitimate and deliberately not covered —
    # kayaBrandTint and kayaPlatformFont run only from view bodies.
    start = swift.find("func kayaCanvasAppearance()")
    if start < 0:
        out.append(
            f"{MAC}: no `func kayaCanvasAppearance()` — this clause is blind"
        )
    else:
        body = swift[start:start + 900]
        if "UITraitCollection.current" in body:
            out.append(
                f"{MAC}: kayaCanvasAppearance reads UITraitCollection.current "
                f"— that ambient value is undefined off a trait callback, and "
                f"the harness thread is exactly that; it reported the SYSTEM's "
                f"mode while the raster used the window's (ios lane, "
                f"2026-08-27). Read the window's own traitCollection"
            )
        if "traitCollection.userInterfaceStyle" not in body:
            out.append(
                f"{MAC}: kayaCanvasAppearance no longer reads a window's own "
                f"traitCollection — the mode must come from the surface whose "
                f"pixels the verb reports on, and it must stay a TOOLKIT "
                f"read-back so the dark leg cannot become self-fulfilling"
            )

    # --- B2. SwiftUI may not use .preferredColorScheme for this. ---------
    # It moves \.colorScheme and leaves NSApp.effectiveAppearance on the
    # host's — the two-reading divergence kayaCanvasAppearance warns of.
    if ".preferredColorScheme" in swift:
        out.append(
            f"{MAC}: .preferredColorScheme appears — it moves SwiftUI's "
            f"colorScheme but NOT NSApp.effectiveAppearance, so "
            f"kayaCanvasAppearance and KayaPresentationReporter would "
            f"report different modes (see kayaCanvasAppearance's comment)"
        )

    # --- C. One dark leg per lane. ---------------------------------------
    for path, spelling, lane in LEGS:
        if spelling not in src[path]:
            out.append(
                f"{path}: no `{spelling}` — the {lane} lane has no dark "
                f"canvas leg, so the dark half of expect_ink's frozen "
                f"string is asserted nowhere on it"
            )
    return out


g = Gate("check-appearance")
src = {p: g.read(p) for p in FILES}
for path, _spelling, _lane in LEGS:
    src[path] = g.read(path)
g.counted("files read", list(src), floor=11)

# ---- Watched negatives: the census's own refusals, made to fire. -------
# Each removes ONE link from a copy in memory, with the substitution count
# printed; a perturbation that applied nothing is a failed self-test.


def without(path, pattern, repl, label, *, want=1, flags=0):
    """`src` with one file doctored — the census's input, never the tree."""
    copy = dict(src)
    copy[path] = g.doctor(label, src[path], pattern, repl, want=want, flags=flags)
    return copy


g.negative(
    "N1 the GTK override deleted",
    lambda: census(without(
        GTK, r"adw::StyleManager::default\(\)\.set_color_scheme", "let _ = (", "N1")),
    want="GTK forces libadwaita's colour scheme",
)
g.negative(
    "N2 the WinUI override deleted",
    lambda: census(without(
        WINUI, r"element\.SetRequestedTheme\(want\)\?;", "()?;", "N2")),
    want="WinUI sets the content root's RequestedTheme",
)
g.negative(
    "N3 the Compose WINDOW BACKGROUND half deleted",
    lambda: census(without(
        COMPOSE, r"activity\.window\.setBackgroundDrawable\(", "noop(", "N3")),
    want="Compose moves the WINDOW BACKGROUND half",
)
g.negative(
    "N3b the Compose isSystemInDarkTheme half deleted",
    lambda: census(without(
        COMPOSE, r"CompositionLocalProvider\(LocalConfiguration provides forced",
        "run(", "N3b")),
    want="Compose moves the isSystemInDarkTheme half",
)
g.negative(
    "N3c the relaunching mechanism reintroduced",
    lambda: census(without(
        COMPOSE, r"activity\.window\.setBackgroundDrawable\(",
        "activity.getSystemService(UiModeManager::class.java)"
        ".setApplicationNightMode(", "N3c")),
    want="setApplicationNightMode is back",
)
g.negative(
    "N4 the macOS override installed UNCONDITIONALLY (the inert clause)",
    lambda: census(without(
        MAC, r"guard let mode = kayaAppearanceAsked\(\) else \{",
        "let mode = \"dark\"; if false {", "N4")),
    want="is not guarded by",
)
g.negative(
    "N5 the Rust reader answering for an ABSENT variable",
    lambda: census(without(
        CANVAS, r'std::env::var\("KAYA_APPEARANCE"\)\.ok\(\)\?',
        'Some(std::env::var("KAYA_APPEARANCE").unwrap_or_default())', "N5")),
    want="must install nothing",
)
g.negative(
    "N6 a bad value silently ignored instead of refused",
    lambda: census(without(
        CANVAS, r'other => panic!\("kaya: KAYA_APPEARANCE=\{other\} '
                r'is not a mode; use light or dark"\)',
        "_ => None", "N6")),
    want="no longer refused",
)
g.negative(
    "N7 WinUI reporting the ENV instead of reading ActualTheme back",
    lambda: census(without(
        WINUI, r"let mode = if element\.ActualTheme\(\)\? == ElementTheme::Dark",
        "let mode = if crate::canvas::appearance_override().is_some()", "N7")),
    want="read the TOOLKIT back",
)
g.negative(
    "N8 SwiftUI reaching for .preferredColorScheme",
    lambda: census(without(
        MAC, r"NSApp\.appearance = NSAppearance\(named:",
        ".preferredColorScheme(x); NSApp.appearance = NSAppearance(named:", "N8")),
    want="preferredColorScheme appears",
)
g.negative(
    "N9 the mac dark leg unwired",
    lambda: census(without(
        "tools/lib/lanes/mac.py", r'"canvasdark-rust-swiftui"',
        '"canvas-rust-swiftui"', "N9")),
    want="the mac lane has no dark canvas leg",
)
g.negative(
    "N10 the windows dark leg unwired",
    lambda: census(without(
        "tools/lib/lanes/win.py", r'"canvasdark_rust"', '"canvas_rust"', "N10")),
    want="the windows lane has no dark canvas leg",
)
g.negative(
    "N10b the ios dark leg unwired",
    lambda: census(without(
        "tools/lib/lanes/ios.py", r'"canvasdark-swift"', '"canvas-swift"',
        "N10b")),
    want="the ios lane has no dark canvas leg",
)
g.negative(
    "N11 the ink verb back on the ambient trait collection",
    lambda: census(without(
        MAC, r"window\.traitCollection\.userInterfaceStyle == \.dark",
        "UITraitCollection.current.userInterfaceStyle == .dark", "N11")),
    want="reads UITraitCollection.current",
)
g.negative(
    "N12 the Rust asked function no longer falling through to the knob",
    lambda: census(without(
        CANVAS, r"_ => appearance_override\(\),", "_ => None,", "N12")),
    want="no longer falls through",
)
g.negative(
    "N13 the mac expect_appearance arm echoing what the app asked for",
    lambda: census(without(
        MAC, r"let gotMode = DispatchQueue\.main\.sync \{ kayaCanvasAppearance\(\) \}",
        "let gotMode = DispatchQueue.main.sync { kayaAppearanceAsked() ?? \"light\" }",
        "N13")),
    want="must read the toolkit back",
)
g.negative(
    "N14 GTK's appearance read-back answering the asked function",
    lambda: census(without(
        GTK, r"if adw::StyleManager::default\(\)\.is_dark\(\) \{ \"dark\"\.to_string\(\) \}",
        "if crate::canvas::appearance_asked().is_some() { \"dark\".to_string() }", "N14")),
    want="must read the toolkit back",
)
g.negative(
    "N15 Compose's asked function no longer falling through to the knob",
    lambda: census(without(
        COMPOSE, r"else -> appearanceOverride", "else -> null", "N15")),
    want="no longer falls through",
)
g.negative(
    "N16 Compose's background half fed by the choice alone",
    lambda: census(without(
        COMPOSE, r"installAppearanceBackground\((\w+), appearanceAsked\(\)\)",
        r"installAppearanceBackground(\1, null)", "N16", want=2)),
    want="fed by the asked function",
)
g.negative(
    "N20 the mac reader's source word no longer reading the override slot",
    lambda: census(without(
        MAC, r'NSApp\.appearance == nil \? "system" : "override"', '"system"', "N20")),
    want="answers no source word",
)
g.negative(
    "N21 the iOS text-scale install no longer guarded by the asked function",
    lambda: census(without(
        MAC, r"if let factor = kayaTextScaleOverride\(\) \{",
        "if let factor = Optional(2.0) {", "N21")),
    want="is not guarded by",
)
g.negative(
    "N22 the text-scale read-back echoing the knob",
    lambda: census(without(
        MAC, r'guard let window = kayaHarnessWindow\(\) else \{ return 1\.0 \}',
        'if let want = ProcessInfo.processInfo.environment["KAYA_TEXT_SCALE"], '
        'let f = Double(want) { return f }\n'
        '        guard let window = kayaHarnessWindow() else { return 1.0 }', "N22")),
    want="derives its factor from the knob",
)
g.negative(
    "N23 the GTK text-scale install no longer guarded by the asked function",
    lambda: census(without(
        GTK, r"if let Some\(factor\) = crate::fmt::text_scale_override\(\) \{",
        "if let Some(factor) = Some(2.0) {", "N23")),
    want="is not guarded by",
)
g.negative(
    "N24 the Compose compliance installs no longer guarded by the inert clause",
    lambda: census(without(
        COMPOSE, r"if \(scale == null && locale == null\) \{", "if (false) {", "N24")),
    want="is not guarded by",
)
g.negative(
    "N25 the Compose text-scale read-back echoing the knob",
    lambda: census(without(
        COMPOSE, r"val got = onUi\(activity\) \{ kayaRootFontScale \}",
        "val got = KayaCompose.textScaleAsked() ?: 1.0", "N25")),
    want="derives its factor from the knob",
)
g.negative(
    "N26 the Compose locale read-back echoing the knob",
    lambda: census(without(
        COMPOSE, r'val got = onUi\(activity\) \{ kayaRootLocale\?\.toLanguageTag\(\) \?: "" \}',
        'val got = KayaCompose.localeAsked() ?: ""', "N26")),
    want="derives its answer from the knob",
)
g.negative(
    "N27 the WinUI locale read-back echoing the door's latch",
    lambda: census(without(
        WINUI, r"Ok\(element\.Language\(\)\?\.to_string\(\)\)",
        "Ok(crate::fmt::locale().tag)", "N27")),
    want="derives its answer from the knob",
)
g.negative(
    "N28 the WinUI text-scale read-back echoing the knob",
    lambda: census(without(
        WINUI,
        r"windows::UI::ViewManagement::UISettings::new\(\)\n\s*"
        r"\.and_then\(\|s\| s\.TextScaleFactor\(\)\)\n\s*\.unwrap_or\(1\.0\)",
        "crate::fmt::text_scale_override().unwrap_or(1.0)", "N28")),
    want="derives its factor from the knob",
)
g.negatives_ran(28)

# ---- The real census. --------------------------------------------------
for line in census(src):
    g.finding(line)

g.verdict(
    f"{len(INSTALLS)} install sites guarded, {len(LEGS)} lanes carry a dark "
    f"canvas leg, no reporter derives its mode from the variable"
)
