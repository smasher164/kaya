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

THE PER-LANGUAGE GUEST BUILDS LIVE HERE TOO, one copy, called and never
copied: validate-mac.py runs all seven pooled and tools/run-leg.py runs
the one its leg needs under --build. They do I/O when CALLED, never at
import, so every census above still imports this module for its tables
alone.
"""

import os
import pathlib
import re
import shutil
import subprocess
import sys
import threading
import time

import content_fresh
import exclusive
import media_server
import scene_cut

# THE scene list: the mechanical per-scene surfaces derive from it —
# the cargo --example flags, the rust-guest staging, build_swift's
# sweep. Order preserved from the shell body's one line.
SCENES = [
    "background", "stall", "milestone2", "entry", "gallery", "todos",
    "reorder", "feed", "grow", "layout", "align", "window", "panels",
    "confirm", "nav", "split", "panes", "table", "scroll", "scrollto", "fullscreen",
    "progress",
    "select", "radio", "grid", "textarea", "sections", "menus", "rowmenu",
    "commands", "a11y", "a11yrows", "filedialog", "clipboard", "undo",
    "dirty", "ranges", "save", "styling", "toolbar", "identity",
    "assets", "sizepolicy", "adaptive", "pickers", "sliders",
    "tooltips", "search", "richtext", "ownundo", "richlabel", "sheet",
    "submit", "numberfield", "timecode", "colorpicker", "range",
    "secure", "autofill", "reveal", "segmented", "toast", "expander",
    "safearea", "netimage", "netimage_http",
    "grounds", "shapes", "cards", "tracks", "dock",
    # docs/code-surface-plan.md §5.
    "codesurface",
]
# Depth-slice scenes: a rust example + steps exist, the language sweep
# has not landed — built and run rust-only until their guests arrive,
# when they move into SCENES.
DEPTH_SCENES = ["typeface", "windowed", "canvas", "dnd", "tasks", "notify", "notes", "richrows",
                "format", "flexshrink", "listrow", "tints", "badge", "emoji", "media",
                # The capture (docs/capture-plan.md §8), rust-only at depth.
                "capture"]
# The C-floor scenes THIS LANE RUNS (guests/c/Makefile keeps the whole
# list; this is the SCENES= override build_c passes, and check-steps'
# sweep_c_floor reads it from the other side).
C_SCENES = ["undo", "dirty", "ranges", "save", "a11yrows", "styling",
            "assets",
            # The formatter door at the floor (docs/compliance-plan.md §1.4).
            "format",
            # The segmented control at the floor (docs/segmented-plan.md G12).
            "segmented",
            # The toast at the floor (docs/toast-plan.md T15).
            "toast",
            # The expander at the floor (docs/expander-plan.md K18).
            "expander",
            # The safe area at the floor (docs/safe-area-plan.md A16).
            "safearea",
            # Network images at the floor (docs/network-images-plan.md N16).
            "netimage",
            # The skin at the floor (docs/styling-pass-plan.md Y10).
            "grounds", "shapes", "cards", "tracks", "dock"]

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
GUEST_STEM = {"listdetail": "split", "taskspersist": "tasks", "windowmem": "split",
              "links": "tasks", "formatde": "format", "formatar": "format",
              "tasksrtl": "tasks", "clock24": "format", "scrollrtl": "scroll",
              "numberfieldde": "numberfield", "numberfieldar": "numberfield",
              "rangertl": "range",
              "media_formats": "media", "media_delivery": "media",
              "media_session": "media", "media_tracks": "media", "media_feed": "media",
              "media_picked": "media", "media_timeout": "media",
              "media_reader": "media", "capture_denied": "capture",
              "music_home": "music", "music_playlist": "music", "music_header": "music",
              "music_dock": "music", "music_artist": "music", "music_search": "music",
              "music_context": "music"}

# THE LOCALE A SCENE RUNS UNDER (docs/compliance-plan.md §4): the knob the
# leg carries, so the same guest is read under German and Arabic; the
# platform installs it and the reads ask the platform, never this table.
SCENE_LOCALE = {"formatde": "de-DE", "formatar": "ar-EG", "tasksrtl": "ar-EG",
                "scrollrtl": "ar-EG", "numberfieldde": "de-DE", "numberfieldar": "ar-EG",
                "rangertl": "ar-EG"}

# THE SCENES THIS LANE CUTS, through tools/lib/scene_cut.py, the phones'
# census, which check-steps runs over this table too. The eye's Tab reach is
# the system's Keyboard navigation setting's, which no lane turns on
# (docs/reveal-plan.md V10).
CUTS = {"reveal": {"cut": "press tab", "keep": "expect_unmasked expect_masked"}}

# The scenes this lane DECLARES OFF, each with its reason, read by
# tools/check-steps.py beside the phones' declarations: macOS has no text
# size, so a knob that scales one is refused there (docs/compliance-plan.md
# R4) and the two scale scenes run on the other four lanes.
OFF_SCENES = {"tasksbig": "macOS has no text size (docs/compliance-plan.md R4)",
              "formatbig": "macOS has no text size (docs/compliance-plan.md R4)",
              "codesurfacebig": "macOS has no text size (docs/compliance-plan.md R4)",
              "chatkeyboard": "macOS has no software keyboard (docs/safe-area-plan.md A13)",
              "taskskeyboard": "macOS has no software keyboard (docs/safe-area-plan.md A13)",
              "autofillkeyboard": "macOS has no software keyboard (docs/safe-area-plan.md A13)",
              "chatkeyboardland": "macOS has no software keyboard (docs/safe-area-plan.md A13)"}

# The clock a scene runs under (docs/compliance-plan.md §4): the core writes
# Apple's own `AppleICUForce24HourTime` into this process's volatile argument
# domain from KAYA_CLOCK, so the maintainer's Mac is never touched. A launch
# argument carrying the key was measured NOT reaching CoreFoundation in a
# guest that formats before its defaults exist (docs/traps.md).
SCENE_CLOCK = {"clock24": "24"}

# The dark half of expect_ink's frozen string, one leg instead of a
# lane re-run (tools/check-appearance.py holds the leg here): canvas's
# script and binary under KAYA_APPEARANCE=dark; and the tints resolved in
# the dark appearance (docs/tints-plan.md §4).
DARK_LEGS = (("canvasdark-rust-swiftui", "canvas", "rust"),
             ("tintsdark-rust-swiftui", "tints", "rust"),
             # The clamped gradient in the dark (docs/styling-pass-plan.md Y2).
             ("groundsdark-rust-swiftui", "grounds", "rust"),
             # The album's gradient header in the dark (docs/media-player-plan.md M5).
             ("music_headerdark-python-swiftui", "music_header", "python"),
             # The artist page's picture on the dark page (docs/traps.md, the
             # image ground read as none in the dark).
             ("music_artistdark-python-swiftui", "music_artist", "python"),
             # The dock in the dark (docs/media-player-plan.md M16 (22)).
             ("music_dockdark-python-swiftui", "music_dock", "python"))

# EXCLUSIVE and the idle wait are below, after legs() — the set is derived
# from the queue rather than spelled.

# The apps and depth scenes hand-queued OUTSIDE SCENES/DEPTH_SCENES
# (each would otherwise derive a cargo --example that does not exist):
# editor is a GO app by design, portfolio and varied are PYTHON alone.
HAND_QUEUED = {"editor": "go", "chat": "go", "portfolio": "python", "varied": "python",
               # The task manager's second scene (docs/tasks-s4-plan.md
               # §4): the same rust example under another script, so it
               # derives no --example of its own.
               "taskspersist": "rust",
               # The split guest's dragged sidebar across a relaunch
               # (docs/tasks-s4-plan.md P8).
               "windowmem": "rust",
               # The app-links scene: the same rust example under a third
               # script (docs/app-links-plan.md L5).
               "links": "rust",
               # The format guest under two more locales (SCENE_LOCALE).
               "formatde": "rust", "formatar": "rust",
               # The task manager in Arabic (SCENE_LOCALE).
               "tasksrtl": "rust",
               # The scroll guest's sideways strip in Arabic (docs/hscroll-plan.md §4).
               "scrollrtl": "rust",
               # The format guest under the 24-hour clock (SCENE_CLOCK).
               "clock24": "rust",
               # The number field guest under de-DE (SCENE_LOCALE).
               "numberfieldde": "rust",
               # Under ar-EG: what a typed number may contain
               # (docs/number-field-plan.md §3 rule 5); the rule is the core's.
               "numberfieldar": "rust",
               # The range guest in Arabic (SCENE_LOCALE).
               "rangertl": "rust",
               # The media suite's scenes, one guest (docs/media-plan.md §7a).
               "media_formats": "rust", "media_delivery": "rust",
               "media_session": "rust", "media_tracks": "rust", "media_feed": "rust",
               # A picked clip played (docs/media-plan.md §2): rust-only.
               "media_picked": "rust",
               # The bound (docs/media-plan.md §7c): rust-only, one 30 s wait.
               "media_timeout": "rust",
               # The capture's denied prompt, one prompt per process
               # (docs/capture-plan.md §2), rust-only at depth.
               "capture_denied": "rust",
               # The media player demo, one Python app under a script per
               # screen (docs/media-player-plan.md M3, §5).
               "music_home": "python", "music_playlist": "python",
               "music_header": "python", "music_dock": "python",
               "music_artist": "python", "music_search": "python",
               "music_context": "python"}

# The queue, in run order. Entries:
#   (scene, (lang, ...))    a group: script export + one leg per lang
#   ("drain",)              the pool barrier
#   ("panel_mode", n, name) rotate the machine-wide file-panel view mode
#   ("panel_check",)        the modes-run census + restore
#   ("dark_leg",)           the dark legs (DARK_LEGS above)
# The single-language groups between drains ARE the serial families, each
# with its reason at the group.
ORDER = [
    ("milestone2", LANGS),
    ("entry", LANGS),
    ("search", LANGS),
    ("secure", LANGS),
    ("autofill", LANGS),
    ("reveal", LANGS),
    ("segmented", LANGS + ("c",)),
    # The number field in the everyday locale and in German
    # (docs/number-field-plan.md §5).
    ("timecode", LANGS),
    ("numberfield", LANGS),
    ("numberfieldde", LANGS),
    ("numberfieldar", ("rust",)),
    # set_color never opens the shared panel, so the everyday scene pools
    # (docs/color-picker-plan.md §5).
    ("colorpicker", LANGS),
    # The submit gesture on the three text kinds (docs/submit-plan.md §5).
    ("submit", LANGS),
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
    # A clip picked through the panel and played (docs/media-plan.md §2),
    # alone between drains for the panel's reason.
    ("media_picked", ("rust",)),
    ("drain",),
    # The text editor: go alone by design, alone between drains (real
    # panels, real keys).
    ("editor", ("go",)),
    ("drain",),
    # The chat app: go alone by design (docs/chat-plan.md R1), alone
    # between drains for the keystrokes its compose field takes.
    ("chat", ("go",)),
    ("drain",),
    ("portfolio", ("python",)),
    ("drain",),
    ("varied", ("python",)),
    ("drain",),
    ("windowed", ("rust",)),
    ("drain",),
    # Fullscreen moves the host's display to a new Space and activates the
    # guest (docs/fullscreen-plan.md §4.1): alone between drains, and
    # EXCLUSIVE below, one leg at a time.
    ("fullscreen", LANGS),
    ("drain",),
    # A row wider than its window (docs/flex-shrink-plan.md §6).
    ("flexshrink", ("rust",)),
    # The common list-row shapes, and the height comparison nothing else
    # could make (docs/deferred.md's list-row layout scene).
    ("listrow", ("rust",)),
    # The platform tints on a filled container (docs/tints-plan.md).
    ("tints", ("rust",)),
    ("codesurface", LANGS),
    # The skin (docs/styling-pass-plan.md §5): grounds, shapes, cards, the
    # track table and the dock.
    ("grounds", LANGS + ("c",)),
    ("shapes", LANGS + ("c",)),
    ("cards", LANGS + ("c",)),
    ("tracks", LANGS + ("c",)),
    ("dock", LANGS + ("c",)),
    # The task manager: a RUST app by design (docs/tasks-plan.md §0).
    ("tasks", ("rust",)),
    # The task manager in Arabic (docs/compliance-plan.md §6): the ar
    # catalog's bytes, the platform's dates, the layout mirrored.
    ("tasksrtl", ("rust",)),
    # The sideways strip in Arabic (docs/hscroll-plan.md §4): starts at its
    # right edge, ends at its left.
    ("scrollrtl", ("rust",)),
    # The notification scene, bundled (BUNDLED_SCENES); rust-only until the
    # breadth slice (docs/tasks-s3-plan.md §6).
    ("notify", ("rust",)),
    # The app's icon badge (docs/app-badge-plan.md), bundled for its
    # notification.
    ("badge", ("rust",)),
    # The emoji button (docs/emoji-picker-plan.md): the character palette.
    ("emoji", ("rust",)),
    # The range and the vertical slider (docs/range-plan.md §5), and the same
    # guest under ar-EG (SCENE_LOCALE). set_value drives the thumbs' own
    # controls and nudge an in-process key, so it pools.
    ("range", LANGS),
    ("rangertl", LANGS),
    # The media suite (docs/media-plan.md §7a). The players are muted; the
    # media legs read the local server this lane starts.
    ("media_formats", LANGS),
    ("media_delivery", LANGS),
    ("media_session", LANGS),
    ("media_tracks", LANGS),
    ("media_feed", LANGS),
    ("media_timeout", ("rust",)),
    ("media_reader", LANGS),
    ("capture", LANGS),
    ("capture_denied", LANGS),
    ("toast", LANGS + ("c",)),
    ("expander", LANGS + ("c",)),
    ("safearea", LANGS + ("c",)),
    ("netimage", LANGS + ("c",)),
    ("netimage_http", LANGS),
    ("music_home", ("python",)),
    ("music_playlist", ("python",)),
    ("music_header", ("python",)),
    ("music_dock", ("python",)),
    ("music_artist", ("python",)),
    ("music_search", ("python",)),
    ("music_context", ("python",)),
    ("richtext", ("rust", "python", "js", "go", "csharp", "java", "swift",
                  "ocaml", "haskell")),
    ("ownundo", ("rust", "python", "js", "go", "csharp", "java", "swift",
                 "ocaml", "haskell")),
    ("richlabel", ("rust", "python", "js", "go", "csharp", "java", "swift",
                   "ocaml", "haskell")),
    ("notes", ("rust",)),
    # THE RICH ROWS (docs/rich-text-plan.md §19): a rich textarea per stamped
    # row, its document a field. This lane carries every binding's template
    # sugar; the other four stay rust-only while richtext does.
    ("richrows", ("rust", "python", "js", "go", "csharp", "java", "swift",
                  "ocaml", "haskell")),
    ("sheet", LANGS),
    # THE FORMATTER DOOR AND THE CATALOG (docs/compliance-plan.md §6): every
    # binding's guest under the everyday locale, then under de-DE and ar-EG
    # through the KAYA_LOCALE knob (SCENE_LOCALE).
    ("format", LANGS + ("c",)),
    ("formatde", LANGS + ("c",)),
    ("formatar", LANGS + ("c",)),
    # The user's 24-hour clock reaching the door (docs/compliance-plan.md §4).
    ("clock24", ("rust",)),
    ("drain",),
    # WHAT SURVIVES A RELAUNCH (docs/tasks-s4-plan.md §4): the tasks
    # guest again under taskspersist.steps, act two through the PLAIN
    # door. Alone between drains — act one leaves a marker in the state
    # home and act two is a second process of the same bundle.
    ("taskspersist", ("rust",)),
    ("drain",),
    # The dragged sidebar across a relaunch (docs/tasks-s4-plan.md P8).
    ("windowmem", ("rust",)),
    ("drain",),
    # APP LINKS (docs/app-links-plan.md L5): the tasks guest a third
    # time, warm through NSWorkspace and cold through `open`. Alone
    # between drains — act two is a second process of the same bundle,
    # and LaunchServices routes a scheme to ONE of the registered
    # claimants.
    ("links", ("rust",)),
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
    ("drain",),
    ("dnd", LANGS),
    ("pickers", LANGS),
    ("sliders", LANGS),
    ("tooltips", LANGS),
    ("drain",),
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
    ("scrollto", LANGS),
    ("progress", LANGS),
    ("select", LANGS),
    ("radio", LANGS),
    ("grid", LANGS),
    ("textarea", LANGS),
    ("sections", LANGS),
    ("menus", LANGS),
    ("rowmenu", LANGS),
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
            out.extend(DARK_LEGS)
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
            out[-1].extend(name for name, _, _ in DARK_LEGS)
        elif entry[0] not in ("panel_mode", "panel_check"):
            scene, langs = entry
            out[-1].extend(leg_name(scene, lang) for lang in langs)
    if not out[-1]:
        out.pop()
    return out


def wired_scenes():
    """The scenes some leg runs — the gates' census surface."""
    return {scene for _name, scene, _lang in legs()}


