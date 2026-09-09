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

# THE scene list: every mechanical per-scene surface derives from it
# (cross-build examples, exe/python shipping, taskkill). Adding a
# scene here is the ONE registration; ORDER stays explicit because
# it encodes per-language coverage decisions.
SCENES = [
    "background", "stall", "milestone2", "entry", "gallery", "todos",
    "reorder", "feed", "grow", "layout", "align", "window", "panels",
    "confirm", "nav", "split", "panes", "table", "scroll",
    "progress", "select", "radio", "grid", "textarea", "search", "sections",
    "menus", "commands", "a11y", "a11yrows", "filedialog",
    "clipboard", "undo", "dirty", "ranges", "save", "styling",
    "typeface", "toolbar", "identity", "assets", "adaptive", "dnd", "pickers", "sliders", "tooltips",
]

# THE LEGS THAT RUN AS THE ONLY INPUT-DRIVING LEG ON THE HOST (tools/lib/
# exclusive.py): the drag family, already alone inside this lane for the
# OLE reasons above, so an exclusive-only run carries them and the everyday
# matrix can leave them (the maintainer, 2026-09-06: the drags are what
# make a matrix long).
EXCLUSIVE = {"dnd_rust", "dnd_python", "dnd_js", "dnd_go", "dnd_csharp", "dnd_java",
             "dndwitness_rust", "dndforeign_rust"}

# Depth-slice scenes: a rust example + steps exist, the language
# sweep has not landed. Built, shipped and run RUST-ONLY — the
# deploy-win twin of validate-mac's DEPTH_SCENES. The gates read
# THIS default; the runner calls depth_scenes(), which honours the
# KAYA_WIN_DEPTH_SCENES override the lane uses for one-off slices.
DEPTH_SCENES = ["windowed", "canvas", "sizepolicy", "tasks", "notify"]

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
RELAUNCH_DOOR = {"tasks": "com-activator"}
# The door script the runner drives (tools/guest/, shipped by the deploy).
RELAUNCH_DOOR_SCRIPT = "relaunch-com.ps1"
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
GO_ONLY_SCENES = ["editor"]
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
     # The sliders pool for the pickers' reason: `set_value` drives the
     # CONTROL's own property, no real mouse and no OS-global chrome. RUST
     # ALONE while the eight bindings' sugar is the parallel worktree
     # (docs/slider-plan.md §5) — hence the DEPTH_SCENES row, which ships
     # the exe and no .py or .ts; the other five legs join this line with
     # their guests.
     "sliders_rust", "sliders_python", "sliders_js", "sliders_go", "sliders_csharp", "sliders_java",
    "tooltips_rust", "tooltips_python", "tooltips_js", "tooltips_go", "tooltips_csharp", "tooltips_java",
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
     # The notification conformance scene (docs/tasks-s3-plan.md N5). POOLED:
     # the platform keys a notification by the AUMID `Register()` derives from
     # the EXE, so this leg's history is its own, and a toast banner neither
     # takes the foreground nor lands where a pooled window is tiled.
     "notify_rust",
     "canvas_rust",
     "canvasdark_rust",
     "sizepolicy_rust",
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
    # EACH search LEG ALONE, ranges' reason exactly: its `type` verb puts
    # REAL KEYSTROKES on the system input queue and foregrounds the guest to
    # do it, so a pooled neighbour taking the foreground mid-scene would eat
    # the query (docs/search-plan.md §5).
    [
     "search_rust",
    ],
    [
     "search_python",
    ],
    [
     "search_js",
    ],
    [
     "search_go",
    ],
    [
     "search_csharp",
    ],
    [
     "search_java",
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
    # save_rust: the filedialog rule — the save dialog is the same
    # OS-global `#32770` chrome, found the same way.
    [
     "save_rust",
    ],
    # editor_go, for BOTH serial reasons: open/save dialogs plus
    # OS-global `type` keystrokes (docs/editor-plan.md; Go alone by
    # design — an editor in Rust would be kaya testing itself).
    [
     "editor_go",
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


def alone(leg):
    """True when the leg runs in a block of its own — between drains."""
    return any(block == [leg] for block in ORDER)


def wired_scenes():
    """The scenes some leg runs — the gates' census surface."""
    return {scene_lang(leg)[0] for leg in legs()}

