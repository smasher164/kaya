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
    "milestone2", "stall", "entry", "search", "secure", "reveal", "segmented", "expander", "autofill", "submit", "scrollto", "fullscreen", "gallery",
    "todos", "reorder", "feed", "grow", "align", "layout",
    "confirm", "nav", "listdetail:split", "scroll", "progress",
    "select", "radio", "grid", "textarea", "sections",
    "menus", "commands", "a11y", "a11yrows", "clipboard",
    "background", "undo", "ranges", "dirty", "filedialog",
    "save", "styling", "toolbar", "identity", "assets",
    "table", "canvas", "sizepolicy", "dnd", "pickers", "sliders",
    "tooltips", "sheet",
    # The formatter door and the catalog under three locales
    # (docs/compliance-plan.md §6): one app, three scripts (SCENE_LOCALE).
    "format", "formatde:format", "formatar:format",
    "numberfield", "numberfieldde:numberfield", "timecode",
    "colorpicker",
    # The range and the rotated fader, and under ar-EG (docs/range-plan.md §4).
    "range", "rangertl:range",
    # The media suite, one guest (docs/media-plan.md §7a).
    "media_formats:media", "media_delivery:media", "media_session:media",
    "media_tracks:media", "media_feed:media",
    # The reader and the canvas's images (docs/media-plan.md §8).
    "media_reader:media",
    # The capture on kaya's in-process synthetic devices (docs/capture-plan.md §7).
    "capture", "capture_denied:capture",
    "toast",
    "safearea",
    # Network images (docs/network-images-plan.md §6).
    "netimage", "netimage_http",
    # The skin (docs/styling-pass-plan.md §5).
    "grounds", "shapes", "cards", "tracks", "dock",
]

# The go suite: the swift roster entry for entry minus the two
# rust-only canvas scenes, plus `editor` off-list below — a Go app with
# no swift guest to mirror (docs/editor-plan.md).
GO_SCENES = [
    "milestone2", "stall", "entry", "search", "secure", "reveal", "segmented", "expander", "autofill", "submit", "scrollto", "fullscreen", "gallery",
    "todos", "reorder", "feed", "grow", "align", "layout",
    "confirm", "nav", "listdetail", "scroll", "progress",
    "select", "radio", "grid", "textarea", "sections",
    "menus", "commands", "a11y", "a11yrows", "clipboard",
    "background", "undo", "ranges", "dirty", "filedialog",
    "save", "styling", "toolbar", "identity", "assets",
    "table", "dnd", "pickers", "sliders", "tooltips", "sheet",
    "format", "formatde", "formatar",
    "numberfield", "numberfieldde", "timecode",
    "colorpicker",
    "range", "rangertl",
    "media_formats", "media_delivery", "media_session", "media_tracks",
    "media_feed", "media_reader",
    "capture", "capture_denied",
    "toast",
    "safearea",
    "netimage", "netimage_http",
    "grounds", "shapes", "cards", "tracks", "dock",
]

# CPython embedded in ONE bundle carrying every python scene
# (docs/python-mobile-plan.md).
PYTHON_SCENES = ["portfolio", "varied", "music_home", "music_playlist", "music_header",
                 "music_dock", "music_artist", "music_search"]
# A scene whose guest file is another's: staged under the scene's name, the
# one the host's main.py runs (tools/pyhost-main.py).
PYTHON_GUEST = {"music_home": "music", "music_playlist": "music", "music_header": "music",
                "music_dock": "music", "music_artist": "music", "music_search": "music"}
