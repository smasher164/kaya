"""The Android lane's tables — ONE source of truth for the legs the
runner derives and the gates census (docs/runner-conversion-plan.md §2,
stage 3: run-emulator). Plain data on the win and ios modules' model:
no I/O at import, no dev-shell guard.

Four suites over one leg machinery: compose (the rust guest on the
Compose interpreter), jvm (the Kotlin guest over the ring tier), go
(a c-shared .so the shell Activity loads), python (CPython in one APK).
The tablet leg rides beside its pool sibling (this lane's iPad — one
device carrying one scene, form-factor coverage), the remount legs are
the ordinary leg with the Activity relaunched mid-scene, and the
per-leg modifiers — cuts, drops, appends, KAYA_ASSET_DIR, the dark
appearance — are data because they are what a leg ASSERTS.

The runner is tools/android/run-emulator.py; check-steps,
check-appearance, tools/lib/scene-features.py and
tools/lib/android-leg-order.py import this instead of regexing the
shell body.
"""

# Per-suite artifact, package and activity — the app every leg of the
# suite installs once (the staging barrier) and starts per leg.
SUITE_APPS = {
    "compose": ("android/rusthost/build/outputs/apk/debug/"
                "rusthost-debug.apk", "dev.kaya.rusthost",
                ".MainActivity"),
    "jvm": ("android/javahost/build/outputs/apk/debug/"
            "javahost-debug.apk", "dev.kaya.javahost",
            ".MainActivity"),
    "go": ("android/gohost/build/outputs/apk/debug/"
           "gohost-debug.apk", "dev.kaya.gohost",
           ".MainActivity"),
    "python": ("android/pyhost/build/outputs/apk/debug/pyhost-debug.apk",
               "dev.kaya.pyhost", ".MainActivity"),
}

SUITES = ("compose", "jvm", "go", "python")

# The roster, per suite and in queue order. Leg names are the census
# surface every gate reads; the exceptions ride FLAGS below.
LEGS = {
    "compose": [
        "compose", "a11y-compose", "entry-compose",
        "gallery-compose", "todos-compose", "remount-compose",
        "remount-nav-compose", "reorder-compose", "table-compose",
        "windowed-compose", "canvas-compose", "canvasdark-compose",
        "sizepolicy-compose", "adaptive-compose", "feed-compose",
        "grow-compose", "align-compose", "layout-compose",
        "stall-compose", "confirm-compose", "filedialog-compose",
        "save-compose", "nav-compose", "scroll-compose",
        "progress-compose", "select-compose", "radio-compose",
        "grid-compose", "textarea-compose", "sections-compose",
        "menus-compose", "toolbar-compose", "identity-compose",
        "listdetail-compose", "listdetail-compose-tablet", "commands-compose",
        "a11yrows-compose", "styling-compose", "typeface-compose",
        "assets-compose", "clipboard-compose", "background-compose",
        "undo-compose", "dirty-compose", "ranges-compose",
    ],
    "jvm": [
        "jvm", "a11y-jvm", "entry-jvm",
        "gallery-jvm", "todos-jvm", "remount-jvm",
        "reorder-jvm", "feed-jvm", "grow-jvm",
        "align-jvm", "layout-jvm", "stall-jvm",
        "confirm-jvm", "nav-jvm", "scroll-jvm",
        "progress-jvm", "select-jvm", "radio-jvm",
        "grid-jvm", "textarea-jvm", "sections-jvm",
        "menus-jvm", "toolbar-jvm", "identity-jvm",
        "listdetail-jvm", "commands-jvm", "clipboard-jvm",
        "background-jvm", "undo-jvm", "filedialog-jvm",
        "table-jvm", "save-jvm", "dirty-jvm",
        "ranges-jvm", "styling-jvm", "typeface-jvm",
        "assets-jvm",
    ],
    "go": [
        "go", "a11y-go", "a11yrows-go",
        "styling-go", "typeface-go", "assets-go",
        "entry-go", "gallery-go", "todos-go",
        "remount-go", "reorder-go", "table-go",
        "feed-go", "grow-go", "align-go",
        "layout-go", "stall-go", "confirm-go",
        "nav-go", "scroll-go", "progress-go",
        "select-go", "radio-go", "grid-go",
        "textarea-go", "sections-go", "menus-go",
        "toolbar-go", "identity-go", "listdetail-go",
        "commands-go", "clipboard-go", "background-go",
        "undo-go", "filedialog-go", "save-go",
        "dirty-go", "ranges-go", "editor-go",
    ],
    "python": [
        "varied-python", "portfolio-python",
    ],
}

# THE RECREATION LEGS' SCENE and the statement they cut in half:
# `todos` because the model it re-projects is EARNED, and the cut is
# after `expect_focused`, the last statement that reads view-local
# state (docs/deferred.md's mount entry).
REMOUNT_SCENE = "todos"
REMOUNT_STEP = 6
REMOUNT_LINE = "KAYA_REMOUNT: recreating after step 6 (expect_focused entry#0)"

