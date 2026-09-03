"""The iOS lane's tables — ONE source of truth for the legs the runner
derives and the gates census (docs/runner-conversion-plan.md §2, stage
2: run-sim). Plain data on the win module's model: no I/O at import, no
dev-shell guard.

The lane derives legs from FOUR SUITES rather than one explicit roster:
swift and go iterate their scene lists over one bundle recipe, python
carries every scene in one CPython bundle, and rust-swiftui builds one
cargo example per scene. The iPad legs ride beside their phone
siblings (form-factor coverage, not device-matrix breadth), and the
per-leg modifiers — the phone-expressible cuts and drops, the extras
only true on one device — are data here because they are what a leg
ASSERTS, not how the runner runs it.

The runner is tools/ios/run-sim.py; check-steps, check-appearance and
tools/lib/scene-features.py import this instead of regexing the shell
body's IOS_*_SCENES assignments.
"""

# The swift suite's roster, in build-and-queue order. An entry is `scene`
# or `scene:guest`, the source defaulting to the scene's own name and
# naming a different one where two scenes share an app: a scene selects a
# SCRIPT, never an app (`listdetail:split` is the only such pair).
SWIFT_ENTRIES = [
    "milestone2", "stall", "entry", "gallery", "todos",
    "reorder", "feed", "grow", "align", "layout",
    "confirm", "nav", "listdetail:split", "scroll", "progress",
    "select", "radio", "grid", "textarea", "sections",
    "menus", "commands", "a11y", "a11yrows", "clipboard",
    "background", "undo", "ranges", "dirty", "filedialog",
    "save", "styling", "toolbar", "identity", "assets",
    "table", "canvas", "sizepolicy",
]

# The go suite: the swift roster entry for entry minus the two
# rust-only canvas scenes, plus `editor` off-list below — a Go app with
# no swift guest to mirror (docs/editor-plan.md).
GO_SCENES = [
    "milestone2", "stall", "entry", "gallery", "todos",
    "reorder", "feed", "grow", "align", "layout",
    "confirm", "nav", "listdetail", "scroll", "progress",
    "select", "radio", "grid", "textarea", "sections",
    "menus", "commands", "a11y", "a11yrows", "clipboard",
    "background", "undo", "ranges", "dirty", "filedialog",
    "save", "styling", "toolbar", "identity", "assets",
    "table",
]

# CPython embedded in ONE bundle carrying every python scene
# (docs/python-mobile-plan.md).
PYTHON_SCENES = ["portfolio", "varied"]

# The rust-swiftui suite: one cargo example per scene, milestone2 first
# (its leg is the bare `rust-swiftui`). The EXAMPLE a scene builds is
# its own name except listdetail, which drives the split example — the
# same script-not-app rule as the swift roster's `listdetail:split`.
RUST_SCENES = [
    "milestone2",
    "entry", "todos", "gallery", "reorder", "feed",
    "grow", "align", "layout", "stall", "confirm",
    "nav", "scroll", "filedialog", "save", "clipboard",
    "a11y", "a11yrows", "styling", "ranges", "progress",
    "menus", "toolbar", "identity", "assets", "listdetail",
    "table", "windowed", "adaptive", "commands", "undo",
    "dirty",
]

# The iPad legs, queued right after their phone sibling: the phone pool is
# ALWAYS compact, so these are the only observations of the regular-width
# lowering. The value is the leg's EXTRA step; table's is empty by
# decision 5's design — the tiers present identical bytes, and the leg
# buys that the native path executes at all.
PAD_EXTRAS = {
    "menus": 'expect_menu_presentation "regular/bar"',
    "listdetail": 'expect_split "regular/split"',
    "table": "",
}

# Machine-read by check-steps' wired(): a scene is wired on this lane IF
# AND ONLY IF a suite lists it, or it is declared here. window/panels
# drive chrome no phone has; split/panes drive resize_window, which this
# host rejects by design (DESIGN.md, Windows).
DESKTOP_ONLY_SCENES = ["window", "panels", "split", "panes"]
# Scenes whose GUEST cannot run here yet. Empty since 2026-08-28 (the
# packaging milestone wired the two python scenes).
UNWIRED_SCENES = []

