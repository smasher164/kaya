"""The mac lane's tables — ONE source of truth for the legs the runner
derives and the gates census (docs/runner-conversion-plan.md §2, stage
4: validate-mac). Plain data on the win/ios/android modules' model: no
I/O at import, no dev-shell guard.

One backend (the SwiftUI interpreter), eight hosted languages plus the
C floor, ~350 legs. ORDER is the queue itself: scene groups with their
language order (the order VARIES per scene and is data — dirty carries
no java leg at all, styling puts swift fourth), drain barriers as
explicit entries, the three panel view modes as entries between the
filedialog groups, and the serial families (save, clipboard, undo,
editor — one leg per drain pair, each for a measured reason recorded
at the runner's sites) as single-language groups between drains.

The runner is tools/validate-mac.py; check-steps, check-staging,
check-appearance, check-stubs and tools/lib/scene-features.py import
this instead of regexing the shell body.
"""

# THE scene list: the mechanical per-scene surfaces derive from it —
# the cargo --example flags, the rust-guest staging, build_swift's
# sweep. Order preserved from the shell body's one line.
SCENES = [
    "background", "stall", "milestone2", "entry", "gallery", "todos",
    "reorder", "feed", "grow", "layout", "align", "window", "panels",
    "confirm", "nav", "split", "panes", "table", "scroll", "progress",
    "select", "radio", "grid", "textarea", "sections", "menus",
    "commands", "a11y", "a11yrows", "filedialog", "clipboard", "undo",
    "dirty", "ranges", "save", "styling", "toolbar", "identity",
    "assets", "sizepolicy", "adaptive",
]
# Depth-slice scenes: a rust example + steps exist, the language sweep
# has not landed — built and run rust-only until their guests arrive,
# when they move into SCENES.
DEPTH_SCENES = ["typeface", "windowed", "canvas"]
# The C-floor scenes THIS LANE RUNS (guests/c/Makefile keeps the whole
# list; this is the SCENES= override build_c passes, and check-steps'
# sweep_c_floor reads it from the other side).
C_SCENES = ["undo", "dirty", "ranges", "save", "a11yrows", "styling",
            "assets"]

# The nine hosted languages in their DEFAULT group order; a group
# that deviates spells its own order in ORDER below. js is the ninth
# binding (docs/js-plan.md), python's ambient twin, and rides every
# group python rides.
LANGS = ("rust", "python", "go", "csharp", "ocaml", "haskell", "swift",
        "java", "js")

# Scene -> the guest STEM its scene-named launchers run, where the two
# differ: the listdetail legs run split's guests (a scene selects a
# SCRIPT, never an app). editor/portfolio/varied are single-language
# apps whose launchers already name the right artifact.
GUEST_STEM = {"listdetail": "split"}

# The dark half of expect_ink's frozen string, one leg instead of a
# lane re-run (tools/check-appearance.py holds the leg here): canvas's
# script and binary under KAYA_APPEARANCE=dark.
DARK_LEG = ("canvasdark-rust-swiftui", "canvas", "rust")

# The apps and depth scenes hand-queued OUTSIDE SCENES/DEPTH_SCENES
# (each would otherwise derive a cargo --example that does not exist):
# editor is a GO app by design, portfolio and varied are PYTHON alone.
HAND_QUEUED = {"editor": "go", "portfolio": "python", "varied": "python"}