# Per-leg exceptions, keyed by LEG NAME: `scene` where the name does not
# spell it, `tablet` for the one lockless-device leg, `remount` as
# (step, expected-line), `asset_dir` for KAYA_ASSET_DIR, `appearance` for
# the dark override, `append` for steps only true on this device.
# Everything else derives from `<scene>-<suite>`.
FLAGS = {
    "remount-compose": {"scene": REMOUNT_SCENE,
                        "remount": (REMOUNT_STEP, REMOUNT_LINE)},
    "remount-jvm": {"scene": REMOUNT_SCENE,
                    "remount": (REMOUNT_STEP, REMOUNT_LINE)},
    "remount-go": {"scene": REMOUNT_SCENE,
                   "remount": (REMOUNT_STEP, REMOUNT_LINE)},
    # The per-window half todos cannot reach: nav's title is
    # materialized ON THE ACTIVITY, and KAYA_APPEARANCE makes the
    # override's per-window background write something the re-attach
    # has to do again.
    "remount-nav-compose": {
        "scene": "nav",
        "remount": (4, "KAYA_REMOUNT: recreating after step 4 "
                       "(expect_entries 1)"),
        "appearance": "dark"},
    # The dark half of expect_ink's frozen string, one leg instead of a
    # lane re-run (check-appearance holds the leg here).
    "canvasdark-compose": {"scene": "canvas", "appearance": "dark"},
    # The one leg on the 1280dp tablet, and the two appended claims the
    # shared file may not carry — the split literal, and the BACK rule
    # (with both panes on screen back reveals nothing, so it must not
    # pop). The only leg in any lane reaching Compose's split arm.
    "listdetail-compose-tablet": {
        "scene": "listdetail", "tablet": True,
        "append": 'expect_split "regular/split";back;expect_entries 1;'
                  'expect_split "regular/split"'},
    # KAYA_ASSET_DIR riders: the identity and typeface legs resolve the
    # pushed root; the assets legs on compose and go deliberately carry
    # NONE (the APK route is the assertion), while assets-jvm reads the
    # pushed root.
    "identity-compose": {"asset_dir": True},
    "identity-jvm": {"asset_dir": True},
    "identity-go": {"asset_dir": True},
    "typeface-compose": {"asset_dir": True},
    "typeface-jvm": {"asset_dir": True},
    "typeface-go": {"asset_dir": True},
    "assets-jvm": {"asset_dir": True},
}

# Script modifiers, keyed by SCENE and shared by every suite that runs it
# — the two mobile lanes take the same list and grammar, since two
# answers to one question is how lanes drift. `cut` is
# (verb, keep, extra-for-validation); `append` rides after the cut's
# prefix. The reasons live at the runner's sites and the plans.
MODS = {
    "sections": {"cut": ("expect_windows",
                         "expect_section expect_section_symbol", "")},
    "adaptive": {"cut": ("resize_window",
                         "expect_axis=row@dash expect_axis=column@steady",
                         'expect_axis row@narrow "vertical"'),
                 "append": 'expect_axis row@narrow "vertical";'},
    "portfolio": {"cut": ("resize_window", "expect_window=column@ledger",
                          "expect_folded column@summary column@ledger"),
                  "append": "expect_folded column@summary column@ledger;"},
    "dirty": {"cut": ("close_window", "expect_dirty", ""),
              "append": 'expect_title "dirty"'},
    "editor": {"cut": ("close_window", "expect_dirty", "")},
    "identity": {"drop": ("expect_title", "window#1", "expect_app_icon")},
}

# Machine-derived by tools/lib/android-leg-order.py from the shared
# verbs: the scenes that leave the app for DocumentsUI (the
# accessibility service), and the one that opens a composing region
# (the helper IME).
A11Y_SCENES = ["filedialog", "save", "editor"]
IME_SCENES = ["ranges"]

# A scene is wired on this lane IF AND ONLY IF a suite lists it, or it
# is declared here. window/panels drive aux windows and panel chrome no
# phone has; split/panes drive resize_window, which this host rejects
# by design (the system owns surfaces; DESIGN.md, Windows).
DESKTOP_ONLY_SCENES = ["window", "panels", "split", "panes"]
UNWIRED_SCENES = []


def scene_of(leg):
    """The scene a leg drives. The bare suite names are milestone2's
    (the unprefixed default arm); FLAGS overrides the rest."""
    flags = FLAGS.get(leg, {})
    if "scene" in flags:
        return flags["scene"]
    if leg in SUITES:
        return "milestone2"
    for suffix in ("-compose", "-jvm", "-go", "-python"):
        if leg.endswith(suffix):
            return leg[: -len(suffix)]
    raise ValueError(f"unrecognized leg name {leg!r}")


def suite_legs(suite):
    return list(LEGS[suite])


def legs():
    """Every leg, suites in run order."""
    return [leg for suite in SUITES for leg in LEGS[suite]]


def wired_scenes():
    """The scenes some leg runs — the gates' census surface."""
    return {scene_of(leg) for leg in legs()}
