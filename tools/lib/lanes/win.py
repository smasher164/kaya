"""The windows lane's tables — ONE source of truth for the roster
the runner executes and the gates census (the runner-conversion
ruling, docs/runner-conversion-plan.md §2: the leg tables become an
importable data module, the runner consumes it, and the parsers
that read tools/deploy-win.py's TEXT become imports of these same
tables).

Plain data on build-id.py's GATES model: no I/O at import, no
dev-shell guard — a table must be importable anywhere a gate runs.
The runner is tools/deploy-win.py; the gates that import this are
check-steps, check-staging, check-appearance, check-stubs and
tools/lib/scene-features.py (check-assets, check-build-id and
check-gates read the runner BODY, which is behaviour, not a table).
"""

import os
import pathlib
import re

# THE scene list: every mechanical per-scene surface derives from it
# (cross-build examples, exe/python shipping, taskkill). Adding a
# scene here is the ONE registration; ORDER stays explicit because
# it encodes per-language coverage decisions.
SCENES = [
    "background", "stall", "milestone2", "entry", "gallery", "todos",
    "reorder", "feed", "grow", "layout", "align", "window", "panels",
    "confirm", "nav", "split", "panes", "table", "scroll",
    "progress", "select", "radio", "grid", "textarea", "search", "submit", "scrollto", "fullscreen",
    "numberfield", "timecode", "colorpicker", "range", "secure", "autofill", "reveal",
    "segmented",
    "expander",
    "toast",
    "sections",
    "menus", "commands", "a11y", "a11yrows", "filedialog",
    "clipboard", "undo", "dirty", "ranges", "save", "styling",
    "typeface", "toolbar", "identity", "assets", "adaptive", "dnd", "pickers", "sliders", "tooltips",
    "sheet",
    # The formatter door and the catalog in every language this lane runs
    # (docs/compliance-plan.md §6); formatde/formatar reuse its guests.
    "format",
    # The media suite's one guest in every language (docs/media-plan.md
    # §7a); its scenes are media_formats and kin, GUEST_STEM below.
    "media",
    # The capture (docs/capture-plan.md); capture_denied runs its guest.
    "capture",
]

# THE LEGS THAT RUN AS THE ONLY INPUT-DRIVING LEG ON THE HOST (tools/lib/
# exclusive.py): the drag family, already alone inside this lane for the
# OLE reasons above, so an exclusive-only run carries them and the everyday
# matrix can leave them (the maintainer, 2026-09-06: the drags are what
# make a matrix long).
EXCLUSIVE = {"dnd_rust", "dnd_python", "dnd_js", "dnd_go", "dnd_csharp", "dnd_java",
             "dndwitness_rust", "dndforeign_rust",
             # notes types three seconds after launch, while a pooled
             # neighbour's window is still taking the foreground; twice
             # red under a matrix, green alone (docs/deferred.md, the
             # PopupHost WATCH's second sighting, 2026-09-15).
             "notes_rust",
             # The emoji panel holds the keyboard while it is open, and the
             # pick types into its search (docs/emoji-picker-plan.md §5).
             "emoji_rust",
             # THE TEXT-SCALE LEGS (docs/compliance-plan.md R5, U3): the
             # setting is the user's, written before and deleted after, so
             # nothing else may be running under it.
             "tasksbig_rust", "formatbig_rust",
             # THE 24-HOUR CLOCK LEG: the Region keys are the user's
             # (CLOCK24_LEGS), written before and restored after.
             "clock24_rust",
             # FULLSCREEN (docs/fullscreen-plan.md §5): the window covers the
             # VM's display and the user half presses F11 on the system
             # input queue, so a neighbour taking the foreground would take
             # the key.
             "fullscreen_rust", "fullscreen_python", "fullscreen_js",
             "fullscreen_go", "fullscreen_csharp", "fullscreen_java"}

# The legs that run under the user's 24-hour clock: HKCU\Control Panel\
# International's iTime and sShortTime, written by deploy-win before the leg
# and put back to the VM's own values after (docs/compliance-plan.md §4; U11
# measured the keys reaching a fresh process's formatters).
CLOCK24_LEGS = {"clock24_rust"}

# The user's text scale a leg runs under, as HKCU\Software\Microsoft\
# Accessibility's TextScaleFactor percentage, written by deploy-win before
# the leg and deleted after (R5; a fresh process reads it, U3).
TEXT_SCALE_LEGS = {"tasksbig_rust": 200, "formatbig_rust": 200}

# Depth-slice scenes: a rust example + steps exist, the language
# sweep has not landed. Built, shipped and run RUST-ONLY — the
# deploy-win twin of validate-mac's DEPTH_SCENES. The gates read
# THIS default; the runner calls depth_scenes(), which honours the
# KAYA_WIN_DEPTH_SCENES override the lane uses for one-off slices.
DEPTH_SCENES = ["windowed", "canvas", "sizepolicy", "tasks", "notify", "richtext", "flexshrink",
                "listrow", "tints", "badge", "emoji",
                "ownundo", "richlabel", "notes", "richrows"]