# The verbs that reach the host beyond the guest's own window, as (kind,
# what the leg takes). EXCLUSIVE, TAKEOVER_SCENES and TAKEOVER_LEGS are
# derived from them and the scene scripts at the end of this module, and
# tools/check-exclusive.py holds every interpreter call that activates the
# guest to a takeover verb here.
#   panel: presses the file panel's own buttons through the accessibility
#     client, and a press posted while a human holds the foreground is
#     swallowed with AX reporting success (docs/deferred.md, the
#     swallowed-press entry).
#   session: takes the host's Now Playing, so the system sends the guest
#     media commands (docs/media-plan.md §5). Its reading is the system's Now
#     Playing, not HIDIdleTime: macOS hands Now Playing to the app that last
#     started playing, so a host app that starts during the leg takes the
#     guest's commands (docs/traps.md, the browser that took Now Playing).
#     A holder defers the leg to the lane's end and it is NOT RUN if the
#     holder stays, as a takeover leg is.
#   takeover: makes the guest the active app or moves the host's display, so
#     a person typing types into the guest (docs/traps.md, the emoji leg took
#     the maintainer's keystrokes). Never runs while the maintainer is active
#     (his ruling of 2026-09-28): an expired or unreadable wait reports the leg
#     NOT RUN rather than running it anyway.
HOST_VERBS = {
    "file_choose": ("panel", "presses the file panel's buttons"),
    "file_save": ("panel", "presses the file panel's buttons"),
    "file_dialog_name": ("panel", "types into the file panel's name field"),
    "session_send": ("session", "takes the host's Now Playing"),
    "expect_now_playing": ("session", "takes the host's Now Playing"),
    "expect_now_playing_art": ("session", "takes the host's Now Playing"),
    "expect_now_playing_app": ("session", "takes the host's Now Playing"),
    "pick_emoji": ("takeover", "activates the guest under the emoji palette, "
                               "taking the host's keyboard"),
    "open_link": ("takeover", "activates the guest through LaunchServices, "
                              "taking the host's keyboard"),
    "user_fullscreen": ("takeover", "moves the host's display"),
    "expect_fullscreen": ("takeover", "moves the host's display"),
}

# The host's own idle clock (HIDIdleTime, nanoseconds since the last key or
# pointer event), read before such a leg is admitted; the wait never
# reddens a lane (docs/deferred.md, the swallowed-press entry). IDLE_S: a
# reader's pauses are seconds, so 20s idle means the host is not in use;
# IDLE_BOUND_S: what one leg waits before running anyway and saying so;
# IDLE_BUDGET_S: what the whole lane spends, rather than bound x set, which
# grows the day a leg joins the set; validate-all nets it out of the mac
# ceiling (idle_waited_seconds).
IDLE_S = 20.0
IDLE_BOUND_S = 60.0
IDLE_BUDGET_S = 240.0
TAKEOVER_IDLE_S = 120.0
TAKEOVER_BOUND_S = 120.0
# What a red leg's whole-desktop picture waits for (tools/lib/flightrec_lane.py's
# shot_desktop): the screen is the maintainer's while he is at it.
DESKTOP_SHOT_IDLE_S = 120.0
IDLE_TELL_S = 30.0
IDLE_POLL_S = 1.0
# How often a leg that found the host busy again inside the token releases it
# and waits again before the last reading decides (idle_admit).
IDLE_RECHECKS = 2
# A SELF-TEST DOOR, and _hid_idle_ns() below is its ONLY reader
# (tools/check-exclusive.py refuses any other): nanosecond values, comma
# separated, answered one per poll with the last repeating, instead of
# asking ioreg. Every sentence the wait then prints carries `(doctored)`,
# so a doctored run can never read as a real one.
IDLE_DOOR = "KAYA_HID_IDLE_NS_OVERRIDE"
# The Now Playing reading's own door, read by _now_playing() alone: entries
# `<pid> <what>` separated by `|`, answered one per reading with the last
# repeating; pid 0 is no app.
NP_DOOR = "KAYA_NOW_PLAYING_OVERRIDE"