# Python scenes that also run under KAYA_APPEARANCE=dark, as `<scene>dark-python`
# (docs/media-player-plan.md M5).
PYTHON_DARK = ("music_header", "music_artist", "music_dock")
# The media player demo on a phone (docs/media-player-plan.md M6): no pointer,
# and the library is the Library section rather than the sidebar.
MUSIC_PLAYLIST_PHONE_TAIL = ('expect_columns column@tracks "#|Title|Time"; expect_rows column@tracks "4,Seven Chimes/Pierce Murphy,0:20|7,Athens/Pierce Murphy,0:20"; back; expect_selected column@card_201715 on; click column@card_581719; expect_rows column@tracks "1,A Serpent I Did Hear/Pierce Murphy,0:20|2,Persimmon/Pierce Murphy,0:20"; back; select_section 2; click row@saved[201715]; expect_rows column@tracks "4,Seven Chimes/Pierce Murphy,0:20|7,Athens/Pierce Murphy,0:20"; back; expect_selected row@saved[201715] on')
# The dock's phone half: a tap opens the full player, which holds the rest.
MUSIC_DOCK_PHONE_TAIL = ('expect_dock_line none; click row@dock_open; expect_sheets 1; expect_sheet "Now Playing"; expect_inset column@full_player 16; expect_image_phase image@full_art shown; expect label@full_title "In Tune"; click button@full_play_pause; expect_ax button@full_play_pause "button/Play"; set_value slider@progress 0.5; expect_value slider@progress "0.5"; expect label@elapsed "0:10"; expect label@remaining "-0:10"; click button@full_play_pause; expect_ax button@full_play_pause "button/Pause"; hold slider@progress at 0; settle 1000; expect_value slider@progress "0"; click button@full_play_pause; expect_ax button@full_play_pause "button/Play"; release slider@progress; expect_value slider@progress "0"; expect label@elapsed "0:00"; expect label@remaining "-0:20"; expect_ax checkbox@shuffle "toggle/Shuffle"; expect_checked checkbox@shuffle off; toggle checkbox@shuffle on; expect_checked checkbox@shuffle on; toggle checkbox@shuffle off; expect_checked checkbox@shuffle off; expect_ax checkbox@repeat "toggle/Repeat off"; expect_checked checkbox@repeat off; expect_symbol checkbox@repeat "repeat"; toggle checkbox@repeat on; expect_ax checkbox@repeat "toggle/Repeat all"; expect_checked checkbox@repeat on; expect_symbol checkbox@repeat "repeat"; toggle checkbox@repeat off; expect_ax checkbox@repeat "toggle/Repeat one"; expect_checked checkbox@repeat on; expect_symbol checkbox@repeat "repeat_one"; toggle checkbox@repeat off; expect_ax checkbox@repeat "toggle/Repeat off"; expect_checked checkbox@repeat off; expect_symbol checkbox@repeat "repeat"; expect_ax checkbox@like "toggle/Like"; toggle checkbox@like on; expect_checked checkbox@like on; click button@full_next; expect label@full_title "Owl Time"; expect_checked checkbox@like off; click button@previous; expect label@full_title "In Tune"; expect_checked checkbox@like on; click button@full_next; expect label@full_title "Owl Time"; expect_ax button@full_play_pause "button/Pause"; click button@full_play_pause; expect_ax button@full_play_pause "button/Play"; set_value slider@progress 0.5; expect label@elapsed "0:10"; click button@previous; expect label@full_title "Owl Time"; expect label@elapsed "0:00"; click button@previous; expect label@full_title "In Tune"; dismiss_sheet; expect_sheets 0; expect label@dock_title "In Tune"')
MUSIC_HEADER_PHONE_TAIL = ('expect_ground_reach column@album_header top; expect_system_bars "legible/none"; back; expect_system_bars "legible/none"; expect_title "Music"; click column@card_581719; expect_checked checkbox@favorite off; back; click column@card_201715; expect_checked checkbox@favorite on; toggle checkbox@favorite off; expect_checked checkbox@favorite off; expect_pref music.favorites ""')
# The artist page's phone half: three columns, then back to the album and Home.
# An image ground at a screen's top runs under the status bar (docs/media-player-plan.md M15).
GROUNDS_PHONE_TAIL = 'expect_ground_reach column@hero top; expect_system_bars "legible/none"'
MUSIC_ARTIST_PHONE_TAIL = ('expect_ground_reach column@artist_header none; expect_system_bars "legible/none"; expect_columns column@top_tracks "#|Title"; expect_rows column@top_tracks "1,In Tune (J. Glaze Remix)/Kellee Maize|2,In Tune/Kellee Maize|3,Owl Time/Kellee Maize|4,Mad Humans (J. Glaze Remix)/Kellee Maize"; back; expect_ax button@album_artist "button/Kellee Maize"; back; expect_title "Music"')
# Search is the phone's second section; the like is the full player's, read
# once the sheet is down (docs/toast-plan.md T8: a toast sits below a modal).
MUSIC_SEARCH_PHONE_TAIL = ('select_section 1; expect_placeholder search@find "Artists, albums or tracks"; expect_ax search@find "field/Search"; expect label@search_status "Search Jamendo for artists, albums and tracks."; expect_segments segmented@chips "[All]|Albums|Artists|Tracks"; click search@find; expect_focused search@find; type "David"; expect label@search_status "2 albums · 1 artist · 3 tracks"; expect_image_phase image@found_album_art[149020] shown; expect_shape image@found_album_art[149020] rounded; expect label@found_album_name[149020] "David Amber and Friends, Vol. 1"; expect label@found_artist_name[476280] "David Amber"; expect label@found_track_name[1243462] "Gnarly (feat. Devyn Rush)"; expect label@found_track_time[1243462] "0:20"; expect_image_phase image@found_track_art[1243462] shown; expect_no_clipping; choose segmented@chips 1; expect_segments segmented@chips "All|[Albums]|Artists|Tracks"; expect label@search_status "2 albums"; expect_no_target column@found_artist[476280]; expect_no_target row@found_track[1243462]; choose segmented@chips 2; expect label@search_status "1 artist"; expect_image_phase image@found_artist_art[476280] shown; expect_shape image@found_artist_art[476280] circle; expect_no_target column@found_album[149020]; choose segmented@chips 3; expect label@search_status "3 tracks"; expect_no_target column@found_artist[476280]; click row@found_track[1243462]; expect label@dock_title "Gnarly (feat. Devyn Rush)"; expect_tint label@found_track_name[1243462] accent; click row@dock_open; expect_sheets 1; toggle checkbox@like on; dismiss_sheet; expect_sheets 0; expect_toast "Added to Liked Songs|Undo"; toast_action; expect_no_toast; click row@dock_open; expect_sheets 1; expect_checked checkbox@like off; toggle checkbox@like on; dismiss_sheet; expect_sheets 0; expect_toast "Added to Liked Songs|Undo"; choose segmented@chips 0; expect label@search_status "2 albums · 1 artist · 3 tracks"; clear_search search@find; expect search@find ""; expect label@search_status "Search Jamendo for artists, albums and tracks."; expect_segments segmented@chips "[All]|Albums|Artists|Tracks"; expect_no_target column@found_album[149020]; expect_no_target row@found_track[1243462]; click search@find; expect_focused search@find; type "zzqxv"; expect label@search_status "No results for “zzqxv”."; expect_no_target column@found_artist[476280]; set_text search@find "David"; expect label@search_status "2 albums · 1 artist · 3 tracks"; expect label@found_artist_name[476280] "David Amber"; click column@found_artist[476280]; expect_ax label@artist_name "heading/David Amber"; back; expect label@search_status "2 albums · 1 artist · 3 tracks"; select_section 0; expect_title "Music"')
MUSIC_PHONE_TAIL = ('expect_title "Music"; click column@card_201715; back; expect_selected column@card_201715 on; expect_selected column@card_581719 off; expect_fill column@card_201715 selected; click column@card_139585; back; expect_selected column@card_139585 on; expect_selected column@card_201715 off; select_section 2; expect_selected row@saved[139585] on; expect_selected row@saved[201715] off; expect_image_phase image@saved_art[139585] shown; expect_shape image@saved_art[139585] rounded; click row@saved[201715]; back; expect_selected row@saved[201715] on; select_section 0; expect_selected column@card_201715 on; expect_selected column@card_139585 off')