# THE PACKAGED LEGS (docs/packaging-plan.md P3): the SAME Rust guests, run
# out of an installed MSIX instead of out of C:\kaya, because a kaya app is
# either a packaged process or it is not and users will do both. leg -> the
# scene, which is also the exe's stem and the package's `<Application Id>`.
# The launchers are a PAIR — run_<leg>.cmd hands the leg to
# tools/guest/pkg-run.ps1 and pkg_<leg>.cmd runs inside the package, since
# the caller's environment does not cross Invoke-CommandInDesktopPackage.
PACKAGED_LEGS = {"notifypkg_rust": "notify", "taskspkg_rust": "tasks"}


def packaged_inner(leg):
    """The launcher that runs INSIDE the package for a packaged leg."""
    return f"pkg_{leg}.cmd"


# THE SECOND ACT'S DOOR, per scene that has a `relaunch` line
# (docs/tasks-s9-plan.md R6/R6a). Windows has no programmatic tap, so the
# runner pushes the OS's own door one step past it: `CoCreateInstance` of the
# COM activator's class id, which starts the exe through LocalServer32 (the
# library's HKCU registration) or through the package's `com:ExeServer`, and
# then calls `Activate` with the toast's launch arguments. Measured
# 2026-09-08 on both routes.
#
# S4's scenes relaunch with NOTHING PENDING, so they take the PLAIN door
# (docs/tasks-s4-plan.md P5): the runner starts the same exe the way a user
# would — no KAYA_* signalling the harness, the act-two marker on disk the
# only thing that says a second act exists. The word is the scene's own:
# `relaunch launch` makes the harness print `KAYA_RELAUNCH: door launch`,
# which the runner requires before it pushes anything.
#
# THE LINK DOOR (docs/app-links-plan.md L5) is a third: the runner asks the
# SHELL to open the URL act one printed, and Windows starts the process
# through the protocol registration the app wrote for itself at launch. The
# URL rides a FILE rather than a `%1` — `=` is an argument delimiter in a
# .cmd's %1..%9 and `&` is a cmd operator, so a link with a query cannot be
# a positional argument (measured 2026-09-09) — and the door's own .cmd sets
# the leg's XDG_STATE_HOME, since the activated process is a DIRECT CHILD of
# the calling cmd and inherits its environment (measured the same day; the COM
# door needs relaunch-com.ps1's user-environment trick because a LocalServer32
# is started by the COM service instead).
RELAUNCH_DOOR = {"tasks": "com-activator", "taskspersist": "launch",
                 "links": "link"}
# The door scripts the runner drives (tools/guest/, shipped by the deploy),
# one per door.
RELAUNCH_DOOR_SCRIPT = "relaunch-com.ps1"
RELAUNCH_LAUNCH_SCRIPT = "relaunch-launch.ps1"
RELAUNCH_LINK_SCRIPT = "relaunch-link.ps1"
# The exe a door names for a scene whose guest is another scene's (taskspersist
# and links both run the tasks app under their own scene name, exactly as the
# linux lane does). The plain door STARTS it; the link door only names it, to
# say whether it is on this guest at all and to stop the process the shell
# started.
RELAUNCH_EXE = {"taskspersist": "tasks", "links": "tasks"}
# The launch string `Activate` is handed, in the two pieces cmd.exe can carry:
# `=` is an ARGUMENT DELIMITER in a .cmd's %1..%9, so `kaya=1` arrives as two
# tokens and the door opens with a launch string naming no id (measured
# 2026-09-08). The key is crates/kaya/src/winui/mod.rs's NOTIFICATION_ARG_KEY
# and the id is the tasks guest's own for t1 (docs/tasks-s9-plan.md R2).
RELAUNCH_ARG_KEY = "kaya"
RELAUNCH_NOTIFICATION = 1


def depth_scenes():
    env = os.environ.get("KAYA_WIN_DEPTH_SCENES")
    return env.split() if env else list(DEPTH_SCENES)


# A guest that exists in Go and only Go BY DESIGN (docs/editor-plan.md
# — an editor in Rust would be kaya testing itself). Joins the
# taskkill sweep and nothing per-language.
GO_ONLY_SCENES = ["editor", "chat"]
# Python BY DESIGN: the portfolio (docs/portfolio-plan.md) and the
# variable-height scene (docs/virtualization-plan.md §5). They join
# the .py ship and stamp, and no exe family.
PY_ONLY_SCENES = ["portfolio", "varied"]

# milestone2's six legs are the bare language names; their scene is
# milestone2 and their launchers are run_rust.cmd and kin. The js legs
# mirror the python ones leg for leg (2026-09-01): pooled where python
# is pooled, alone where python is alone, absent where python is absent.
MILESTONE2_LEGS = ("rust", "python", "go", "csharp", "java", "js")

# THE VERBS THAT AIM AT SCREEN COORDINATES, and the ONE placement rule they
# force. A tile slot is a position on the desktop: this VM's slots 4 and 5 sit
# at y=786 on an 800-tall screen, so a window there puts a drag's source off
# the bottom and the verb refuses by name — measured 2026-09-08, `drag: the
# source's box (271.0, 918.0, 97.8, 18.6) is off a 1280x800 screen`, when a
# packaged tasks leg drew slot 4. Every other verb drives or reads a CONTROL
# and does not care where the window is. A leg that runs ALONE always gets
# slot 0 (deploy-win's `_release_slot` sorts the free list), so the rule is
# simply: a pointer leg is never pooled. tools/deploy-win.py refuses the
# roster and tools/check-steps.py holds it.
POINTER_VERBS = ("drag", "drag_file")