# The queue, in run order. Entries:
#   (scene, (lang, ...))    a group: script export + one leg per lang
#   ("drain",)              the pool barrier
#   ("panel_mode", n, name) rotate the machine-wide file-panel view
#                           mode before the group that follows
#   ("panel_check",)        the modes-run census + restore, after the
#                           last filedialog group
#   ("dark_leg",)           the canvasdark leg (DARK_LEG above)
#
# The single-language groups between drains ARE the serial families;
# the measured reasons live at the runner's sites (the save panel's
# machine-wide last-directory preference, 2026-08-10; the one system
# clipboard; the undo scene's real keystrokes; the editor's chrome
# plus keys).
ORDER = [
    ("milestone2", LANGS),
    ("entry", LANGS),
    ("gallery", LANGS),
    ("todos", LANGS),
    ("reorder", LANGS),
    ("feed", LANGS),
    ("grow", LANGS),
    ("drain",),
    ("window", LANGS),
    ("panels", LANGS),
    ("nav", LANGS),
    ("split", LANGS),
    ("panes", LANGS),
    ("table", LANGS),
    ("listdetail", LANGS),
    ("background", LANGS),
    # The eight filedialog legs SPLIT ACROSS THE THREE PANEL VIEW
    # MODES, a drain before each mode because a mode is set for
    # whatever is running, not for a leg.
    ("drain",),
    ("panel_mode", 1, "columns"),
    ("filedialog", ("rust", "python", "go")),
    ("drain",),
    ("panel_mode", 2, "list"),
    ("filedialog", ("csharp", "ocaml", "haskell")),
    ("drain",),
    ("panel_mode", 3, "icons"),
    ("filedialog", ("swift", "java", "js")),
    ("drain",),
    ("panel_check",),
    # EACH SAVE LEG ALONE BETWEEN DRAINS: macOS shares a save panel's
    # last directory as a user preference across every process
    # (measured 2026-08-10).
    ("save", ("rust",)),
    ("drain",),
    ("save", ("java",)),
    ("drain",),
    ("save", ("python",)),
    ("drain",),
    ("save", ("go",)),
    ("drain",),
    ("save", ("swift",)),
    ("drain",),
    ("save", ("haskell",)),
    ("drain",),
    ("save", ("csharp",)),
    ("drain",),
    ("save", ("ocaml",)),
    ("drain",),
    ("save", ("c",)),
    ("drain",),
    ("save", ("js",)),
    ("drain",),
    # The text editor: go alone by design, alone between drains (real
    # panels, real keys).
    ("editor", ("go",)),
    ("drain",),
    ("portfolio", ("python",)),
    ("drain",),
    ("varied", ("python",)),
    ("drain",),
    ("windowed", ("rust",)),
    ("drain",),
    ("adaptive", LANGS),
    ("drain",),
    ("a11yrows", (*LANGS, "c")),
    ("drain",),
    ("styling", ("rust", "python", "go", "swift", "csharp", "ocaml",
                 "haskell", "java", "js", "c")),
    ("drain",),
    ("typeface", ("rust",)),
    ("drain",),
    ("canvas", ("rust",)),
    ("dark_leg",),
    ("drain",),
    ("sizepolicy", LANGS),
    ("drain",),
    ("toolbar", ("rust", "python", "go", "swift", "csharp", "ocaml",
                 "haskell", "java", "js")),
    ("drain",),
    ("identity", ("rust", "python", "go", "swift", "csharp", "ocaml",
                  "haskell", "java", "js")),
    ("drain",),
    ("assets", ("rust", "python", "go", "swift", "csharp", "ocaml",
                "haskell", "java", "js", "c")),
    ("drain",),
    # EACH CLIPBOARD LEG ALONE BETWEEN DRAINS: one system clipboard
    # per session (check-steps pins the drain/run/drain bracket).
    ("clipboard", ("rust",)),
    ("drain",),
    ("clipboard", ("python",)),
    ("drain",),
    ("clipboard", ("go",)),
    ("drain",),
    ("clipboard", ("swift",)),
    ("drain",),
    ("clipboard", ("csharp",)),
    ("drain",),
    ("clipboard", ("ocaml",)),
    ("drain",),
    ("clipboard", ("haskell",)),
    ("drain",),
    ("clipboard", ("java",)),
    ("drain",),
    ("clipboard", ("js",)),
    ("drain",),
    # EACH UNDO LEG ALONE BETWEEN DRAINS: the type verb delivers real
    # keystrokes.
    ("undo", ("rust",)),
    ("drain",),
    ("undo", ("python",)),
    ("drain",),
    ("undo", ("go",)),
    ("drain",),
    ("undo", ("c",)),
    ("drain",),
    ("undo", ("haskell",)),
    ("drain",),
    ("undo", ("swift",)),
    ("drain",),
    ("undo", ("csharp",)),
    ("drain",),
    ("undo", ("ocaml",)),
    ("drain",),
    ("undo", ("java",)),
    ("drain",),
    ("undo", ("js",)),
    ("drain",),
    ("scroll", LANGS),
    ("progress", LANGS),
    ("select", LANGS),
    ("radio", LANGS),
    ("grid", LANGS),
    ("textarea", LANGS),
    ("sections", LANGS),
    ("menus", LANGS),
    ("a11y", LANGS),
    ("commands", LANGS),
    ("stall", LANGS),
    ("confirm", LANGS),
    # NO JAVA LEG in the dirty group — real coverage, not an
    # oversight (the sugar's java arm has no dirty guest yet); order
    # follows the per-binding commentary at the runner's site.
    ("dirty", ("rust", "python", "ocaml", "c", "go", "haskell",
               "swift", "csharp", "js")),
    ("ranges", ("rust", "python", "c", "csharp", "go", "java",
                "haskell", "swift", "ocaml", "js")),
    ("align", LANGS),
    ("drain",),
    ("layout", LANGS),
    ("drain",),
]