# The rust-swiftui suite: one cargo example per scene, milestone2 first
# (its leg is the bare `rust-swiftui`). The EXAMPLE a scene builds is
# its own name except listdetail, which drives the split example — the
# same script-not-app rule as the swift roster's `listdetail:split`.
RUST_SCENES = [
    "milestone2",
    "entry", "search", "todos", "gallery", "reorder", "feed",
    "grow", "align", "layout", "stall", "confirm",
    "nav", "scroll", "filedialog", "save", "clipboard",
    "a11y", "a11yrows", "styling", "ranges", "progress",
    "menus", "toolbar", "identity", "assets", "listdetail",
    "table", "windowed", "adaptive", "commands", "undo",
    "dirty", "dnd", "pickers", "sliders", "tooltips", "sheet",
    # The formatter door and the catalog under three locales
    # (docs/compliance-plan.md §6); SCENE_LOCALE carries the knob.
    "format", "formatde", "formatar",
    # The task manager in Arabic, and at twice the text size, and the
    # format guest at twice it (docs/compliance-plan.md §6; SCENE_TEXT_SCALE).
    "tasksrtl", "tasksbig", "formatbig",
    # The scroll guest's sideways strip in Arabic (docs/hscroll-plan.md §4).
    "scrollrtl",
    # The format guest under the 24-hour clock (SCENE_CLOCK).
    "clock24",
    # A row wider than its window (docs/flex-shrink-plan.md §6).
    "flexshrink", "scrollto",
    # Immersive mode (docs/fullscreen-plan.md §3); MODS cuts the user half.
    "fullscreen",
    # The common list-row shapes (docs/deferred.md).
    "listrow",
    # The platform tints on a filled container (docs/tints-plan.md).
    "tints",
    # The submit gesture on the three text kinds (docs/submit-plan.md §5).
    "submit",
    # The secure field (docs/secure-entry-plan.md §5).
    "secure",
    # The reveal toggle (docs/reveal-plan.md §5).
    "reveal",
    # The segmented control (docs/segmented-plan.md §6).
    "segmented",
    # The expander (docs/expander-plan.md §5).
    "expander",
    # The toast (docs/toast-plan.md §6).
    "toast",
    # The content type (docs/autofill-plan.md §5).
    "autofill",
    # The notification conformance scene: the activation is a REAL tap on
    # SpringBoard's own shade, driven by the xcui driver's notify_tap
    # (docs/tasks-s3-plan.md N5).
    "notify",
    # The app's icon badge (docs/app-badge-plan.md), with a notification.
    "badge",
    # The emoji button (docs/emoji-picker-plan.md): iOS has no picker (R2),
    # so MODS drops the pick and what it would have written.
    "emoji",
    # The task manager: a RUST app by design (docs/tasks-plan.md §0).
    "tasks",
    # WHAT SURVIVES A RELAUNCH (docs/tasks-s4-plan.md §4): the same
    # example under taskspersist.steps, act two through the PLAIN door.
    "taskspersist",
    # APP LINKS (docs/app-links-plan.md L5): the same example again,
    # warm through UIApplication.open and cold through `simctl openurl`.
    "links",
    # RICH TEXT (docs/rich-text-plan.md §4): rust-only until the bindings'
    # sugar sweep lands, as `ranges` was.
    "richtext",
    # THE APP-OWNED UNDO (docs/rich-text-plan.md §14): rust-only for the
    # same reason, and the one scene that drives route App on this lane.
    "ownundo",
    # THE RICH LABEL (docs/rich-text-plan.md §15): rust-only for the same
    # reason; the runs are read-only, so this lane drives no keyboard.
    "richlabel",
    "notes",
    # THE RICH ROWS (docs/rich-text-plan.md §19): rust-only for richtext's
    # reason; the copy's act is the harness's format verb, no keyboard.
    "richrows",
    # The number field (docs/number-field-plan.md §4.2), and under de-DE.
    "numberfield", "numberfieldde", "timecode", "numberfieldar",
    # The colour picker (docs/color-picker-plan.md §4.2).
    "colorpicker",
    # The range and the rotated fader, and under ar-EG (docs/range-plan.md
    # §4.2, §4.3).
    "range", "rangertl",
    # The media suite (docs/media-plan.md §7a), one guest; the lane's
    # local server is up while any of these is queued.
    "media_formats", "media_delivery", "media_session", "media_tracks",
    "media_feed", "media_reader",
    # A picked clip played (docs/media-plan.md §2): rust-only.
    "media_picked",
    # The bound (docs/media-plan.md §7c): rust-only.
    "media_timeout",
    # The capture (docs/capture-plan.md §7): kaya's in-process synthetic
    # devices, the simulator having no camera and its microphone being the
    # host's.
    "capture", "capture_denied",
    # The safe area (docs/safe-area-plan.md §6): `bleed`, and the task manager
    # and the content-type form with the keyboard up.
    "safearea", "taskskeyboard", "autofillkeyboard",
    # Network images (docs/network-images-plan.md §6).
    "netimage", "netimage_http",
    # The skin (docs/styling-pass-plan.md §5).
    "grounds", "shapes", "cards", "tracks", "dock",
]