def pointer_scenes(scenes_dir):
    """{scene: the first pointer verb its script uses}, READ OUT OF THE
    SCENE SCRIPTS. Never a hand list of legs: a hand list is what goes
    stale the day a scene grows a drag."""
    found = {}
    for path in sorted(pathlib.Path(scenes_dir).glob("*.steps")):
        for line in path.read_text(encoding="utf-8").splitlines():
            head = line.strip().split(" ")[0] if line.strip() else ""
            if head in POINTER_VERBS:
                found[path.stem] = head
                break
    return found


# THE VERBS THAT MEAN A REAL TOAST WENT UP, and the ONE ordering rule they
# force: A NOTIFICATION LEG NEVER RUNS IN THE POOL AN EXCLUSIVE LEG'S FUNNEL
# DRAINS. The shell's notification host window comes up ~2s AFTER a
# notification is delivered, holds the foreground with nothing in it and
# refuses SetForegroundWindow for 30s and more (docs/deferred.md, the phantom
# notification window), and the funnel joins every leg started before it in
# its block — so a notification raised there is in flight exactly when the
# typing leg foregrounds. tools/check-exclusive.py holds it.
NOTIFICATION_VERBS = ("expect_notification", "notification_activate")


def notification_scenes(scenes_dir):
    """Every scene whose script asserts a DELIVERED notification, READ OUT
    OF THE SCENE SCRIPTS — pointer_scenes' own reason: a hand list is what
    goes stale the day a scene grows a toast."""
    found = set()
    for path in sorted(pathlib.Path(scenes_dir).glob("*.steps")):
        for line in path.read_text(encoding="utf-8").splitlines():
            head = line.strip().split(" ")[0] if line.strip() else ""
            if head in NOTIFICATION_VERBS:
                found.add(path.stem)
                break
    return found


def notification_legs(scenes_dir):
    """Every leg of this lane whose scene posts a notification."""
    scenes = notification_scenes(scenes_dir)
    return {leg for leg in legs() if scene_lang(leg)[0] in scenes}


def pooled_pointer_legs(scenes_dir):
    """{leg: verb} for every leg that drives the real pointer and is NOT
    alone in its block — the pool may place any of them on a tile that
    leaves the screen."""
    pointer = pointer_scenes(scenes_dir)
    return {leg: pointer[scene_lang(leg)[0]] for leg in legs()
            if scene_lang(leg)[0] in pointer and not alone(leg)}


