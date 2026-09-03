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
GUARD_SWIFT = r"guard let mode = kayaAppearanceOverride\(\) else \{ return \}"
GUARD_RUST = r"if let Some\(mode\) = crate::canvas::appearance_override\(\)"
GUARD_KT = r'System\.getenv\("KAYA_APPEARANCE"\) \?: return'
# KayaAppearance's own early-out, the composition half's inert clause.
GUARD_KT_UI = r"if \(want == null\) \{"

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
    (ENTRY, r"kayaApplyAppearanceOverride\(\)", None,
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
    (COMPOSE, r"activity\.window\.setBackgroundDrawable\(", GUARD_KT,
     "Compose moves the WINDOW BACKGROUND half"),
    (COMPOSE, r"CompositionLocalProvider\(LocalConfiguration provides forced",
     GUARD_KT_UI,
     "Compose moves the isSystemInDarkTheme half"),
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
        MAC, r"guard let mode = kayaAppearanceOverride\(\) else \{ return \}",
        "let mode = \"dark\"", "N4")),
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
g.negatives_ran(14)

# ---- The real census. --------------------------------------------------
for line in census(src):
    g.finding(line)

g.verdict(
    f"{len(INSTALLS)} install sites guarded, {len(LEGS)} lanes carry a dark "
    f"canvas leg, no reporter derives its mode from the variable"
)