# The iPad legs, queued right after their phone sibling: the phone pool is
# ALWAYS compact, so these are the only observations of the regular-width
# lowering. The value is the leg's EXTRA step; table's is empty by
# decision 5's design — the tiers present identical bytes, and the leg
# buys that the native path executes at all.
# Scenes that also run under KAYA_APPEARANCE=dark, as `<scene>dark-swiftui`:
# the tints resolved in the dark appearance (docs/tints-plan.md §4).
DARK_EXTRAS = ("tints", "grounds")
# Scenes that also run in a bundle pinned to landscape, as
# `<scene>land-<suite>` (docs/safe-area-plan.md §5.4): the keyboard leaves
# least room there. The reading appended proves the interface turned: a
# notched phone's top inset goes and its home indicator stays.
LANDSCAPE_EXTRAS = ("taskskeyboard", "autofillkeyboard")
LANDSCAPE_READING = 'expect_insets "none/bar"'

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
UNWIRED_SCENES = []

# The fullscreen scene's app-only way back after the cut, the same steps as
# tools/lib/lanes/android.py's FULLSCREEN_APP_TAIL: no user change arrives.
FULLSCREEN_APP_TAIL = ('click button#0; expect label#0 "asked for a window"; '
                       'expect_fullscreen off; click button#1; '
                       'expect label#2 "pings 2"; '
                       'expect label#1 "no change from the user"')