# Per-leg modifiers, keyed (suite, scene). `cut` names the verb this host
# cannot express (everything from it on is dropped, printed); `drop` names
# ONE step by verb and target; `keep` names the assertions neither may
# take with it; `extra` appends steps only true on this device.
MODS = {
    # The declared NAME is read off an auxiliary window this host does
    # not have; the icon reads survive (docs/app-identity-plan.md
    # ruling 3).
    ("swift", "identity"): {"drop": ("expect_title", "window#1"),
                            "keep": "expect_app_icon"},
    ("go", "identity"): {"drop": ("expect_title", "window#1"),
                         "keep": "expect_app_icon"},
    ("rust-swiftui", "identity"): {"drop": ("expect_title", "window#1"),
                                   "keep": "expect_app_icon"},
    # The sections tail opens an aux window rejected by capability.
    ("swift", "sections"): {"cut": "expect_windows",
                            "keep": "expect_section expect_section_symbol"},
    ("go", "sections"): {"cut": "expect_windows",
                         "keep": "expect_section expect_section_symbol"},
    # dirty's last six steps hang off a chrome close; iOS's close
    # grammar is macOS-only (docs/dirty-plan.md D4).
    ("swift", "dirty"): {"cut": "close_window", "keep": "expect_dirty"},
    ("go", "dirty"): {"cut": "close_window", "keep": "expect_dirty"},
    ("rust-swiftui", "dirty"): {"cut": "close_window",
                                "keep": "expect_dirty"},
    # The editor opens both pickers and ends past a chrome close
    # (docs/editor-plan.md).
    ("go", "editor"): {"cut": "close_window", "keep": "expect_dirty"},
    # The portfolio's fold block sits at the scene's END
    # (docs/adaptive-layout-plan.md D7): the cut takes the
    # resize-driven round trip a phone cannot command, the extra
    # asserts the always-stacked truth this host CAN express.
    ("python", "portfolio"): {
        "extra": "expect_folded column@summary column@ledger",
        "cut": "resize_window",
        "keep": "expect_window=column@ledger"},
    # The adaptive breakpoint's phone side: an always-narrow window
    # applies at its first report, no resize ever
    # (docs/adaptive-layout-plan.md §2).
    ("rust-swiftui", "adaptive"): {
        "extra": 'expect_axis row@narrow "vertical"',
        "cut": "resize_window",
        "keep": "expect_axis=row@dash expect_axis=column@steady"},
}

SUITES = ("swift", "go", "python", "rust-swiftui")


def swift_scene(entry):
    """(scene, guest source) for a swift roster entry."""
    scene, _, src = entry.partition(":")
    return scene, src or scene


def rust_example(scene):
    """The cargo example a rust-swiftui scene builds."""
    return "split" if scene == "listdetail" else scene


def suite_legs(suite):
    """The suite's leg names, in queue order."""
    out = []
    if suite == "swift":
        for entry in SWIFT_ENTRIES:
            scene, _src = swift_scene(entry)
            if scene == "milestone2":
                out.append("swift")
            elif scene == "canvas":
                # Both appearances, one bundle: the dark leg is the
                # appearance override's set proof (docs/canvas-plan.md
                # phase 4; check-appearance holds the leg here).
                out += ["canvas-swift", "canvasdark-swift"]
            else:
                out.append(f"{scene}-swift")
    elif suite == "go":
        for scene in GO_SCENES:
            out.append("go" if scene == "milestone2" else f"{scene}-go")
        out.append("editor-go")
    elif suite == "python":
        out += [f"{scene}-python" for scene in PYTHON_SCENES]
    elif suite == "rust-swiftui":
        for scene in RUST_SCENES:
            if scene == "milestone2":
                out.append("rust-swiftui")
                continue
            out.append(f"{scene}-swiftui")
            if scene in PAD_EXTRAS:
                out.append(f"{scene}-swiftui-pad")
    return out


def legs():
    """Every leg, suites in run order."""
    return [leg for suite in SUITES for leg in suite_legs(suite)]


def wired_scenes():
    """The scenes some suite runs — check-steps' wired() reads this."""
    out = {swift_scene(e)[0] for e in SWIFT_ENTRIES}
    out.update(GO_SCENES)
    out.update(PYTHON_SCENES)
    out.update(RUST_SCENES)
    out.add("editor")
    return out