# THE ROSTER AND ITS ORDER. A list of BLOCKS: each block's legs run in
# the WIDTH-wide slot pool and the pool DRAINS between blocks, so a
# one-leg block runs ALONE. The barriers are measured contention fixes,
# never style, and check-steps' serial clauses read this structure.
ORDER = [
    # The wide pool: no typed input, no window close, no OS-global
    # chrome in any of these. milestone2's five legs are the bare
    # language names (their launchers are run_rust.cmd and kin).
    [
     # THE CAPTURE LEGS, FIRST so their one-at-a-time run ends inside the
     # pool's: SERIAL_GROUPS' camera group, beside everything else here.
     "capture_rust", "capture_python", "capture_js", "capture_go",
     "capture_csharp", "capture_java",
     "capture_denied_rust", "capture_denied_python", "capture_denied_js",
     "capture_denied_go", "capture_denied_csharp", "capture_denied_java",
     "rust", "python", "js", "go", "csharp", "java",
     "entry_rust", "entry_python", "entry_js", "entry_go", "entry_csharp", "entry_java",
     "gallery_rust", "gallery_python", "gallery_js", "gallery_go", "gallery_csharp", "gallery_java",
     "todos_rust", "todos_python", "todos_js", "todos_go", "todos_csharp", "todos_java",
     "reorder_rust", "reorder_python", "reorder_js", "reorder_go", "reorder_csharp", "reorder_java",
     "table_rust", "table_python", "table_js", "table_go", "table_csharp", "table_java",
     "feed_rust", "feed_python", "feed_js", "feed_go", "feed_csharp", "feed_java",
     "grow_rust", "grow_python", "grow_js", "grow_go", "grow_csharp", "grow_java",
     "align_rust", "align_python", "align_js", "align_go", "align_csharp", "align_java",
     "window_rust", "window_python", "window_js", "window_go", "window_csharp", "window_java",
     "panels_rust", "panels_python", "panels_js", "panels_go", "panels_csharp", "panels_java",
     "stall_rust", "stall_python", "stall_js", "stall_go", "stall_csharp", "stall_java",
     "confirm_rust", "confirm_python", "confirm_js", "confirm_go", "confirm_csharp", "confirm_java",
     "nav_rust", "nav_python", "nav_js", "nav_go", "nav_csharp", "nav_java",
     "scroll_rust", "scroll_python", "scroll_js", "scroll_go", "scroll_csharp", "scroll_java",
     "progress_rust", "progress_python", "progress_js", "progress_go", "progress_csharp", "progress_java",
     "a11y_rust", "a11y_python", "a11y_js", "a11y_go", "a11y_csharp", "a11y_java",
     "select_rust", "select_python", "select_js", "select_go", "select_csharp", "select_java",
     "radio_rust", "radio_python", "radio_js", "radio_go", "radio_csharp", "radio_java",
     # The segmented control (docs/segmented-plan.md): `choose` runs the
     # item peer's SelectionItem pattern, no real mouse.
     "segmented_rust", "segmented_python", "segmented_js", "segmented_go", "segmented_csharp",
     "segmented_java",
     "grid_rust", "grid_python", "grid_js", "grid_go", "grid_csharp", "grid_java",
     "textarea_rust", "textarea_python", "textarea_js", "textarea_go", "textarea_csharp", "textarea_java",
     "sections_rust", "sections_python", "sections_js", "sections_go", "sections_csharp", "sections_java",
     "layout_rust", "layout_python", "layout_js", "layout_go", "layout_csharp", "layout_java",
     # The pickers pool like the gallery: set_date and set_time drive the
     # CONTROL's own property, no real mouse and no OS-global chrome. RUST
     # ALONE while the eight bindings' sugar is the parallel worktree
     # (docs/datetime-plan.md §5 step 6) — hence the DEPTH_SCENES row, which
     # ships the exe and no .py or .ts; the other five legs join this line
     # with their guests.
     "pickers_rust", "pickers_python", "pickers_js", "pickers_go", "pickers_csharp", "pickers_java",
     # The colour pickers pool for the pickers' reason: `set_color` writes
     # the ColorPicker's own property and runs the flyout's close path with
     # the flyout never shown (docs/color-picker-plan.md §5).
     "colorpicker_rust", "colorpicker_python", "colorpicker_js", "colorpicker_go",
     "colorpicker_csharp", "colorpicker_java",
     # The sliders pool for the pickers' reason: `set_value` drives the
     # CONTROL's own property, no real mouse and no OS-global chrome. RUST
     # ALONE while the eight bindings' sugar is the parallel worktree
     # (docs/slider-plan.md §5) — hence the DEPTH_SCENES row, which ships
     # the exe and no .py or .ts; the other five legs join this line with
     # their guests.
     "sliders_rust", "sliders_python", "sliders_js", "sliders_go", "sliders_csharp", "sliders_java",
     # The range pools for the sliders' reason: `set_value` drives a thumb's
     # own Slider, and a nudge is one arrow key to a focused thumb, the
     # number field's Tab one control over (docs/range-plan.md §5).
     "range_rust", "range_python", "range_js", "range_go", "range_csharp", "range_java",
    "tooltips_rust", "tooltips_python", "tooltips_js", "tooltips_go", "tooltips_csharp", "tooltips_java",
     # The sheet pool: the modal Popup and the close button's own route,
     # no real mouse and no OS-global key (docs/sheet-plan.md U1).
     "sheet_rust", "sheet_python", "sheet_js", "sheet_go", "sheet_csharp", "sheet_java",
     # The toast pool: the InfoBar's own buttons pressed through their
     # peers and Edit>Undo through menu_activate's invoke pipeline, no real
     # mouse and no OS-global key (docs/toast-plan.md T10).
     "toast_rust", "toast_python", "toast_js", "toast_go", "toast_csharp", "toast_java",
    ],
    # THE MEDIA SUITE (docs/media-plan.md §7a), pooled: every player is
    # muted, nothing is typed or pointed at, and the picture is read out of
    # the leg's own window. The local server is the runner's
    # (tools/lib/media_server.py, LANE_PORTS["windows"]).
    [
     # The bound (docs/media-plan.md §7c): a source the server never answers
     # fails `timeout`; progressive, so it pools. FIRST: its 37 s ended the
     # block when it was submitted last.
     "media_timeout_rust",
     "media_formats_rust", "media_formats_python", "media_formats_js",
     "media_formats_go", "media_formats_csharp", "media_formats_java",
     "media_feed_rust", "media_feed_python", "media_feed_js",
     "media_feed_go", "media_feed_csharp", "media_feed_java",
     # The reader (docs/media-plan.md §8): nothing played, nothing typed.
     "media_reader_rust", "media_reader_python", "media_reader_js",
     "media_reader_go", "media_reader_csharp", "media_reader_java",
    ],
    # media_delivery TWO AT A TIME, media_tracks ALONE (RULED 2026-10-01 and
    # amended 2026-10-06, docs/media-plan.md §7c): Media Foundation's adaptive
    # pipeline loses an event when media guests run beside each other on the
    # loaded VM, measured 1 in about 12 legs six wide, 1 in 48 two wide, 0 in
    # 48 one at a time (docs/traps.md, the WinUI adaptive pipeline that goes
    # idle). The lost open is rebuilt once since 2026-10-05; the lost paused
    # seek, media_tracks' face, has no such recovery.
    ["media_delivery_rust", "media_delivery_python"],
    ["media_delivery_js", "media_delivery_go"],
    ["media_delivery_csharp", "media_delivery_java"],
    ["media_tracks_rust"],
    ["media_tracks_python"],
    ["media_tracks_js"],
    ["media_tracks_go"],
    ["media_tracks_csharp"],
    ["media_tracks_java"],
    # EACH media_session LEG ALONE: the system's media session manager is one
    # per desktop, every unpackaged kaya process wears the same declared app id
    # in it, and the leg sends commands through it to whichever session
    # carries that id (docs/media-plan.md §5).
    [
     "media_session_rust",
    ],
    [
     "media_session_python",
    ],
    [
     "media_session_js",
    ],
    [
     "media_session_go",
    ],
    [
     "media_session_csharp",
    ],
    [
     "media_session_java",
    ],
    # dirty_rust ALONE: the leg drives a real WM_CLOSE on its own
    # window and the veto keeps it — a window disappearing out from
    # under a pooled leg reads as somebody else's bug.
    [
     "dirty_rust",
    ],
    # Pooled depth + python-only + the styling family, each rust-only or
    # python-only by design (docs/canvas-plan.md,
    # docs/virtualization-plan.md §6.3, docs/portfolio-plan.md).
    # canvasdark is the appearance override's set proof, running the same
    # canvas.exe under KAYA_APPEARANCE=dark.
    [
     "windowed_rust",
     # A row wider than its window (docs/flex-shrink-plan.md §6).
     "flexshrink_rust",
     # The common list-row shapes (docs/deferred.md).
     "listrow_rust",
     # The platform tints on a filled container, light and dark
     # (docs/tints-plan.md).
     "tints_rust",
     "tintsdark_rust",
     # The expander (docs/expander-plan.md): `toggle` takes the header's
     # own door, no real mouse.
     "expander_rust", "expander_python", "expander_js", "expander_go", "expander_csharp",
     "expander_java",
     "canvas_rust",
     "canvasdark_rust",
     "sizepolicy_rust",
     # The format guests under the everyday locale and two knobs: POOLED,
     # since the knob is per process (a language list per formatter and
     # the window ground's own Language, U5) and nothing on the host moves.
     "format_rust", "format_python", "format_js", "format_go", "format_csharp", "format_java",
     "formatde_rust", "formatde_python", "formatde_js", "formatde_go", "formatde_csharp", "formatde_java",
     "formatar_rust", "formatar_python", "formatar_js", "formatar_go", "formatar_csharp", "formatar_java",
     # The task manager in Arabic (docs/compliance-plan.md §6): POOLED,
     # unlike tasks_rust — no drag, no notification, no relaunch.
     "tasksrtl_rust",
     # The scroll guest's sideways strip in Arabic (docs/hscroll-plan.md §4).
     "scrollrtl_rust",
     # The range guest in Arabic (docs/range-plan.md §3 rules 5, 6): the range
     # mirrors, the vertical fader does not.
     "rangertl_rust",
     # THE RICH LABEL (docs/rich-text-plan.md §15). POOLED, unlike its
     # richtext neighbour: a label is read-only, so the scene clicks two
     # buttons and reads the runs back — no typed input, no composition, no
     # OS-global chrome. RUST-ONLY while the eight bindings' sugar is the
     # parallel worktree — hence the DEPTH_SCENES row.
     "richlabel_rust",
     "richrows_rust",
     "notes_rust",
     # The notification conformance scene (docs/tasks-s3-plan.md N5). POOLED:
     # the platform keys a notification by the AUMID `Register()` derives from
     # the EXE, so this leg's history is its own, and a toast banner neither
     # takes the foreground nor lands where a pooled window is tiled. AFTER
     # notes_rust, never before it, by the NOTIFICATION_VERBS rule above.
     "notify_rust",
     "portfolio_python",
     "varied_python",
     "a11yrows_rust", "a11yrows_python", "a11yrows_js", "a11yrows_go", "a11yrows_csharp", "a11yrows_java",
     "styling_rust", "styling_python", "styling_js", "styling_go", "styling_csharp", "styling_java",
     "typeface_rust", "typeface_python", "typeface_js", "typeface_go", "typeface_csharp", "typeface_java",
     "identity_rust", "identity_python", "identity_js", "identity_go", "identity_csharp", "identity_java",
     "toolbar_rust", "toolbar_python", "toolbar_js", "toolbar_go", "toolbar_csharp", "toolbar_java",
     "assets_rust", "assets_python", "assets_js", "assets_go", "assets_csharp", "assets_java",
     # THE NOTIFY GUEST, PACKAGED (docs/packaging-plan.md P3, PACKAGED_LEGS
     # above). Pooled beside its unpackaged twin for notify_rust's own reason
     # and one more: the package's AUMID is the platform's `<family>!<app>`
     # and the unpackaged one is the declared id, so the two processes'
     # notification histories are separate stores and neither can read the
     # other's. LAST in the block, so no leg before it changes tile slot.
     "notifypkg_rust",
    ],
    # THE TASK MANAGER, BOTH WAYS, EACH ALONE. A RUST app by design
    # (docs/tasks-plan.md §0), and its scene `drag`s real screen pixels, which
    # is the POINTER_VERBS rule above: a pooled pointer leg can draw a tile
    # that leaves the screen. tasks_rust was pooled SECOND and passed on that
    # luck for a milestone; the packaged twin, pooled fifth, drew slot 4 and
    # the drag refused by name.
    [
     "tasks_rust",
    ],
    # taskspkg_rust ALONE, and the reason is a MEASURED one: the tasks scene
    # `drag`s real screen pixels, and the tiling's slots 4 and 5 sit at y=786
    # on this VM's 800-tall screen. Pooled fifth it drew slot 4 and the drag
    # refused with `the source's box (271.0, 918.0, ...) is off a 1280x800
    # screen`. A leg that runs alone always gets slot 0 (deploy-win's
    # `_release_slot` sorts). Its unpackaged twin is pooled SECOND, which is
    # the same luck spelled differently.
    [
     "taskspkg_rust",
    ],
    # WHAT SURVIVES A RELAUNCH (docs/tasks-s4-plan.md §4), the SAME guest
    # under its own scene: alone because every relaunch leg is (check-steps'
    # own clause — the door reaches whichever kaya process holds it), and
    # because the scene resizes the primary window and then reads that frame
    # back out of a second process.
    [
     "taskspersist_rust",
    ],
    # THE TEXT-SCALE LEGS, each alone: the registry setting is the user's
    # (TEXT_SCALE_LEGS; docs/compliance-plan.md R5).
    [
     "tasksbig_rust",
    ],
    [
     "formatbig_rust",
    ],
    # THE 24-HOUR CLOCK LEG, alone: the Region keys are the user's
    # (CLOCK24_LEGS).
    [
     "clock24_rust",
    ],
    # WHAT A LINK OPENS (docs/app-links-plan.md L5), the tasks guest again
    # under its own scene: ALONE for the relaunch reason above and one more
    # this platform has by itself — every activation starts a NEW PROCESS that
    # asks who holds the single-instance key, and every kaya process on this
    # guest registers that key under the SAME declared id, so a pooled
    # neighbour would be handed this leg's link.
    [
     "links_rust",
    ],
    # dnd_rust ALONE: the `drag` verb moves the REAL MOUSE across the
    # desktop and presses it (docs/dnd-plan.md D10 — there is no
    # generalized DoDragDrop for a UI element and OLE's modal loop reads
    # real mouse messages), so a pooled neighbour would be dragged over
    # mid-scene. check-steps' menu_serial pins the barrier.
    [
     "dnd_rust",
    ],
    [
     "dnd_python",
    ],
    [
     "dnd_js",
    ],
    [
     "dnd_go",
    ],
    [
     "dnd_csharp",
    ],
    [
     "dnd_java",
    ],
    # THE CROSS-APP WITNESSES (docs/dnd-plan.md §5 step 7), each alone for
    # dnd_rust's reason and one more: a second process's window is on the
    # desktop and a real drag crosses between them, so a pooled leg would
    # be dragged over AND would take the foreground the gesture needs.
    # `dndwitness` is kaya SOURCE -> a stock Win32 OLE reader; `dndforeign`
    # is a Win32 OLE source and Explorer -> kaya, which is the classic
    # route's own reason for existing (probe 2).
    [
     "dndwitness_rust",
    ],
    [
     "dndforeign_rust",
    ],
    # ranges_rust ALONE: `type` injects OS-GLOBAL keystrokes and
    # `compose` starts a TSF composition in whatever document holds the
    # keyboard focus — a pooled leg stealing the foreground mid-scene
    # would put a composition in someone else's control.
    [
     "ranges_rust",
    ],
    # richtext_rust ALONE, ranges' two reasons exactly: it types and it
    # composes (docs/rich-text-plan.md §4). RUST-ONLY while the eight
    # bindings' sugar is the parallel worktree — hence the DEPTH_SCENES row.
    [
     "richtext_rust",
    ],
    # ownundo_rust ALONE, ranges' first reason: its `type` verb puts REAL
    # KEYSTROKES on the system input queue and foregrounds the guest to do it
    # (docs/rich-text-plan.md §14 — the app's history is made of what was
    # typed). RUST-ONLY while the eight bindings' sugar is the parallel
    # worktree — hence the DEPTH_SCENES row.
    [
     "ownundo_rust",
    ],
    # search AND submit POOL (the maintainer, 2026-10-06; docs/traps.md, the
    # WinUI keystrokes posted to the input site): `type` and `press return`
    # post to each guest's own window, so neighbours no longer eat each
    # other's keys.
    [
     "search_rust", "search_python", "search_js", "search_go", "search_csharp", "search_java",
    ],
    [
     "submit_rust", "submit_python", "submit_js", "submit_go", "submit_csharp", "submit_java",
    ],
    # The secure field (docs/secure-entry-plan.md): type_secret posts to the
    # guest's own input site, as `type` does.
    [
     "secure_rust", "secure_python", "secure_js", "secure_go", "secure_csharp", "secure_java",
    ],
    # EACH number field LEG STILL ALONE (docs/traps.md, the WinUI keystrokes
    # posted to the input site): a pooled neighbour's window taking the
    # activation moves the box's focus, and its focus loss is a commit door,
    # measured committing mid-scene in five pooled runs.
    [
     "timecode_rust",
    ],
    [
     "timecode_python",
    ],
    [
     "timecode_js",
    ],
    [
     "timecode_go",
    ],
    [
     "timecode_csharp",
    ],
    [
     "timecode_java",
    ],
    [
     "numberfield_rust",
    ],
    [
     "numberfield_python",
    ],
    [
     "numberfield_js",
    ],
    [
     "numberfield_go",
    ],
    [
     "numberfield_csharp",
    ],
    [
     "numberfield_java",
    ],
    [
     "numberfieldde_rust",
    ],
    [
     "numberfieldde_python",
    ],
    [
     "numberfieldde_js",
    ],
    [
     "numberfieldde_go",
    ],
    [
     "numberfieldde_csharp",
    ],
    [
     "numberfieldde_java",
    ],
    # Under ar-EG, what a typed number may contain (docs/number-field-plan.md
    # §3 rule 5); the rule is the core's, so rust alone.
    [
     "numberfieldar_rust",
    ],
    [
     "scrollto_rust", "scrollto_python", "scrollto_js",
     "scrollto_go", "scrollto_csharp", "scrollto_java",
    ],
    # EACH fullscreen LEG ALONE, submit's reason: F11 is a real keystroke on
    # the system queue, and the window covers the display (EXCLUSIVE above).
    [
     "fullscreen_rust",
    ],
    [
     "fullscreen_python",
    ],
    [
     "fullscreen_js",
    ],
    [
     "fullscreen_go",
    ],
    [
     "fullscreen_csharp",
    ],
    [
     "fullscreen_java",
    ],
    # The filedialog family, ONE LEG PER DRAIN: the Shell's dialog is
    # OS-GLOBAL modal chrome — it must hold the FOREGROUND to be driven,
    # and the harness finds it by walking the desktop, so two at once
    # means both fail (measured 2026-07-31: the rust leg was green for
    # weeks and started failing the moment a python leg joined it).
    [
     "filedialog_rust",
    ],
    [
     "filedialog_python",
    ],
    [
     "filedialog_js",
    ],
    [
     "filedialog_go",
    ],
    [
     "filedialog_csharp",
    ],
    [
     "filedialog_java",
    ],
    # A clip picked through the Shell's dialog and played (docs/media-plan.md
    # §2): the filedialog rule, one leg per drain.
    [
     "media_picked_rust",
    ],
    # save_rust: the filedialog rule — the save dialog is the same
    # OS-global `#32770` chrome, found the same way.
    [
     "save_rust",
    ],
    [
     "save_java",
    ],
    # editor_go, for BOTH serial reasons: open/save dialogs plus
    # OS-global `type` keystrokes (docs/editor-plan.md; Go alone by
    # design — an editor in Rust would be kaya testing itself).
    [
     "editor_go",
    ],
    # chat_go: OS-global `type` keystrokes into its compose field, the
    # submit legs' serial reason (docs/chat-plan.md).
    [
     "chat_go",
    ],
    # badge_rust ALONE: every unpackaged kaya process groups under the one
    # declared AUMID, so the taskbar overlay it sets and reads belongs to
    # that group, last writer wins (docs/app-badge-plan.md §2).
    [
     "badge_rust",
    ],
    # emoji_rust ALONE: it types into the system's emoji panel.
    [
     "emoji_rust",
    ],
    # The reveal toggle (docs/reveal-plan.md): type_secret posts to the guest's
    # own input site, as the secure field's legs do.
    [
     "reveal_rust", "reveal_python", "reveal_js", "reveal_go", "reveal_csharp", "reveal_java",
    ],
    # The content type (docs/autofill-plan.md): clicks only, pooled.
    [
     "autofill_rust", "autofill_python", "autofill_js", "autofill_go", "autofill_csharp",
     "autofill_java",
    ],
    # The background scene, pooled between drains: its worker parks
    # until a click releases it, so a binding that ran the work ON the
    # app thread deadlocks and TIMES OUT — the deadlock IS the gate
    # (docs/background-work-plan.md §5).
    [
     "background_rust", "background_python", "background_js", "background_go",
     "background_csharp", "background_java",
    ],
    # split/panes/adaptive/listdetail: each family drives resize_window
    # (the real size-class transition), drained between families.
    [
     "split_rust", "split_python", "split_js", "split_go", "split_csharp", "split_java",
    ],
    [
     "panes_rust", "panes_python", "panes_js", "panes_go", "panes_csharp", "panes_java",
    ],
    [
     "adaptive_rust", "adaptive_python", "adaptive_js", "adaptive_go", "adaptive_csharp", "adaptive_java",
    ],
    [
     "listdetail_rust", "listdetail_python", "listdetail_js", "listdetail_go",
     "listdetail_csharp", "listdetail_java",
    ],
    # undo_rust ALONE, the menus reason exactly: its `type` verb puts
    # REAL KEYSTROKES on the system input queue and foregrounds the
    # guest to do it (check-steps' menu_serial pins the barrier).
    [
     "undo_rust",
    ],
    # The menus and commands families, each leg ALONE between drains:
    # WinUI shortcut injection is OS-global (docs/traps.md) — the
    # harness foregrounds the guest and puts the real chord on the
    # system input queue, so a concurrent leg's SetForegroundWindow
    # would steal it. check-steps pins the drain/run/drain barrier.
    [
     "menus_rust",
    ],
    [
     "menus_python",
    ],
    [
     "menus_js",
    ],
    [
     "menus_go",
    ],
    [
     "menus_csharp",
    ],
    [
     "menus_java",
    ],
    [
     "commands_rust",
    ],
    [
     "commands_python",
    ],
    [
     "commands_js",
    ],
    [
     "commands_go",
    ],
    [
     "commands_csharp",
    ],
    [
     "commands_java",
    ],
    # The clipboard family, one drain each (docs/clipboard-plan.md §0d):
    # one system clipboard per session — legs writing it concurrently
    # are processes assigning one variable. NOT the menus reason:
    # menu_activate drives the real invoke pipeline, no chord injected.
    [
     "clipboard_rust",
    ],
    [
     "clipboard_python",
    ],
    [
     "clipboard_js",
    ],
    [
     "clipboard_go",
    ],
    [
     "clipboard_csharp",
    ],
    [
     "clipboard_java",
    ],
]