# A PHONE'S NUMBER FIELD HAS NO STEPPING DOOR (docs/number-field-plan.md
# §5): the scene steps last, so the cut takes the steps alone.
NUMBER_FIELD_CUT = {"cut": "nudge", "keep": "expect_focused expect_ax"}

# THE INSETS ARE THE DEVICE'S (docs/safe-area-plan.md A8, A9): the pool
# phone's status bar over its notch and its home indicator, then immersive
# mode, where the notch alone is left at the top.
SAFEAREA_EXTRA = ('expect_insets "bar/bar"; click button@full; expect label@caption "fullscreen"; '
                  'expect_fullscreen on; expect_insets "cutout/bar"; expect_safe image@picture bleeds; '
                  'expect_safe canvas@ground bleeds; expect_safe label@caption')

# Per-leg modifiers, keyed (suite, scene). `cut` names the verb this host
# cannot express (everything from it on is dropped, printed); `drop` names
# ONE step by verb and target; `keep` names the assertions neither may
# take with it; `extra` appends steps only true on this device.
MODS = {
    # A phone has no pointer (docs/styling-pass-plan.md §5): the cards leg
    # ends at its first hover.
    ("rust-swiftui", "cards"): {"cut": "hover", "keep": "expect_selected expect_ax"},
    ("swift", "cards"): {"cut": "hover", "keep": "expect_selected expect_ax"},
    ("go", "cards"): {"cut": "hover", "keep": "expect_selected expect_ax"},
    # The macOS native table's own keyboard (docs/styling-pass-plan.md Y4,
    # AMENDED 2026-10-17): a phone's table has no selection of its own to move.
    ("rust-swiftui", "tracks"): {"cut": "press down", "keep": "expect_tint expect_rows"},
    ("swift", "tracks"): {"cut": "press down", "keep": "expect_tint expect_rows"},
    ("go", "tracks"): {"cut": "press down", "keep": "expect_tint expect_rows"},
    # The declared NAME is read off an auxiliary window this host does
    # not have; the icon reads survive (docs/app-identity-plan.md
    # ruling 3).
    ("swift", "identity"): {"drop": ("expect_title", "window#1"),
                            "keep": "expect_app_icon"},
    ("go", "identity"): {"drop": ("expect_title", "window#1"),
                         "keep": "expect_app_icon"},
    ("rust-swiftui", "identity"): {"drop": ("expect_title", "window#1"),
                                   "keep": "expect_app_icon"},
    # THE PHONE'S OWN STEP (docs/compliance-plan.md §2.1): the knob picks the
    # content size category nearest 2.0, accessibilityLarge at 33pt over
    # the 17pt body, and the read-back is that ratio — 1.94, never the
    # knob's round number. The clipping read is what the leg exists for.
    ("rust-swiftui", "formatbig"): {"drop": ("expect_text_scale", "2"),
                                    "keep": "expect_no_clipping",
                                    "extra": "expect_text_scale 1.94"},
    # THE PLATFORM'S RETURN ON A SINGLE-LINE FIELD ENDS EDITING
    # (docs/submit-plan.md S3, §7.1): SwiftUI's TextField resigns on
    # Return, so the entry publishes and the keyboard goes with the focus;
    # the submitting textarea's Send keeps its focus and that step stays.
    ("rust-swiftui", "emoji"): {"drop": (("pick_emoji", '"😀"'),
                                         ("expect", "entry@message"),
                                         ("expect", "label@echo")),
                                "keep": "expect_focused"},
    # iOS publishes an announcement to VoiceOver alone, so no listener here
    # can hear it (docs/toast-plan.md T13's carve-out).
    ("rust-swiftui", "toast"): {"drop": ("expect_toast_announced", '"Saved|"'),
                                "keep": "expect_toast"},
    ("swift", "toast"): {"drop": ("expect_toast_announced", '"Saved|"'),
                         "keep": "expect_toast"},
    ("go", "toast"): {"drop": ("expect_toast_announced", '"Saved|"'),
                      "keep": "expect_toast"},
    ("rust-swiftui", "submit"): {"drop": ("expect_focused", "entry#0"),
                                 "keep": "expect"},
    ("swift", "submit"): {"drop": ("expect_focused", "entry#0"),
                          "keep": "expect"},
    ("go", "submit"): {"drop": ("expect_focused", "entry#0"),
                       "keep": "expect"},
    # The sections tail opens an aux window rejected by capability.
    ("swift", "sections"): {"cut": "expect_windows",
                            "keep": "expect_section expect_section_symbol"},
    ("go", "sections"): {"cut": "expect_windows",
                         "keep": "expect_section expect_section_symbol"},
    # dirty's last six steps hang off a chrome close; iOS's close
    # grammar is macOS-only (docs/dirty-plan.md D4).
    ("swift", "dirty"): {"cut": "close_window", "keep": "expect_dirty"},
    ("go", "dirty"): {"cut": "close_window", "keep": "expect_dirty"},
    # THE DETENT IS THE PHONES' TO ANSWER (docs/sheet-plan.md §4): the
    # shared script asserts the desktops' `none`; this lane drops that
    # step and reopens the medium sheet at the end to read the platform's
    # own detent back, then cancels it through the swipe.
    ("swift", "sheet"): {
        "drop": ("expect_sheet_detent", "none"), "keep": "expect_sheet",
        "extra": "click button#0; expect_sheets 1; expect_sheet_detent medium; "
                 "dismiss_sheet; expect_sheets 0"},
    ("go", "sheet"): {
        "drop": ("expect_sheet_detent", "none"), "keep": "expect_sheet",
        "extra": "click button#0; expect_sheets 1; expect_sheet_detent medium; "
                 "dismiss_sheet; expect_sheets 0"},
    ("rust-swiftui", "sheet"): {
        "drop": ("expect_sheet_detent", "none"), "keep": "expect_sheet",
        "extra": "click button#0; expect_sheets 1; expect_sheet_detent medium; "
                 "dismiss_sheet; expect_sheets 0"},
    ("rust-swiftui", "dirty"): {"cut": "close_window",
                                "keep": "expect_dirty"},
    # The editor opens both pickers and ends past a chrome close
    # (docs/editor-plan.md).
    ("go", "editor"): {"cut": "close_window", "keep": "expect_dirty"},
    # The portfolio's fold block sits at the scene's END
    # (docs/adaptive-layout-plan.md D7): the cut takes the
    # resize-driven round trip a phone cannot command, the extra
    # asserts the always-stacked truth this host CAN express.
    ("python", "music_home"): {"cut": "hover", "keep": "expect_ax expect_grid_columns",
                               "extra": MUSIC_PHONE_TAIL},
    # The playlist's sidebar tail is the desktops'; a phone comes back with
    # `back` and opens a library album in the Library section.
    ("python", "music_playlist"): {"cut": "expect_title", "keep": "expect_tint",
                                   "extra": MUSIC_PLAYLIST_PHONE_TAIL},
    # The header's sidebar tail is the desktops'; a phone goes back to Home.
    ("python", "music_header"): {"cut": "click row@go_home", "keep": "expect_ground expect_shape",
                                 "extra": MUSIC_HEADER_PHONE_TAIL},
    # The artist page's desktop tail opens an album from the shelf and goes
    # Home through the sidebar; a phone reads its columns and goes back.
    ("python", "music_artist"): {"cut": "expect_title",
                                 "keep": "expect_ground expect_fill expect_shape expect_tint",
                                 "extra": MUSIC_ARTIST_PHONE_TAIL},
    ("python", "music_search"): {"cut": "click row@go_search",
                                 "keep": "expect_image_phase=image@art_116452",
                                 "extra": MUSIC_SEARCH_PHONE_TAIL},
    ("python", "music_dock"): {"cut": "click button@play_pause",
                               "keep": "session_send expect_now_playing expect_dock",
                               "extra": MUSIC_DOCK_PHONE_TAIL},
    ("python", "portfolio"): {
        "extra": "expect_folded column@summary column@ledger",
        "cut": "resize_window",
        "keep": "expect_window=column@ledger"},
    # The adaptive breakpoint's phone side: an always-narrow window
    # applies at its first report, no resize ever
    # (docs/adaptive-layout-plan.md §2).
    # The two window-geometry steps of the persistence scene: this host
    # commands no window size, and the phone has no frame to remember.
    # A DROP, NOT A CUT — a tail cut at `resize_window` would take
    # `relaunch launch` and the whole second act with it, which is the
    # thing the leg exists for (docs/tasks-s4-plan.md §4).
    ("rust-swiftui", "taskspersist"): {
        "drop": (("resize_window", "900x620"),
                 ("expect_window_size", "900x620")),
        "keep": "expect_pref expect_no_pref expect_appearance"},
    # A PHONE HAS NO USER DOOR OUT OF FULLSCREEN (docs/fullscreen-plan.md §2):
    # the cut takes the user half, and the extra runs the app's way back.
    ("swift", "fullscreen"): {"cut": "user_fullscreen", "keep": "expect_fullscreen",
                              "extra": FULLSCREEN_APP_TAIL},
    ("go", "fullscreen"): {"cut": "user_fullscreen", "keep": "expect_fullscreen",
                           "extra": FULLSCREEN_APP_TAIL},
    ("rust-swiftui", "fullscreen"): {"cut": "user_fullscreen", "keep": "expect_fullscreen",
                                     "extra": FULLSCREEN_APP_TAIL},
    # THE EYE'S KEYBOARD REACH is Full Keyboard Access's, which no lane turns
    # on; the mac lane cuts the same block (docs/reveal-plan.md V10).
    ("swift", "reveal"): {"cut": "press tab", "keep": "expect_unmasked expect_masked"},
    ("go", "reveal"): {"cut": "press tab", "keep": "expect_unmasked expect_masked"},
    ("rust-swiftui", "reveal"): {"cut": "press tab", "keep": "expect_unmasked expect_masked"},
    ("swift", "timecode"): {"cut": "nudge", "keep": "expect_value"},
    ("go", "timecode"): {"cut": "nudge", "keep": "expect_value"},
    ("rust-swiftui", "timecode"): {"cut": "nudge", "keep": "expect_value"},
    ("swift", "numberfield"): NUMBER_FIELD_CUT,
    ("swift", "numberfieldde"): NUMBER_FIELD_CUT,
    ("go", "numberfield"): NUMBER_FIELD_CUT,
    ("go", "numberfieldde"): NUMBER_FIELD_CUT,
    ("rust-swiftui", "numberfield"): NUMBER_FIELD_CUT,
    ("rust-swiftui", "numberfieldde"): NUMBER_FIELD_CUT,
    ("rust-swiftui", "safearea"): {"extra": SAFEAREA_EXTRA},
    ("swift", "grounds"): {"extra": GROUNDS_PHONE_TAIL},
    ("go", "grounds"): {"extra": GROUNDS_PHONE_TAIL},
    ("rust-swiftui", "grounds"): {"extra": GROUNDS_PHONE_TAIL},
    ("swift", "safearea"): {"extra": SAFEAREA_EXTRA},
    ("go", "safearea"): {"extra": SAFEAREA_EXTRA},
    ("rust-swiftui", "adaptive"): {
        "extra": 'expect_axis row@narrow "vertical"; expect_grid_columns grid@sheet 1; '
                 'expect_grid_columns grid@fit 1',
        "cut": "resize_window",
        "keep": "expect_axis=row@dash expect_axis=column@steady"},
}