IDLE_SENTENCES = {
    "waiting": "mac: {leg} waits for an idle host — HIDIdleTime {idle}s, "
               "wants {want}s (waited {waited}s of {bound}s){door}",
    "cleared": "mac: {leg} waited {waited}s for an idle host — HIDIdleTime "
               "{idle}s{door}",
    "expired": "mac: {leg} waited {bound}s and the host is still in use "
               "(HIDIdleTime {idle}s, wants {want}s) — running it anyway, so "
               "a red here is the host's{door}",
    "spent": "mac: {leg} does not wait — this lane has spent its {budget}s "
             "idle-wait budget (HIDIdleTime {idle}s){door}",
    "unreadable": "mac: {leg} cannot read HIDIdleTime ({why}) — running "
                  "without the idle wait",
    "held": "mac: {leg} {takes} and the host is still in "
            "use after {waited}s (HIDIdleTime {idle}s, wants {want}s) — NOT "
            "RUN{door}",
    "held-unreadable": "mac: {leg} {takes} and HIDIdleTime "
                       "cannot be read ({why}) — NOT RUN, since nothing says "
                       "the host is idle",
    "summary": "mac: idle waits — {legs} leg(s) waited {secs}s of the "
               "{budget}s budget for an idle host; takeover legs waited "
               "{takeover}s, session legs {session}s for Now Playing, "
               "{deferred} deferred to the lane's end",
    "returned": "mac: {leg} took the token and the host is in use again "
                "(HIDIdleTime {idle}, wants {want}s) — released it to wait "
                "again{door}",
    "returned-anyway": "mac: {leg} took the token and the host is in use "
                       "again (HIDIdleTime {idle}, wants {want}s) after "
                       "{tries} waits — running it anyway, so a red here is "
                       "the host's{door}",
    "returned-held": "mac: {leg} {takes} and the host was in "
                     "use again each of the {tries} times it took the token "
                     "(HIDIdleTime {idle}, wants {want}s) — NOT RUN{door}",
    "deferred": "mac: {leg} {takes} and the host is in use "
                "(HIDIdleTime {idle}, wants {want}s) — deferred to the lane's "
                "end{door}",
    "np-deferred": "mac: {leg} {takes} and the system's Now Playing is {holder} "
                   "— deferred to the lane's end{door}",
    "np-waiting": "mac: {leg} waits for the system's Now Playing — {holder} "
                  "(waited {waited}s of {bound}s){door}",
    "np-cleared": "mac: {leg} waited {waited}s for the system's Now Playing — "
                  "{holder}{door}",
    "np-held": "mac: {leg} {takes} and the system's Now Playing is still "
               "{holder} after {waited}s — NOT RUN{door}",
    "np-returned-held": "mac: {leg} {takes} and the system's Now Playing was "
                        "{holder} each of the {tries} times it took the token "
                        "— NOT RUN{door}",
    "under-token": "mac: {leg} would wait for an idle host while this process "
                   "holds the matrix-wide token for {held} — every other lane "
                   "would wait on the human too; wait before exclusive.hold() "
                   "and re-read the clock inside it (idle_admit)",
}

_idle = {"spent": 0.0, "legs": 0, "door": [], "cleared": False,
         "takeover": 0.0, "session": 0.0, "np_door": [], "deferred": 0,
         "deadline": None}