def leg_name(scene, lang):
    """milestone2's legs ARE the unprefixed originals."""
    if scene == "milestone2":
        return f"{lang}-swiftui"
    return f"{scene}-{lang}-swiftui"


def guest_stem(scene):
    """The artifact stem a scene-named launcher runs."""
    return GUEST_STEM.get(scene, scene)


def legs():
    """Every leg as (name, scene, lang), queue order."""
    out = []
    for entry in ORDER:
        if entry[0] == "dark_leg":
            name, scene, lang = DARK_LEG
            out.append((name, scene, lang))
        elif entry[0] not in ("drain", "panel_mode", "panel_check"):
            scene, langs = entry
            out.extend((leg_name(scene, lang), scene, lang)
                       for lang in langs)
    return out


def blocks():
    """Leg names grouped between drains — the serial families are the
    single-leg blocks."""
    out = [[]]
    for entry in ORDER:
        if entry[0] == "drain":
            if out[-1]:
                out.append([])
        elif entry[0] == "dark_leg":
            out[-1].append(DARK_LEG[0])
        elif entry[0] not in ("panel_mode", "panel_check"):
            scene, langs = entry
            out[-1].extend(leg_name(scene, lang) for lang in langs)
    if not out[-1]:
        out.pop()
    return out


def wired_scenes():
    """The scenes some leg runs — the gates' census surface."""
    return {scene for _name, scene, _lang in legs()}


# THE LEG'S COMMAND AND SCRIPT, one copy: tools/validate-mac.py runs the
# roster through these, and tools/run-leg.py runs ONE leg by hand through
# the same two — a hand run that spelled its own env once ran a stale
# interpreter for a whole failure (2026-09-01, docs/traps.md).
KAYA_LIB_LANGS = ("csharp", "ocaml", "java")
RUST_GUESTS = "target/rust-guests"
CS_GUEST = "guests/csharp/bin/Debug/net10.0/kaya-guests.dll"


def leg_argv(scene, lang, hs_bin):
    """The guest command for one leg; `hs_bin(stem)` resolves a Haskell
    binary (cabal list-bin) so this module does no I/O of its own."""
    stem = guest_stem(scene)
    if lang == "rust":
        return [f"{RUST_GUESTS}/{stem}"]
    if lang == "python":
        return ["python3", f"guests/python/{stem}.py"]
    if lang == "js":
        return ["node", f"guests/js/{stem}.ts"]
    if lang == "go":
        return ["target/go-guests/kaya-go"]
    if lang == "csharp":
        return ["dotnet", "exec", CS_GUEST]
    if lang == "ocaml":
        return [f"_build/default/guests/ocaml/{stem}.exe"]
    if lang == "haskell":
        return [hs_bin(stem)]
    if lang == "swift":
        return [f"target/swift-guests/{stem}"]
    if lang == "java":
        return ["java", "-XstartOnFirstThread", "-cp",
                "target/java-guests", "dev.kaya.guests.Main"]
    if lang == "c":
        return [f"target/c-guests/{stem}"]
    raise ValueError(lang)


def scene_script(root, scene):
    """The scene script's TEXT for the interpreter's environment, comments
    stripped: some transports fold newlines into `;`, and a leading
    comment must not swallow the folded script. Newlines are kept."""
    lines = [line for line in
             (root / f"tools/scenes/{scene}.steps").read_text(
                 encoding="utf-8").splitlines()
             if not line.startswith("#")]
    return "\n".join(lines)


def leg_env(root, scene, lang, appearance=""):
    """Per-leg env, never a persisting export (the shell's one
    KAYA_SELFTEST_SCRIPT export once ran another scene's steps)."""
    env = {"KAYA_SELFTEST": "1" if scene == "milestone2" else scene,
           "KAYA_SELFTEST_SCRIPT": scene_script(root, scene),
           "KAYA_SWIFTUI_LIB": str(root / "target/swiftui/libkaya_swiftui.dylib")}
    if lang in KAYA_LIB_LANGS:
        env["KAYA_LIB"] = str(root / "target/debug/libkaya.dylib")
    if lang == "python":
        env["PYTHONPATH"] = str(root / "bindings/python")
    if appearance:
        env["KAYA_APPEARANCE"] = appearance
    return env