SUITES = ("swift", "go", "python", "rust-swiftui")

# A10 (docs/safe-area-plan.md §7): the pool raises the software keyboard while
# this lane runs, through this preference, written before the first leg and
# put back after the last, both read back.
SOFTWARE_KEYBOARD_PREF = ("com.apple.keyboard.preferences", "AutomaticMinimizationEnabled")

# THE SECOND ACT'S DOOR ON THIS LANE (docs/tasks-s9-plan.md R6a). The
# simulator's shade activates no notification by any route
# (docs/traps.md), so the lane takes the mac arm's carve-out: the same
# bundle launched again with KAYA_LAUNCH_NOTIFICATION, which the
# interpreter delivers through the centre delegate's own funnel.
# tools/check-steps.py reads this against the scenes carrying `relaunch`.
RELAUNCH_DOOR = {"tasks": "launch-notification",
                 # THE PLAIN DOOR (docs/tasks-s4-plan.md P5): `simctl
                 # launch` of the same bundle, nothing pending and nothing
                 # added to the environment — the marker in the app's own
                 # Documents is the second process's only signal.
                 "taskspersist": "launch",
                 # THE LINK DOOR (docs/app-links-plan.md L5): `simctl
                 # openurl`, which raises a SpringBoard confirmation the
                 # first time on a device and delivers nothing until it is
                 # answered (docs/traps.md) — run-sim answers it through
                 # the lane's own driver.
                 "links": "link"}