def _hid_idle_ns():
    """(nanoseconds, None), or (None, why) — never an invented number."""
    raw = os.environ.get(IDLE_DOOR, "")
    if raw:
        if not _idle["door"]:
            try:
                _idle["door"] = [int(v) for v in raw.split(",") if v.strip()]
            except ValueError:
                return None, f"{IDLE_DOOR}={raw!r} is not a list of integers"
        if not _idle["door"]:
            return None, f"{IDLE_DOOR} is set and names no value"
        rest = _idle["door"]
        return (rest.pop(0) if len(rest) > 1 else rest[0]), None
    try:
        got = subprocess.run(["ioreg", "-c", "IOHIDSystem", "-r", "-d", "1"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, encoding="utf-8", errors="replace",
                             check=False)
    except OSError as e:
        return None, f"ioreg would not run: {e.strerror or e}"
    if got.returncode != 0:
        first = (got.stderr or "").strip().splitlines()
        return None, (f"ioreg exited {got.returncode}"
                      + (f": {first[0]}" if first else ""))
    m = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', got.stdout)
    if not m:
        return None, ("ioreg's IOHIDSystem entry carries no HIDIdleTime "
                      f"({len(got.stdout.splitlines())} line(s) read)")
    return int(m.group(1)), None


def _now_playing():
    """((pid, what), None) for the system's Now Playing, pid 0 for no app, as
    tools/mac/mediaremote.c reads it inside /usr/bin/perl; or (None, why)."""
    raw = os.environ.get(NP_DOOR, "")
    if raw:
        if not _idle["np_door"]:
            _idle["np_door"] = [v.strip() for v in raw.split("|") if v.strip()]
        rest = _idle["np_door"]
        if not rest:
            return None, f"{NP_DOOR} is set and names no value"
        entry = rest.pop(0) if len(rest) > 1 else rest[0]
        pid, _, what = entry.partition(" ")
        if not pid.isdigit():
            return None, f"{NP_DOOR} entry {entry!r} is not `<pid> <what>`"
        return (int(pid), what or "no app"), None
    lib = media_server.mediaremote_lib(_scenes_root())
    if lib is None:
        return None, "tools/mac/mediaremote.c would not build"
    try:
        got = subprocess.run(
            ["/usr/bin/perl", "-e",
             "use DynaLoader; my $l=DynaLoader::dl_load_file($ARGV[0],0) or die "
             "DynaLoader::dl_error(); my $s=DynaLoader::dl_find_symbol($l,"
             "'kaya_mediaremote_run') or die 'no symbol'; "
             "DynaLoader::dl_install_xsub('main::run',$s); run();", lib],
            env=dict(os.environ, KAYA_MR_ACTION="pid"), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace",
            timeout=20, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"the helper did not answer: {e}"
    m = re.search(r"mediaremote: now playing pid (-?\d+) \((.*)\)", got.stdout)
    if not m:
        return None, f"the helper said {got.stdout.strip()!r}, exit {got.returncode}"
    if int(m.group(1)) < 0:
        return None, m.group(2)
    return (int(m.group(1)), m.group(2)), None


def _session_reading():
    """(the holder as text, clear): no app, or a paused one on an idle host."""
    got, why = _now_playing()
    if got is None:
        return f"unreadable ({why})", False
    pid, what = got
    if pid == 0:
        return "no app", True
    if "not playing" in what:
        ns, _ = _hid_idle_ns()
        if ns is not None and ns / 1e9 >= IDLE_S:
            return f"pid {pid} ({what}) on an idle host", True
        idle = "unreadable" if ns is None else f"{int(ns / 1e9)}s"
        return f"pid {pid} ({what}) while the host is in use (HIDIdleTime {idle})", False
    return f"pid {pid} ({what})", False


def session_wait(leg, say=None):
    """A SESSION_LEGS leg's wait for the system's Now Playing to clear, under the
    lane's end's shared bound (takeover_deadline); in its queue position
    idle_admit has read it clear already, so this returns at once. Returns None
    or the NOT RUN sentence."""
    say = say or _idle_say
    _not_under_token(leg)
    door = " (doctored)" if os.environ.get(NP_DOOR, "") else ""
    started = time.monotonic()
    deadline = _idle["deadline"]
    bound = TAKEOVER_BOUND_S if deadline is None else max(0.0, deadline - started)
    told = 0
    while True:
        waited = time.monotonic() - started
        holder, clear = _session_reading()
        if clear:
            if waited >= IDLE_POLL_S:
                say(IDLE_SENTENCES["np-cleared"].format(
                    leg=leg, waited=int(waited), holder=holder, door=door))
            _idle["session"] += waited
            _idle["cleared"] = True
            return None
        if waited >= bound:
            _idle["session"] += waited
            refused = IDLE_SENTENCES["np-held"].format(
                leg=leg, takes=SESSION_LEGS[leg], holder=holder, waited=int(waited),
                door=door)
            say(refused)
            return refused
        if waited >= (told + 1) * IDLE_TELL_S:
            told += 1
            say(IDLE_SENTENCES["np-waiting"].format(
                leg=leg, holder=holder, waited=int(waited), bound=int(bound), door=door))
        time.sleep(IDLE_POLL_S)


def _idle_say(text):
    print(text, file=sys.stderr, flush=True)


def _not_under_token(leg):
    holder = exclusive.held()
    if holder is not None:
        raise RuntimeError(IDLE_SENTENCES["under-token"].format(leg=leg, held=holder))


def idle_wait(leg, say=None):
    """Hold an input-driving leg until the host has been idle IDLE_S seconds.

    Called BEFORE the matrix-wide token is taken (idle_admit), and refused
    while this process holds it: a wait on a human inside the token made
    every other lane wait on him too (docs/traps.md, the idle waits held the
    token). An unreadable clock, an expired bound and a spent budget each
    print one sentence and the leg runs, EXCEPT a TAKEOVER_LEGS leg, which
    takeover_wait holds. Returns None when the leg may run, or the sentence.
    """
    say = say or _idle_say
    _not_under_token(leg)
    _idle["cleared"] = False
    if leg in TAKEOVER_LEGS:
        return takeover_wait(leg, say)
    if leg in SESSION_LEGS:
        return session_wait(leg, say)
    door = " (doctored)" if os.environ.get(IDLE_DOOR, "") else ""
    ns, why = _hid_idle_ns()
    if ns is None:
        say(IDLE_SENTENCES["unreadable"].format(leg=leg, why=why))
        return None
    if ns / 1e9 >= IDLE_S:
        _idle["cleared"] = True
        return None
    if _idle["spent"] >= IDLE_BUDGET_S:
        say(IDLE_SENTENCES["spent"].format(
            leg=leg, budget=int(IDLE_BUDGET_S), idle=int(ns / 1e9), door=door))
        return None
    bound = min(IDLE_BOUND_S, IDLE_BUDGET_S - _idle["spent"])
    started = time.monotonic()
    told = 0

    def done(waited):
        _idle["spent"] += waited
        _idle["legs"] += 1

    while True:
        time.sleep(IDLE_POLL_S)
        waited = time.monotonic() - started
        ns, why = _hid_idle_ns()
        if ns is None:
            say(IDLE_SENTENCES["unreadable"].format(leg=leg, why=why))
            done(waited)
            return None
        idle = int(ns / 1e9)
        if ns / 1e9 >= IDLE_S:
            say(IDLE_SENTENCES["cleared"].format(
                leg=leg, waited=int(waited), idle=idle, door=door))
            done(waited)
            _idle["cleared"] = True
            return None
        if waited >= bound:
            say(IDLE_SENTENCES["expired"].format(
                leg=leg, bound=int(bound), idle=idle, want=int(IDLE_S),
                door=door))
            done(waited)
            return None
        if waited >= (told + 1) * IDLE_TELL_S:
            told += 1
            say(IDLE_SENTENCES["waiting"].format(
                leg=leg, idle=idle, want=int(IDLE_S), waited=int(waited),
                bound=int(bound), door=door))


def takeover_wait(leg, say=None):
    """A TAKEOVER_LEGS leg's wait: idle for TAKEOVER_IDLE_S within TAKEOVER_BOUND_S, or
    the leg does not run. Outside the lane's budget, since a leg that waits
    and is then refused costs the lane no run; the lane's end shares ONE bound
    across its deferred legs (takeover_deadline). Returns None or the sentence."""
    say = say or _idle_say
    _not_under_token(leg)
    door = " (doctored)" if os.environ.get(IDLE_DOOR, "") else ""
    started = time.monotonic()
    bound = (TAKEOVER_BOUND_S if _idle["deadline"] is None
             else max(0.0, _idle["deadline"] - started))
    told = 0
    while True:
        waited = time.monotonic() - started
        ns, why = _hid_idle_ns()
        if ns is None:
            refused = IDLE_SENTENCES["held-unreadable"].format(leg=leg, why=why,
                                                              takes=TAKEOVER_LEGS[leg])
            say(refused)
            _idle["takeover"] += waited
            return refused
        idle = int(ns / 1e9)
        if ns / 1e9 >= TAKEOVER_IDLE_S:
            if waited >= IDLE_POLL_S:
                say(IDLE_SENTENCES["cleared"].format(
                    leg=leg, waited=int(waited), idle=idle, door=door))
            _idle["takeover"] += waited
            _idle["cleared"] = True
            return None
        if waited >= bound:
            _idle["takeover"] += waited
            refused = IDLE_SENTENCES["held"].format(
                leg=leg, takes=TAKEOVER_LEGS[leg], waited=int(waited), idle=idle, want=int(TAKEOVER_IDLE_S),
                door=door)
            say(refused)
            return refused
        if waited >= (told + 1) * IDLE_TELL_S:
            told += 1
            say(IDLE_SENTENCES["waiting"].format(
                leg=leg, idle=idle, want=int(TAKEOVER_IDLE_S), waited=int(waited),
                bound=int(bound), door=door))
        time.sleep(IDLE_POLL_S)


def _reading(leg):
    """(idle seconds as text, met) for the leg's own threshold: ONE reading.
    A SESSION_LEGS leg's is the system's Now Playing holder instead."""
    if leg in SESSION_LEGS:
        holder, clear = _session_reading()
        return holder, clear, IDLE_S
    want = TAKEOVER_IDLE_S if leg in TAKEOVER_LEGS else IDLE_S
    ns, why = _hid_idle_ns()
    if ns is None:
        return f"unreadable: {why}", False, want
    return f"{int(ns / 1e9)}s", ns / 1e9 >= want, want


def _defer(leg, idle, want, say):
    if leg in SESSION_LEGS:
        door = " (doctored)" if os.environ.get(NP_DOOR, "") else ""
        said = IDLE_SENTENCES["np-deferred"].format(leg=leg, takes=SESSION_LEGS[leg],
                                                    holder=idle, door=door)
        say(said)
        _idle["deferred"] += 1
        return "deferred", said
    door = " (doctored)" if os.environ.get(IDLE_DOOR, "") else ""
    said = IDLE_SENTENCES["deferred"].format(leg=leg, takes=TAKEOVER_LEGS[leg], idle=idle, want=int(want), door=door)
    say(said)
    _idle["deferred"] += 1
    return "deferred", said


def takeover_deadline():
    """Start the lane's end: the deferred legs share one TAKEOVER_BOUND_S."""
    _idle["deadline"] = time.monotonic() + TAKEOVER_BOUND_S


def idle_admit(leg, hold, run, say=None):
    """An EXCLUSIVE leg's admission, as (outcome, sentence): "ran", "not-run"
    or "deferred". The wait runs BEFORE the token; inside it the clock is read
    ONCE, without sleeping, since the human may have come back while hold()
    waited on another lane, and busy again releases the token and waits again,
    IDLE_RECHECKS times, before the last reading decides. A TAKEOVER_LEGS leg
    in its queue position never waits: a busy reading defers it to the lane's
    end (takeover_deadline). `hold` makes the token's context manager, `run`
    runs the leg."""
    say = say or _idle_say
    door = " (doctored)" if os.environ.get(IDLE_DOOR, "") else ""
    in_place = (leg in TAKEOVER_LEGS or leg in SESSION_LEGS) and _idle["deadline"] is None
    for tries in range(1, IDLE_RECHECKS + 2):
        if in_place:
            idle, met, want = _reading(leg)
            if not met:
                return _defer(leg, idle, want, say)
        refused = idle_wait(leg, say)
        if refused:
            return "not-run", refused
        with hold():
            idle, met, want = _reading(leg)
            if met or not _idle["cleared"]:
                run()
                return "ran", None
            if in_place:
                return _defer(leg, idle, want, say)
            if tries > IDLE_RECHECKS:
                if leg in SESSION_LEGS:
                    said = IDLE_SENTENCES["np-returned-held"].format(
                        leg=leg, takes=SESSION_LEGS[leg], tries=tries, holder=idle,
                        door=" (doctored)" if os.environ.get(NP_DOOR, "") else "")
                    say(said)
                    return "not-run", said
                if leg in TAKEOVER_LEGS:
                    said = IDLE_SENTENCES["returned-held"].format(
                        leg=leg, takes=TAKEOVER_LEGS[leg], tries=tries, idle=idle, want=int(want), door=door)
                    say(said)
                    return "not-run", said
                say(IDLE_SENTENCES["returned-anyway"].format(
                    leg=leg, tries=tries, idle=idle, want=int(want), door=door))
                run()
                return "ran", None
            say(IDLE_SENTENCES["returned"].format(
                leg=leg, idle=idle, want=int(want), door=door))
    raise AssertionError("idle_admit's last try always decides")


def idle_summary(say=None):
    """What waiting for a quiet host cost this lane, printed on EVERY run —
    zero on a quiet host, which is the number the everyday matrix pays."""
    (say or _idle_say)(IDLE_SENTENCES["summary"].format(
        legs=_idle["legs"], secs=int(_idle["spent"]),
        budget=int(IDLE_BUDGET_S), takeover=int(_idle["takeover"]),
        session=int(_idle["session"]), deferred=_idle["deferred"]))


def idle_waited_seconds(text):
    """The seconds the lane's summary line in `text` says it waited for an
    idle host, both kinds; validate-all nets them out of the ceiling
    (docs/traps.md, the idle waits counted against the ceiling)."""
    pattern = re.escape(IDLE_SENTENCES["summary"])
    for key, group in (("legs", r"\d+"), ("secs", r"(?P<secs>\d+)"), ("budget", r"\d+"),
                       ("takeover", r"(?P<takeover>\d+)"), ("session", r"(?P<session>\d+)"),
                       ("deferred", r"\d+")):
        pattern = pattern.replace(re.escape("{" + key + "}"), group)
    m = re.search("^" + pattern + "$", text, re.M)
    return (int(m.group("secs")) + int(m.group("takeover")) + int(m.group("session"))
            if m else 0)


def hid_idle_seconds():
    """The host's idle seconds as (secs, None) or (None, why) — the launch
    line's reading (tools/validate-all.py), one reader with the wait's."""
    ns, why = _hid_idle_ns()
    return (None, why) if ns is None else (int(ns / 1e9), None)


# THE LEG'S COMMAND AND SCRIPT, one copy: validate-mac.py runs the roster
# through these and run-leg.py runs ONE leg by hand through the same two
# (docs/traps.md, 2026-09-01 — a hand-spelled env ran a stale interpreter).
KAYA_LIB_LANGS = ("csharp", "ocaml", "java")
RUST_GUESTS = "target/rust-guests"
# THE BUNDLED SCENES (docs/tasks-s3-plan.md N4): a scene that posts a
# notification runs as a minimal .app, since macOS answers UNUserNotificationCenter
# only from a bundle with an identifier — the identity manifest's `id`. The
# rest stay bare executables (docs/deferred.md: an unbundled launch walks its
# siblings, which is why the staging directory is small).
BUNDLED_SCENES = {"notify", "tasks", "badge"}
# The go scenes that post one: the one kaya-go binary, wrapped per scene.
BUNDLED_GO_SCENES = {"chat"}
GO_GUESTS = "target/go-guests"


# THE PYTHON APPS THAT DECLARE AN IDENTITY OF THEIR OWN run as their bundle
# (docs/media-player-plan.md M22 (6)): the system's Now Playing names a
# process by its bundle's display name, and a bare python3 by "python3.14"
# (measured, M22 (3)). The bundle's executable is a copy of kaya-python, so
# the process's executable is inside it.
PY_GUESTS = "target/py-guests"

# THE HOSTS (tools/mac/kaya-host.c): every python, java, C# and JS leg starts
# in a main executable this lane compiled, because SwiftUI picks its design
# generation from the main executable's sdk stamp and the vendor hosts stamp
# 13.3 and 14.4 (docs/traps.md, SwiftUI resolves its design generation).
HOSTS_DIR = "target/mac-hosts"
HOSTS = {"python": "kaya-python", "java": "kaya-java", "csharp": "kaya-dotnet",
         "js": "kaya-node"}
HOST_SOURCE = "tools/mac/kaya-host.c"
_ROOT = pathlib.Path(__file__).resolve().parents[3]


def host_path(lang):
    return f"{HOSTS_DIR}/{HOSTS[lang]}"


def _host_runtimes():
    """{lang: (defines, link args)} out of the dev shell's own runtimes."""
    def out(argv):
        got = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", check=False)
        if got.returncode != 0:
            raise SystemExit(f"mac lane: {' '.join(argv)} failed: {got.stderr.strip()}")
        return got.stdout.strip()

    def tool(name):
        found = shutil.which(name)
        if found is None:
            raise SystemExit(f"mac lane: `{name}` is not on PATH, so its kaya host cannot be built")
        return pathlib.Path(os.path.realpath(found))

    libpython = pathlib.Path(out(["python3", "-c", "import sysconfig; print(sysconfig.get_config_var('LIBDIR') "
                                  "+ '/' + sysconfig.get_config_var('LDLIBRARY'))"]))
    java_home = tool("java").parents[1]
    release = (java_home / "release").read_text(encoding="utf-8")
    version = re.search(r'^JAVA_RUNTIME_VERSION="([^"]+)"', release, re.M)
    dotnet_root = tool("dotnet").parent
    packs = sorted(dotnet_root.glob("packs/Microsoft.NETCore.App.Host.osx-arm64/*/runtimes/osx-arm64/native/"
                                    "libnethost.a"),
                   key=lambda p: [int(x) if x.isdigit() else 0 for x in p.parts[-5].split(".")])
    if not libpython.is_file() or version is None or not packs:
        raise SystemExit(f"mac lane: a host's runtime is not where the shell says: libpython {libpython} "
                         f"(file: {libpython.is_file()}), {java_home}/release JAVA_RUNTIME_VERSION "
                         f"{version.group(1) if version else None}, libnethost.a under {dotnet_root}/packs: "
                         f"{len(packs)}")
    return {
        "python": (["-DKAYA_HOST_PYTHON"], [str(libpython)]),
        "java": (["-DKAYA_HOST_JAVA", f'-DKAYA_JAVA_VERSION="{version.group(1)}"'],
                 [str(java_home / "lib/libjli.dylib"), f"-Wl,-rpath,{java_home / 'lib'}"]),
        "csharp": (["-DKAYA_HOST_DOTNET", f'-DKAYA_DOTNET_ROOT="{dotnet_root}"'], [str(packs[-1]), "-lc++"]),
        "js": (["-DKAYA_HOST_NODE", f'-DKAYA_NODE_PATH="{tool("node")}"'], []),
    }


def build_hosts(root, langs=None, out_dir=None, log=None):
    """Compile tools/mac/kaya-host.c once per runtime with the dev shell's cc
    (flake.nix's apple-sdk_26), each verified by its build id and its stamp.
    Returns 0, or 1 with the reason written to `log` (stdout when None)."""
    root = pathlib.Path(root)
    out = pathlib.Path(out_dir) if out_dir else root / HOSTS_DIR
    out.mkdir(parents=True, exist_ok=True)
    say = (open(log, "a", encoding="utf-8") if log else sys.stdout)
    try:
        bid = subprocess.run([str(root / "tools/build-id.py"), "mac-host"], capture_output=True, text=True,
                             encoding="utf-8", check=False)
        if bid.returncode != 0:
            say.write(f"build_hosts: tools/build-id.py mac-host failed: {bid.stderr.strip()}\n")
            return 1
        runtimes = _host_runtimes()
        for lang in langs or HOSTS:
            defines, link = runtimes[lang]
            dest = out / HOSTS[lang]
            dest.unlink(missing_ok=True)
            cc = subprocess.run(["cc", "-O2", "-Wall", "-Werror", f'-DKAYA_BUILD_ID="{bid.stdout.strip()}"',
                                 *defines, str(root / HOST_SOURCE), *link, "-o", str(dest)],
                                capture_output=True, text=True, encoding="utf-8", check=False)
            if cc.returncode != 0:
                say.write(f"build_hosts: {HOSTS[lang]} did not compile:\n{cc.stderr}")
                return 1
            verify = subprocess.run([str(root / "tools/build-id.py"), "--verify", "--component", "mac-host",
                                     str(dest)], capture_output=True, text=True, encoding="utf-8", check=False)
            if verify.returncode != 0:
                say.write(f"build_hosts: {verify.stderr}")
                return 1
            refused = modern_refusal(dest, lang)
            if refused:
                say.write(f"build_hosts: {refused}\n")
                return 1
        return 0
    finally:
        if log:
            say.close()


def modern_refusal(exe, lang):
    """None when `exe` is stamped for macOS's modern design generation, else
    the sentence a leg refuses with."""
    import macho
    st, why = macho.stamp(exe)
    if st is None:
        return f"the {lang} legs' main executable {exe} {why}"
    plat, minos, sdk, which = st
    if plat == macho.PLATFORM_MACOS and sdk >= macho.MODERN_FLOOR:
        return None
    host = (f"{host_path(lang)}, built from {HOST_SOURCE} by build_hosts" if lang in HOSTS
            else "a binary this lane links with the dev shell's toolchain")
    return (f"the {lang} legs would start in {exe}, stamped platform {plat} sdk {macho.show(sdk)} "
            f"({which}, minos {macho.show(minos)}); below sdk {macho.floor_of(macho.MODERN_FLOOR)} "
            f"macOS draws the old (compatibility) design generation. A {lang} leg starts in {host} "
            f"(docs/traps.md, SwiftUI resolves its design generation from the MAIN EXECUTABLE's SDK stamp)")


def require_modern(argv, lang):
    """THE WALL every mac leg's argv passes through: a main executable
    stamped below the modern floor refuses the lane, naming the host."""
    exe = argv[0]
    if "/" not in exe:
        found = shutil.which(exe)
        if found is None:
            return argv
        path = pathlib.Path(os.path.realpath(found))
    else:
        path = _ROOT / exe if not os.path.isabs(exe) else pathlib.Path(exe)
    if not path.is_file():
        if lang in HOSTS:
            raise SystemExit(f"mac lane: the {lang} host {path} is not built; build_hosts in "
                             f"tools/lib/lanes/mac.py builds it (validate-mac and run-leg call it)")
        return argv
    refused = modern_refusal(path, lang)
    if refused:
        raise SystemExit(f"mac lane: {refused}")
    return argv


def py_bundled(stem):
    from packaging import identity as app_identity
    return stem in app_identity.APPS


def stage_python(root, stems):
    """Each bundled python app's .app, through the generator's mac arm with
    the app's own declaration; a fresh kaya-python copy every time."""
    from packaging import identity as app_identity
    from packaging import mac as packaging_mac
    python = root / host_path("python")
    if not python.is_file():
        raise SystemExit(f"mac lane: {python} is not built, and the bundled python apps wrap it; "
                         f"build_hosts builds it")
    staging = root / PY_GUESTS
    staging.mkdir(parents=True, exist_ok=True)
    for stem in stems:
        if py_bundled(stem):
            packaging_mac.bundle(root, pathlib.Path(python), staging, stem=stem,
                                 accessory=True, manifest=app_identity.manifest_for(stem))


def rust_guest_path(stem):
    """Where a staged rust guest's executable is: inside its .app for a
    bundled scene, bare otherwise."""
    if stem in BUNDLED_SCENES:
        return f"{RUST_GUESTS}/{stem}.app/Contents/MacOS/{stem}"
    return f"{RUST_GUESTS}/{stem}"


def stage_rust(root, stems):
    """Copy built examples into the small staging directory — ONE COPY,
    validate-mac's whole roster and run-leg's one leg — wrapping the
    bundled scenes THROUGH THE GENERATOR'S MAC ARM
    (tools/lib/packaging/mac.py, docs/packaging-plan.md P4), so the
    bundle a leg runs and a bundle a user would double-click are
    assembled by the same lines. `accessory` is the lane's own half: the
    guests are LSUIElement and a shipped app is not. A fresh inode every
    time, or the kernel kills the guest at exec (docs/traps.md, "Code
    Signature Invalid")."""
    import shutil
    from packaging import mac as packaging_mac
    staging = root / RUST_GUESTS
    staging.mkdir(parents=True, exist_ok=True)
    for stem in stems:
        built = root / f"target/debug/examples/{stem}"
        if stem not in BUNDLED_SCENES:
            dest = staging / stem
            dest.unlink(missing_ok=True)
            shutil.copy2(built, dest)
            continue
        packaging_mac.bundle(root, built, staging, stem=stem,
                             accessory=True)
CS_GUEST = "guests/csharp/bin/Debug/net10.0/kaya-guests.dll"

# THE SECOND ACT'S DOOR ON THIS LANE (docs/tasks-s9-plan.md R6a).
# macOS has no programmatic tap on a delivered notification, so the lane
# takes the carve-out: it starts the same bundle again with
# KAYA_LAUNCH_NOTIFICATION and the interpreter enters the centre
# delegate's own funnel one step past the tap. tools/check-steps.py reads
# this table against the scenes that carry a `relaunch` line.
RELAUNCH_DOOR = {"tasks": "launch-notification", "taskspersist": "launch",
                 "windowmem": "launch",
                 # THE LINK DOOR (docs/app-links-plan.md L5): `open` hands
                 # the URL to LaunchServices, which starts the bundle and
                 # delivers it as an Apple event 21 ms in.
                 "links": "link"}
# Which notification the door hands back. The scene's act one sets t1's
# reminder, and a task's key IS its notification id (R2), so the tap the
# runner plays is on 1.
RELAUNCH_NOTIFICATION = {"tasks": 1}


def act2_dir(root, env=None):
    """`<state>/act2/<id>` as crates/kaya/src/act2.rs computes it, under
    the LEG's own state home (leg_env sets one per leg — docs/traps.md,
    the pooled-scratch race of 2026-09-09) and the identity manifest's
    `id`, through tools/ONE manifest reader."""
    from packaging.identity import load
    source = env if env is not None else os.environ
    state = source.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local/state")
    return pathlib.Path(state) / "kaya" / "act2" / load(root).id


def clear_act2(root, env=None, scene=None):
    """A stale marker or verdict may not serve this run. The core
    consumes the marker on read, so this covers the run that DIED before
    its second act."""
    d = act2_dir(root, env)
    for name in ("marker", "act2.verdict"):
        (d / name).unlink(missing_ok=True)
    if scene in REAL_STORE_SENTINEL:
        plant_real_store(root, scene)


# THE HARNESS NEVER READS OR WRITES THE APP'S REAL STORE (docs/tasks-s4-plan.md
# P8): a value planted in the real domain before act one, which the scene's
# first read shows if the harness read it, and which second_act finds changed
# if the harness wrote it. Put back in the process's exit at the latest.
REAL_STORE_SENTINEL = {"windowmem": ("kaya.window.0.sidebar", "123")}
_real_store_prior = {}


def real_domain(root, scene):
    from packaging import identity
    return identity.load(root, identity.manifest_for(guest_stem(scene))).id


def _defaults(*argv):
    return subprocess.run(["defaults", *argv], capture_output=True, text=True,
                          timeout=30, check=False)


def plant_real_store(root, scene):
    import atexit
    key, value = REAL_STORE_SENTINEL[scene]
    domain = real_domain(root, scene)
    if (domain, key) not in _real_store_prior:
        held = _defaults("read", domain, key)
        prior = held.stdout.strip() if held.returncode == 0 else None
        _real_store_prior[(domain, key)] = None if prior == value else prior
        atexit.register(release_real_store, domain, key)
    _defaults("write", domain, key, "-int", value)


def release_real_store(domain, key):
    if (domain, key) not in _real_store_prior:
        return
    prior = _real_store_prior.pop((domain, key))
    if prior is None:
        _defaults("delete", domain, key)
    else:
        _defaults("write", domain, key, "-int", prior)


def standard_domain(argv):
    """The domain NSUserDefaults.standard names for the process argv starts:
    the bundle's identifier, else the executable's name (docs/traps.md, the
    host domain's window frame)."""
    import plistlib
    exe = pathlib.Path(argv[0])
    if exe.parent.name == "MacOS" and exe.parent.parent.name == "Contents":
        info = exe.parent.parent / "Info.plist"
        if info.is_file():
            return plistlib.loads(info.read_bytes()).get("CFBundleIdentifier", exe.name)
    return exe.name


def real_store_verdict(root, scene, lf, argv):
    """0 when the planted value is still the real domain's and no split
    frame was autosaved, else 1 with the sentence; the user's own value is
    put back either way."""
    key, value = REAL_STORE_SENTINEL[scene]
    domain = real_domain(root, scene)
    held = _defaults("read", domain, key)
    got = held.stdout.strip() if held.returncode == 0 else None
    release_real_store(domain, key)
    import plistlib
    split = []
    for where in sorted({domain, standard_domain(argv)}):
        exported = subprocess.run(["defaults", "export", where, "-"], capture_output=True,
                                  timeout=30, check=False)
        keys = plistlib.loads(exported.stdout).keys() if exported.returncode == 0 else ()
        split += [f"{where}: {k}" for k in sorted(keys)
                  if k.startswith("NSSplitView Subview Frames ")
                  and ("KayaRoot" in k or "KayaAuxRoot" in k)]
    rc = 0
    if got != value:
        lf.write(f"{scene}: the real domain {domain} holds {key} = {got!r} after the leg, "
                 f"planted {value} before act one: the harness wrote the app's real store "
                 f"(docs/tasks-s4-plan.md P8)\n")
        rc = 1
    if split:
        lf.write(f"{scene}: AppKit's split frames {split} were written by the leg, which "
                 f"every launch forgets: the sidebar's split view still autosaves "
                 f"(docs/tasks-s4-plan.md P8)\n")
        rc = 1
    if rc == 0:
        lf.write(f"{scene}: the real domain {domain} still holds {key} = {value}, planted "
                 f"before act one, and no AppKit split frame is in it or in "
                 f"{standard_domain(argv)}\n")
    return rc


def plain_launch(argv, env, root, lf):
    """How act two is started when nothing is filming: the same bound the
    first act runs under."""
    return subprocess.Popen(["timeout", "120", *argv], cwd=root, env=env,
                            stdout=lf, stderr=lf).wait()


def relaunch_url(text):
    """The URL act one printed beside its door (docs/app-links-plan.md
    L5), or "". Read from the LINE rather than from the scene: what the
    door pushes has to be what act one actually reached."""
    for line in text.splitlines():
        marker = "KAYA_RELAUNCH: door link url="
        if line.startswith(marker):
            return line[len(marker):].strip()
    return ""


def relaunched_pid(app):
    """The pid of the process the platform started from `app`'s bundle."""
    got = subprocess.run(
        ["pgrep", "-f", f"{app}/Contents/MacOS/"],
        capture_output=True, text=True, check=False).stdout.split()
    return int(got[0]) if got else None


def open_link_door(root, app, url, act2_env, verdict, lf, seconds=120):
    """THE COLD DOOR ON THIS LANE: `open` hands the URL to
    LaunchServices, which starts the bundle and delivers it as an Apple
    event 21 ms in, before any window exists (docs/traps.md, 2026-09-09).

    TARGETED AT THE BUNDLE with `-a`, never the bare URL: every kaya
    guest claims the same scheme — it defaults to the declared id — and
    this lane keeps several .app wrappers registered, so an untargeted
    open is an undefined pick among them and delivers to the wrong one
    with nothing saying so (measured 2026-09-09).

    `open` returns as soon as the app is launched, so the verdict FILE is
    what this waits on; a process LaunchServices starts inherits nothing
    from here, which is what the `--env` flags are for. NEVER
    KAYA_SWIFTUI_LIB: this is the lane's one platform-started launch, so
    it runs the interpreter the BUNDLE carries (docs/traps.md, the cold
    notification reply of 2026-09-27).
    """
    argv = ["open"]
    for key in ("XDG_STATE_HOME", "KAYA_LIB",
                "KAYA_VERB_TRACE", "KAYA_APPEARANCE"):
        if act2_env.get(key):
            argv += ["--env", f"{key}={act2_env[key]}"]
    argv += ["--stdout", str(log_path(lf)), "--stderr", str(log_path(lf)),
             "-a", str(app), url]
    lf.write(f"== act two: link {url} through {' '.join(argv[:1])} "
             f"-a {app} ==\n")
    lf.flush()
    done = subprocess.run(argv, cwd=root, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", check=False)
    if done.returncode != 0:
        lf.write(f"open exited {done.returncode}: "
                 f"{done.stderr.strip() or done.stdout.strip()}\n")
        return done.returncode
    # THE WINDOW A USER WOULD SEE, WATCHED WHILE THE PROCESS IS ALIVE
    # (docs/app-links-plan.md L5). Act two's own observations all read the
    # MODEL, so they publish OK for a process that never put anything on
    # screen — which is exactly what a URL launch did until 2026-09-09:
    # the NSWindow was built and registered and never composited, and a
    # user tapping a link with the app closed got nothing. THE APP'S OWN
    # WINDOW-SERVER READ is the witness (swift/KayaSwiftUI.swift's
    # `windowserver` diag, `.optionAll` so any Space counts): polling the
    # process table missed a second act that lives a second (matrix #5),
    # and the on-screen list is Space-scoped (docs/traps.md, 2026-09-10).
    # A PANIC ENDS THE WAIT: `open` routes act two's stderr into this log,
    # so one read from the door's own marker onward tells a process that
    # died from one still working (docs/traps.md, 2026-09-27).
    since = log_path(lf).stat().st_size
    deadline = time.monotonic() + seconds
    line = ""
    panicked = ""
    while time.monotonic() < deadline:
        if verdict.is_file():
            line = verdict.read_text(encoding="utf-8",
                                     errors="replace").strip()
            if line:
                break
        with open(log_path(lf), encoding="utf-8", errors="replace") as tail:
            tail.seek(since)
            panicked = next((l for l in tail if "panicked at" in l), "")
        if panicked:
            break
        time.sleep(0.1)
    if not line:
        waited = seconds - max(0.0, deadline - time.monotonic())
        lf.write(f"act two panicked {waited:.1f}s after the link door and "
                 f"wrote no verdict: {panicked.strip()}\n" if panicked else
                 f"act two wrote no verdict within {seconds}s of the link "
                 f"door, and printed no panic to this log\n")
        return 1
    lf.flush()
    report = ""
    grace = time.monotonic() + 3.0
    while time.monotonic() < grace:
        text = log_path(lf).read_text(encoding="utf-8", errors="replace")
        found = [l for l in text.splitlines()
                 if "windowserver wid=0 " in l and "act two" not in l]
        if found:
            report = found[-1]
            break
        time.sleep(0.1)
    # `vis=true` is the witness: AppKit registers the window with the server
    # before any order (`listed` is true either way, measured), while a window
    # never ordered on screen keeps isVisible false; `onscreen` is Space-scoped
    # and only recorded.
    if "vis=true" not in report or "listed=true" not in report:
        lf.write(
            f"act two published its verdict with NO WINDOW ON SCREEN: the "
            f"window server "
            f"{'never listed the primary window' if not report else 'answered ' + report.strip()}"
            f", so the link started a process that drew nothing a user could "
            f"see. Every observation in act two reads the model, which is "
            f"why the verdict is green ({line})\n")
        return 1
    lf.write(f"act two window: {report.strip()}\n")
    return 0


def log_path(lf):
    """The open file's own path — `open --stdout` takes a PATH, and the
    second process is not this one's child, so its output cannot be
    inherited."""
    return pathlib.Path(lf.name)


def second_act(root, scene, argv, env, log, launch=None):
    """Push this lane's door and join act two's verdict (R6a). Returns 0
    only when the second process published a green ordinary verdict into
    `act2.verdict`; every refusal writes its own sentence into `log`.

    TWO DOORS (docs/tasks-s4-plan.md P5). `launch-notification` is the
    carve-out: macOS has no programmatic tap, so the bundle is started
    again naming the notification and the interpreter enters the centre
    delegate's own funnel. `launch` is the PLAIN one — the same bundle
    started the way a user would, with nothing pending and nothing added
    to the environment at all, which is why the marker on disk is the
    only signal the second process has."""
    d = act2_dir(root, env)
    marker, verdict = d / "marker", d / "act2.verdict"
    door = RELAUNCH_DOOR[scene]
    with open(log, "a", encoding="utf-8", errors="replace") as lf:
        if not marker.is_file():
            lf.write(f"{scene}: act one published ACT 1 OK but left no "
                     f"marker at {marker} — the harness's relaunch arm "
                     f"wrote nothing, so there is no act two to run\n")
            return 1
        verdict.unlink(missing_ok=True)
        act2_env = dict(env)
        # THE SECOND PROCESS HAS NO SCENE IN ITS ENVIRONMENT: the marker
        # is the only source, exactly as the platform's own relaunch
        # would leave it (crates/kaya/src/act2.rs).
        act2_env.pop("KAYA_SELFTEST", None)
        act2_env.pop("KAYA_SELFTEST_SCRIPT", None)
        if door == "link":
            # THE LINK DOOR (docs/app-links-plan.md L5). The RECORDING
            # launcher is deliberately not used: LaunchServices starts
            # the process, so there is no pid for the suite recorder to
            # register and act two's tile would be empty either way.
            url = relaunch_url(
                pathlib.Path(log).read_text(encoding="utf-8", errors="replace"))
            if not url:
                lf.write(f"{scene}: act one printed no "
                         f"`KAYA_RELAUNCH: door link url=` line, so this "
                         f"runner has no URL to push the platform's door "
                         f"with\n")
                return 1
            stem = guest_stem(scene)
            app = root / RUST_GUESTS / f"{stem}.app"
            rc = open_link_door(root, app, url, act2_env, verdict, lf)
            if rc != 0:
                return rc
            line = (verdict.read_text(encoding="utf-8", errors="replace")
                    .strip())
            lf.write(f"{scene}: act two verdict {line}\n")
            return 0 if line.startswith("KAYA_SELFTEST: OK") else 1
        if door == "launch":
            lf.write(f"== act two: {door} ==\n")
        else:
            notification = RELAUNCH_NOTIFICATION[scene]
            lf.write(f"== act two: {door} notification {notification} ==\n")
            act2_env["KAYA_LAUNCH_NOTIFICATION"] = str(notification)
        # FLUSHED BEFORE THE CHILD WRITES THROUGH THE SAME fd, as the link
        # door above flushes: unflushed, this marker lands AFTER act two's
        # own output and the log reads as though act two began at its own
        # verdict (measured in a hand run's log, 2026-09-18).
        lf.flush()
        # RECORDING MODE GIVES THE SECOND PROCESS ITS OWN TILE (P6): the
        # runner hands a launcher that registers the relaunched pid with
        # the suite recorder before it waits, so the film covers act one,
        # the gap and act two, and the stills split at the process.
        rc = (launch or plain_launch)(argv, act2_env, root, lf)
        line = (verdict.read_text(encoding="utf-8", errors="replace").strip()
                if verdict.is_file() else "")
        if not line:
            lf.write(f"{scene}: act two wrote no verdict to {verdict} "
                     f"(the second process exited {rc}) — it either never "
                     f"adopted the marker (no KAYA_ACT2 line above) or "
                     f"died before publishing\n")
            return 1
        lf.write(f"{scene}: act two verdict {line}\n")
        rc = 0 if line.startswith("KAYA_SELFTEST: OK") else 1
        if scene in REAL_STORE_SENTINEL:
            rc = real_store_verdict(root, scene, lf, argv) or rc
        return rc


def act_one_ok(log_text):
    """R6a: act one's line is distinct from the ordinary verdict by
    construction, so a leg that ran a `relaunch` scene and printed the
    ORDINARY one never reached the relaunch."""
    return "KAYA_SELFTEST: ACT 1 OK" in log_text


def leg_argv(scene, lang, hs_bin):
    """The guest command for one leg, through require_modern's stamp wall;
    `hs_bin(stem)` resolves a Haskell binary (cabal list-bin)."""
    stem = guest_stem(scene)
    return require_modern(_guest_argv(scene, lang, hs_bin, stem), lang)


def _guest_argv(scene, lang, hs_bin, stem):
    if lang == "rust":
        return [rust_guest_path(stem)]
    if lang == "python":
        if py_bundled(stem):
            return [f"{PY_GUESTS}/{stem}.app/Contents/MacOS/{stem}", f"guests/python/{stem}.py"]
        return [host_path("python"), f"guests/python/{stem}.py"]
    if lang == "js":
        return [host_path("js"), f"guests/js/{stem}.ts"]
    if lang == "go":
        if scene in BUNDLED_GO_SCENES:
            return [f"{GO_GUESTS}/{scene}.app/Contents/MacOS/{scene}"]
        return [f"{GO_GUESTS}/kaya-go"]
    if lang == "csharp":
        return [host_path("csharp"), CS_GUEST]
    if lang == "ocaml":
        return [f"_build/default/guests/ocaml/{stem}.exe"]
    if lang == "haskell":
        return [hs_bin(stem)]
    if lang == "swift":
        return [f"target/swift-guests/{stem}"]
    if lang == "java":
        return [host_path("java"), "-XstartOnFirstThread", "-cp",
                "target/java-guests", "dev.kaya.guests.Main"]
    if lang == "c":
        return [f"target/c-guests/{stem}"]
    raise ValueError(lang)


def scene_script(root, scene):
    """The scene script's TEXT for the interpreter's environment, comments
    stripped: some transports fold newlines into `;`, and a leading
    comment must not swallow the folded script. Newlines are kept. A scene
    in CUTS is its prefix (scene_cut raises CutRefused for a stale cut)."""
    return "\n".join(scene_cut_lines(root, scene)[0])


def scene_cut_lines(root, scene):
    """(the lines the leg runs, the lines this lane does not run)."""
    path = root / f"tools/scenes/{scene}.steps"
    if scene in CUTS:
        cut = CUTS[scene]
        return scene_cut.scene_prefix(path, cut["cut"], cut["keep"], who="mac")
    return [line for line in path.read_text(encoding="utf-8").splitlines()
            if not line.startswith("#")], []


MEDIA_URL = f"http://{media_server.HOST}:{media_server.PORT}"


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
    if scene in SCENE_LOCALE:
        env["KAYA_LOCALE"] = SCENE_LOCALE[scene]
    if scene in SCENE_CLOCK:
        env["KAYA_CLOCK"] = SCENE_CLOCK[scene]
    from packaging import identity as app_identity
    env.update(app_identity.env_for(guest_stem(scene)))
    if media_server.serves(scene):
        env["KAYA_MEDIA_URL"] = MEDIA_URL
        helper = media_server.mediaremote_lib(root)
        if helper:
            env["KAYA_MEDIAREMOTE_LIB"] = helper
    # ONE STATE HOME PER LEG: the harness's scratch stores and the act-two
    # marker are one tree per APP under it, and the pool runs many legs of
    # one app at once (docs/traps.md, 2026-09-09: a concurrent leg's act
    # one emptied the tree under taskspersist's open database).
    leg = f"{scene}-{lang}" + ("-dark" if appearance else "")
    state = root / "target/mac-legs" / leg / "state"
    state.mkdir(parents=True, exist_ok=True)
    env["XDG_STATE_HOME"] = str(state)
    return env


# ------------------------------------------------------- the guest builds
# ONE COPY OF EVERY BUILD (docs/deferred.md's run-leg entry): the lane
# builds all seven pooled, a hand run builds the one language its leg
# needs, and neither can drift into building it a different way.

def _run(argv, log, **kw):
    """One build command. `log` is a path opened in APPEND mode, or None
    to stream to this process's own stdout — the hand run watches its
    build, the lane keeps a per-language log to print on failure."""
    if log is None:
        return subprocess.run(argv, check=False, **kw)
    with open(log, "a", encoding="utf-8") as f:
        return subprocess.run(argv, check=False, stdout=f,
                              stderr=subprocess.STDOUT, **kw)


def build_ocaml(root, log=None):
    # --root . BECAUSE DUNE WALKS UP: run from a git worktree under
    # the repo, a bare `dune build` builds the PARENT checkout
    # (measured 2026-08-28).
    return _run(["dune", "build", "--root", "."], log, cwd=root)


def build_haskell(root, log=None):
    return _run(["cabal", "build", "all",
                 f"--extra-lib-dirs={root}/target/debug",
                 f"--ghc-options=-L{root}/target/debug "
                 f"-optl-Wl,-rpath,{root}/target/debug", "-v0"],
                log, cwd=root / "guests/haskell")


def build_csharp(root, log=None):
    # dotnet run rebuilds per invocation; build once, legs exec it.
    rc = content_fresh.by_content(
        lambda full: _run(["dotnet", "build", "--nologo", "-v", "q",
                           *(["--no-incremental"] if full else []),
                           "guests/csharp/kaya-guests.csproj"], log, cwd=root).returncode,
        ["guests/csharp", "bindings/csharp"],
        [root / "guests/csharp/bin/Debug/net10.0/kaya-guests.dll"],
        root / "target/csharp-guests.sources.json", skip={"bin", "obj"}, who="build_csharp")
    return subprocess.CompletedProcess([], rc)


def build_go(root, log=None):
    # ONE BINARY FOR EVERY SCENE: guests/go/cmd imports every scene
    # library and picks one from KAYA_SELFTEST. encodebench is
    # guest-only and a benchmark, its own main package.
    (root / "target/go-guests").mkdir(parents=True, exist_ok=True)
    rc = _run(["go", "build", "-o", "target/go-guests/kaya-go",
               "dev.kaya/guests/go/cmd"], log, cwd=root)
    if rc.returncode != 0:
        return rc
    rc = _run(["go", "build", "-o", "target/go-guests/encodebench",
               "dev.kaya/guests/go/encodebench"], log, cwd=root)
    if rc.returncode != 0:
        return rc
    from packaging import mac as packaging_mac
    for scene in sorted(BUNDLED_GO_SCENES):
        app = packaging_mac.bundle(root, root / GO_GUESTS / "kaya-go",
                                   root / GO_GUESTS, stem=scene,
                                   accessory=True)
        # THE PLATFORM'S LAUNCH CARRIES NO KAYA_SELFTEST (docs/traps.md, the
        # cold notification reply of 2026-09-27): the bundle must name its
        # scene itself, asked here with that variable removed.
        bare = {k: v for k, v in os.environ.items() if k != "KAYA_SELFTEST"}
        asked = subprocess.run(
            [str(app / "Contents/MacOS" / scene), "--print-scene"],
            env=bare, capture_output=True, text=True, encoding="utf-8",
            check=False)
        said = asked.stdout.strip()
        if asked.returncode != 0 or said != scene:
            msg = (f"build_go: {app.name} launched with no KAYA_SELFTEST "
                   f"runs scene {said!r} (exit {asked.returncode}), not "
                   f"{scene!r} — guests/go/cmd/main_desktop.go's "
                   f"bundledScene must name it from the executable\n")
            if log:
                with open(log, "a", encoding="utf-8") as f:
                    f.write(msg)
            print(msg, end="", file=sys.stderr)
            return subprocess.CompletedProcess(asked.args, 1)
    return rc


def build_swift(root, log=None):
    """The same bindings the iOS bundles compile — the Kaya package
    target (Package.swift, Swift 6 language mode), built once and linked
    into every guest beside libkaya.dylib. swiftc allows top-level code
    only in a file named main.swift, so each scene gets its own staging
    dir and the compiles pool. DEPTH_SCENES too: a depth slice's guests
    arrive one language at a time, and the file test decides — a scene
    whose Swift guest has not landed is skipped, not a build failure."""
    (root / "target/swift-guests").mkdir(parents=True, exist_ok=True)
    rc = _run(["bash", "-c",
               'source "$1/tools/lib/swift-toolchain.sh" && shift && '
               'kaya_swift "$@"', "_", str(root), "build",
               "--disable-automatic-resolution",
               "--scratch-path", "target/swiftpm"], log, cwd=root)
    if rc.returncode != 0:
        return rc
    procs = []
    for guest in [*SCENES, *DEPTH_SCENES]:
        src = root / f"guests/swift/{guest}.swift"
        if not src.is_file():
            continue
        stage = root / f"target/swift-guests/.stage-{guest}"
        shutil.rmtree(stage, ignore_errors=True)
        stage.mkdir(parents=True)
        shutil.copy2(src, stage / "main.swift")
        companions = []
        if (root / f"guests/swift/{guest}+Kaya.swift").is_file():
            companions = [f"guests/swift/{guest}+Kaya.swift"]
        blog = open(stage / "build.log", "w", encoding="utf-8")
        p = subprocess.Popen(
            ["bash", "-c",
             'source "$1/tools/lib/swift-toolchain.sh" && shift && '
             'kaya_swift_guestc "$@"', "_", str(root),
             "-I", "target/swiftpm/debug/Modules",
             "-I", "bindings/swift/CKaya",
             *companions, str(stage / "main.swift"),
             "target/swiftpm/debug/libKaya.a",
             "-L", "target/debug", "-lkaya",
             "-Xlinker", "-rpath", "-Xlinker",
             f"{root}/target/debug",
             "-o", f"target/swift-guests/{guest}"],
            stdout=blog, stderr=blog, cwd=root)
        procs.append((guest, stage, p, blog))
    rc = 0
    for guest, stage, p, blog in procs:
        failed = p.wait() != 0
        blog.close()
        if failed:
            rc = 1
            text = (stage / "build.log").read_text(encoding="utf-8",
                                                   errors="replace")
            if log is None:
                print(text, end="")
            else:
                with open(log, "a", encoding="utf-8") as out:
                    out.write(text)
    for stage in (root / "target/swift-guests").glob(".stage-*"):
        shutil.rmtree(stage, ignore_errors=True)
    return subprocess.CompletedProcess([], rc)


def build_c(root, log=None):
    # THE C FLOOR, THE SCENES THIS LANE ACTUALLY RUNS: C_SCENES, which
    # check-steps' sweep_c_floor reads from the other side — a guest
    # built here and run nowhere is false coverage.
    rc = content_fresh.by_content(
        lambda full: _run(["make", "-C", "guests/c", *(["-B"] if full else []),
                           f"SCENES={' '.join(C_SCENES)}",
                           f"TARGET_DIR={root}/target/debug",
                           f"OUT={root}/target/c-guests"], log, cwd=root).returncode,
        ["guests/c", "bindings/c", "crates/kaya/include"],
        [root / "target/c-guests" / s for s in C_SCENES],
        root / "target/c-guests.sources.json", who="build_c")
    return subprocess.CompletedProcess([], rc)


def build_java(root, log=None):
    # The shared binding + the desktop transport + every scene + the
    # Main selector, one javac.
    shutil.rmtree(root / "target/java-guests", ignore_errors=True)
    (root / "target/java-guests").mkdir(parents=True)
    srcs = ["bindings/java-desktop/dev/kaya/KayaRing.java",
            *sorted(str(p.relative_to(root))
                    for p in (root / "bindings/java/dev/kaya"
                              ).glob("*.java")),
            *sorted(str(p.relative_to(root))
                    for p in (root / "guests/java/dev/kaya/guests"
                              ).glob("*.java"))]
    return _run(["javac", "--release", "21", "-encoding", "UTF-8", "-d",
                 "target/java-guests", *srcs], log, cwd=root)


# The COMPILED languages, in the order the lane starts them. rust is not
# here: its example is built and staged per leg (validate-mac stages the
# whole set up front, run-leg one stem every run). python and js run from
# source, so their binding is always the tree's.
GUEST_BUILDS = {
    "ocaml": build_ocaml,
    "haskell": build_haskell,
    "csharp": build_csharp,
    "go": build_go,
    "swift": build_swift,
    "java": build_java,
    "c": build_c,
}

# THE SPEC A STAGED GUEST WAS BUILT AGAINST. A compiled guest carries the
# wire hash its binding was generated from and refuses a library speaking
# another one, so a guest staged before a spec move dies at LAUNCH naming
# both hashes (docs/traps.md, 2026-09-06). Nothing on disk said which spec
# the staged tree came from, so a hand run could only learn it by watching
# the panic; every build that succeeds writes it here instead.
SPEC_STAMPS = "target/guest-specs"


def spec_hash(root):
    """The tree's protocol fingerprint out of the generated C header, or
    None if the header does not declare one. bindings/c/kaya_wire.h is the
    right file to ask: gen-bindings.py writes every binding's copy from
    the same spec in one pass, and tools/gen-bindings.py --check is a gate,
    so the header and the nine bindings cannot disagree."""
    text = (root / "bindings/c/kaya_wire.h").read_text(encoding="utf-8")
    m = re.search(r"^#define KAYA_SPEC_HASH\s+(0x[0-9a-fA-F]+)", text, re.M)
    return m.group(1) if m else None


def spec_stamp(root, lang):
    return root / SPEC_STAMPS / f"{lang}.spec"


def stamp_spec(root, lang):
    """Record the spec this build compiled against. Called only after a
    build returned 0 — a stamp over a failed build is the stale artifact
    with a fresh label on it. An unreadable header stamps NOTHING and
    still says so: spec_stamp_problem reads the header first, so the
    missing stamp is never the sentence the reader gets."""
    got = spec_hash(root)
    if got is None:
        return
    p = spec_stamp(root, lang)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(got + "\n", encoding="utf-8")


def spec_stamp_problem(root, lang):
    """None, or the sentence refusing to run a staged guest that is not
    this tree's spec. THREE causes, THREE sentences, each printing only
    what it measured (CLAUDE.md invariant 3)."""
    if lang not in GUEST_BUILDS:
        return None
    want = spec_hash(root)
    if want is None:
        return (f"bindings/c/kaya_wire.h declares no KAYA_SPEC_HASH, so "
                f"nothing here can say which protocol the staged {lang} "
                f"guest speaks. Run tools/gen-bindings.py — the header is "
                f"generated, and every binding's copy moves with it.")
    p = spec_stamp(root, lang)
    if not p.is_file():
        return (f"nothing recorded which spec the staged {lang} guest was "
                f"built against ({SPEC_STAMPS}/{lang}.spec is not there), "
                f"and this tree's bindings/c/kaya_wire.h says {want}. A "
                f"guest staged before a spec move dies at launch with "
                f"`library speaks spec {want}, this binding was generated "
                f"from <older>`. Re-run with --build.")
    got = p.read_text(encoding="utf-8").strip()
    if got != want:
        return (f"the staged {lang} guest was built against spec {got} and "
                f"this tree's bindings/c/kaya_wire.h says {want}: it would "
                f"die at launch with `library speaks spec {want}, this "
                f"binding was generated from {got}`. Re-run with --build.")
    return None


def build_guests(root, langs, log_dir=None):
    """The named languages' builds, POOLED (measured 2026-07-22: 29-38s
    serial, bounded by the slowest language pooled). Each writes
    `<log_dir>/<lang>.log`, or streams to stdout when log_dir is None.
    Returns {lang: returncode}, with 1 for a build whose thread died."""
    rc = {}
    threads = []
    for lang in langs:
        fn = GUEST_BUILDS[lang]
        log = (log_dir / f"{lang}.log") if log_dir is not None else None

        def go(lang=lang, fn=fn, log=log):
            got = fn(root, log).returncode
            if got == 0:
                stamp_spec(root, lang)
            rc[lang] = got

        t = threading.Thread(target=go)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    return {lang: rc.get(lang, 1) for lang in langs}


_HS_BINS = {}


def hs_bin(root, name):
    """A Haskell guest's binary, cached — cabal takes ~0.4s to answer and
    the lane asks once per haskell leg."""
    key = (str(root), name)
    if key not in _HS_BINS:
        got = subprocess.run(["cabal", "list-bin", name, "-v0"],
                             cwd=root / "guests/haskell",
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=False,
                             text=True, encoding="utf-8", errors="replace")
        _HS_BINS[key] = got.stdout.strip()
    return _HS_BINS[key]


def scene_host_verbs(root, scene):
    """{verb: (kind, takes)} for the HOST_VERBS the leg's own lines run; a
    scene with no script runs none (tools/check-steps.py refuses that leg)."""
    out = {}
    if not (root / f"tools/scenes/{scene}.steps").is_file():
        return out
    for line in scene_cut_lines(root, scene)[0]:
        words = line.split()
        if words and words[0] in HOST_VERBS:
            out.setdefault(words[0], HOST_VERBS[words[0]])
    return out


def _host_legs(root):
    exclusive_legs, takeover, session = set(), {}, {}
    for name, scene, _lang in legs():
        verbs = scene_host_verbs(root, scene)
        if verbs:
            exclusive_legs.add(name)
        takes = sorted({what for kind, what in verbs.values() if kind == "takeover"})
        if takes:
            takeover[name] = " and ".join(takes)
        holds = sorted({what for kind, what in verbs.values() if kind == "session"})
        if holds and not takes:
            session[name] = " and ".join(holds)
    return exclusive_legs, takeover, session


def _scenes_root():
    """The tree whose tools/scenes this module reads: its own, or for a
    gate's doctored copy in scratch, the working directory's."""
    for root in (*pathlib.Path(__file__).resolve().parents, pathlib.Path.cwd()):
        if (root / "tools/scenes").is_dir():
            return root
    raise RuntimeError(f"{__file__}: no tools/scenes above this file or in "
                       f"{pathlib.Path.cwd()}, so no leg's host verbs can be read")


EXCLUSIVE, TAKEOVER_LEGS, SESSION_LEGS = _host_legs(_scenes_root())
TAKEOVER_SCENES = {scene for name, scene, _lang in legs() if name in TAKEOVER_LEGS}