# LEGS THAT RUN ONE AT A TIME AMONG THEMSELVES AND POOL WITH THE REST OF THEIR
# BLOCK: group -> the scenes in it. The camera group (docs/capture-plan.md §7):
# the arm opens its devices ExclusiveControl, so two guests on one virtual
# camera would answer each other in_use, and nothing else in the lane opens
# them. The runner keeps the lane's devices up around every block holding one.
SERIAL_GROUPS = {"camera": ("capture", "capture_denied")}


def serial_group(leg):
    scene = scene_lang(leg)[0]
    return next((g for g, scenes in SERIAL_GROUPS.items() if scene in scenes), None)


def legs():
    """Every leg, in submission order."""
    return [leg for block in ORDER for leg in block]


def scene_lang(leg):
    """(scene, language) for a leg name; milestone2's five are bare, and a
    packaged leg's scene is the scene it runs (docs/packaging-plan.md P3 —
    the package is a runtime situation, not another scene)."""
    if leg in MILESTONE2_LEGS:
        return "milestone2", leg
    if leg in PACKAGED_LEGS:
        return PACKAGED_LEGS[leg], "rust"
    scene, _, lang = leg.rpartition("_")
    return scene, lang


def launcher(leg):
    """The checked-in guest launcher a leg runs (tools/guest/)."""
    return f"run_{leg}.cmd"