# Which notification the door hands back: the scene's act one sets t1's
# reminder, and a task's key IS its notification id (R2).
RELAUNCH_NOTIFICATION = {"tasks": 1}

# THE LEGS THAT RUN AS THE ONLY INPUT-DRIVING LEG ON THE HOST (tools/lib/
# exclusive.py): the save sheet under a matrix (docs/deferred.md, the two
# save-swiftui WATCHes) and the picker leg whose bridge starved.
EXCLUSIVE = {"save-swift", "save-go", "save-swiftui", "filedialog-go"}


def swift_scene(entry):
    """(scene, guest source) for a swift roster entry."""
    scene, _, src = entry.partition(":")
    return scene, src or scene


# Scene -> the cargo example it builds, where the two differ: a scene
# selects a SCRIPT, never an app.
RUST_EXAMPLE = {"listdetail": "split", "taskspersist": "tasks",
                "links": "tasks", "formatde": "format", "formatar": "format",
                "tasksrtl": "tasks", "tasksbig": "tasks", "formatbig": "format",
                "clock24": "format", "scrollrtl": "scroll",
                "numberfieldde": "numberfield", "numberfieldar": "numberfield",
                "rangertl": "range",
                "media_formats": "media", "media_delivery": "media",
                "media_session": "media", "media_tracks": "media",
                "media_feed": "media", "media_picked": "media",
                "media_timeout": "media", "media_reader": "media",
                "capture_denied": "capture",
                "taskskeyboard": "tasks", "autofillkeyboard": "autofill"}

