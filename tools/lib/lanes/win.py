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

# THE scene list: every mechanical per-scene surface derives from it
# (cross-build examples, exe/python shipping, taskkill). Adding a
# scene here is the ONE registration; ORDER stays explicit because
# it encodes per-language coverage decisions.
SCENES = [
    "background", "stall", "milestone2", "entry", "gallery", "todos",
    "reorder", "feed", "grow", "layout", "align", "window", "panels",
    "confirm", "nav", "split", "panes", "table", "scroll",
    "progress", "select", "radio", "grid", "textarea", "sections",
    "menus", "commands", "a11y", "a11yrows", "filedialog",
    "clipboard", "undo", "dirty", "ranges", "save", "styling",
    "typeface", "toolbar", "identity", "assets", "adaptive", "dnd", "pickers",
]

# Depth-slice scenes: a rust example + steps exist, the language
# sweep has not landed. Built, shipped and run RUST-ONLY — the
# deploy-win twin of validate-mac's DEPTH_SCENES. The gates read
# THIS default; the runner calls depth_scenes(), which honours the
# KAYA_WIN_DEPTH_SCENES override the lane uses for one-off slices.
DEPTH_SCENES = ["windowed", "canvas", "sizepolicy", "sliders"]


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
     "sliders_rust",
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
    """(scene, language) for a leg name; milestone2's five are bare."""
    if leg in MILESTONE2_LEGS:
        return "milestone2", leg
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