# A scene that selects a SCRIPT over another scene's guest (the mac lane's
# GUEST_STEM one platform over): the launcher runs the guest's own file.
GUEST_STEM = {"listdetail": "split", "formatde": "format", "formatar": "format",
              "taskspersist": "tasks", "links": "tasks", "tasksrtl": "tasks",
              "tasksbig": "tasks", "formatbig": "format", "clock24": "format",
              "scrollrtl": "scroll", "numberfieldde": "numberfield", "numberfieldar": "numberfield",
              "rangertl": "range",
              "media_formats": "media", "media_delivery": "media", "media_session": "media",
              "media_tracks": "media", "media_feed": "media", "media_picked": "media",
              "media_timeout": "media", "media_reader": "media", "capture_denied": "capture"}

# THE MEDIA SUITE'S SERVER (docs/media-plan.md §7a): the VM reaches the host
# over UTM's bridge, so the runner binds it there, on this lane's own port,
# and every media launcher names that URL (tools/deploy-win.py refuses one
# that names another).
MEDIA_HOST = "192.168.64.1"


def media_leg(leg):
    return scene_lang(leg)[0].startswith("media_")


# The Store packages that carry the decoders and the Ogg source the lane
# table assumes (docs/media-plan.md §7a, measured with and without): the
# runner refuses a VM that lacks one, naming it, since without them the
# video items play their audio alone and silently.
CODEC_EXTENSIONS = ("Microsoft.HEVCVideoExtension", "Microsoft.AV1VideoExtension",
                    "Microsoft.VP9VideoExtensions", "Microsoft.WebMediaExtensions")