# The scenes whose guest declares a media session: their bundles carry
# UIBackgroundModes audio (docs/media-plan.md §5). The media guest is one
# app for the five scenes, so all five bundles carry it.
SESSION_SCENES = ("media_formats", "media_delivery", "media_session",
                  "media_tracks", "media_feed", "media_picked", "media_timeout",
                  "media_reader", "music_dock")

# The locale a scene runs under, the knob the leg carries
# (docs/compliance-plan.md §4); the reads ask the platform, never this.
SCENE_LOCALE = {"formatde": "de-DE", "formatar": "ar-EG", "tasksrtl": "ar-EG",
                "scrollrtl": "ar-EG", "numberfieldde": "de-DE", "numberfieldar": "ar-EG",
                "rangertl": "ar-EG"}

# The text-scale knob a scene carries (docs/compliance-plan.md §2.1): the
# window's content size category nearest the factor.
SCENE_TEXT_SCALE = {"tasksbig": "2", "formatbig": "2"}

# The clock a scene runs under (docs/compliance-plan.md §4): the core writes
# Apple's own key into the process's volatile argument domain from
# KAYA_CLOCK; a `simctl launch` argument was measured not reaching
# CoreFoundation in a guest that formats before its defaults exist.
SCENE_CLOCK = {"clock24": "24"}


def rust_example(scene):
    """The cargo example a rust-swiftui scene builds."""
    return RUST_EXAMPLE.get(scene, scene)


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
        out.append("chat-go")
        out.append("chatkeyboard-go")
        out.append("chatkeyboardland-go")
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
            if scene in LANDSCAPE_EXTRAS:
                out.append(f"{scene}land-swiftui")
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
    out.add("chat")
    out.add("chatkeyboard")
    out.add("chatkeyboardland")
    return out