def capture_leg(leg):
    return scene_lang(leg)[0] in ("capture", "capture_denied")


# THE CAPTURE LEGS' DEVICES (docs/HACKING.md, the Windows capture install):
# the one-time install's state check, and the helper the runner starts in
# the console session around the capture legs (tools/winvcam).
CAPTURE_INSTALL_SCRIPT = "capture-install.ps1"
CAPTURE_LANE_SCRIPT = "capture-lane.cmd"
CAPTURE_LANE_EXE = "kaya-capture-lane.exe"
CAPTURE_DLL = "kaya_winvcam.dll"


# The one screen every leg's geometry assumes (docs/traps.md, the UTM entry).
SCREEN = (1280, 800)


def screens_refusal(warmup):
    """None when the warm-up's `deskwarm.screen=` lines name exactly one
    SCREEN; otherwise the sentence the lane refuses with."""
    read = re.findall(r"^deskwarm\.screen=(\S+) primary=(\S+) (\d+)x(\d+)\s*$", warmup, re.M)
    if len(read) == 1 and (int(read[0][2]), int(read[0][3])) == SCREEN:
        return None
    said = "; ".join(f"{n} primary={p} {w}x{h}" for n, p, w, h in read) or "no screen at all"
    return (f"the interactive session has {len(read)} screen(s), {said}, where every leg's geometry "
            f"assumes one {SCREEN[0]}x{SCREEN[1]} screen. Run `DisplaySwitch.exe /internal` as an /it "
            f"scheduled task in that session (docs/traps.md, the UTM entry), or set the display in "
            f"UTM, then re-run.")


def guest_stem(scene):
    return GUEST_STEM.get(scene, scene)


def alone(leg):
    """True when the leg runs in a block of its own — between drains."""
    return any(block == [leg] for block in ORDER)


def wired_scenes():
    """The scenes some leg runs — the gates' census surface."""
    return {scene_lang(leg)[0] for leg in legs()}
