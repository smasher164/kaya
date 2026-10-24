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

# THE LEGS THAT RUN AS THE ONLY LEG ON THE HOST (tools/lib/exclusive.py).
EXCLUSIVE = {
             # THE EMULATOR'S AUDIO INPUT BREAKS UNDER HOST LOAD: the guest
             # HAL's reads fail with EIO for the rest of the input's life,
             # with or without the injected tone, read as `samples silent`
             # (docs/traps.md; docs/probes/capture-2026-10-01/compose-measured.md
             # §4): no failed read in 8 quiet runs, most runs beside 14 spinning cores.
             "capture-compose", "capture-jvm", "capture-go"}

# ALONE IN THIS LANE, NOT ON THE HOST: the pool empties around each and the token
# is not taken. clock24-compose sets every phone's 24-hour setting
# (SCENE_SETTINGS). The drags and the shade legs were pooled on 2026-10-09
# (docs/measurements/android-ceiling-2026-10-09.md).
ALONE = {"clock24-compose"}

# THE QUIET TAIL (the maintainer's ruling of 2026-10-05; docs/traps.md, the
# emulator's audio input entry): the microphone legs run after every other lane
# and the gate sweep, with nothing else on the host. validate-all runs this
# lane with KAYA_QUIET=skip and then once more with KAYA_QUIET=only; a lane run
# by hand runs them in place.
QUIET = {"capture-compose", "capture-jvm", "capture-go"}

# A device setting a scene runs under, `settings put <namespace> <key>
# <value>` on every phone in the pool before the leg and deleted after
# (docs/compliance-plan.md §4; U10 measured `time_12_24 24` reaching the
# platform's text-format class and not ICU).
SCENE_SETTINGS = {"clock24": ("system", "time_12_24", "24")}

# The roster, per suite and in queue order. Leg names are the census
# surface every gate reads; the exceptions ride FLAGS below.
LEGS = {
    "compose": [
        "compose", "a11y-compose", "entry-compose",
        "gallery-compose", "todos-compose", "remount-compose",
        "remount-nav-compose", "reorder-compose", "table-compose",
        "windowed-compose", "canvas-compose", "canvasdark-compose",
        # A row wider than its window (docs/flex-shrink-plan.md §6).
        "flexshrink-compose",
        # The common list-row shapes (docs/deferred.md).
        "listrow-compose",
        # The platform tints on a filled container, light and dark
        # (docs/tints-plan.md).
        "tints-compose",
        "tintsdark-compose",
        "scrollto-compose",
        # The number field in the everyday locale and in German
        # (docs/number-field-plan.md §5); MODS cuts the steps.
        "timecode-compose", "numberfield-compose", "numberfieldde-compose",
        # Under ar-EG, what a typed number may contain (§3 rule 5).
        "numberfieldar-compose",
        # The colour picker's synthesized sheet (docs/color-picker-plan.md §6).
        "colorpicker-compose",
        # The range and the rotated fader, and under ar-EG (docs/range-plan.md
        # §5); MODS drops the keyboard's lines.
        "range-compose", "rangertl-compose",
        # Immersive mode (docs/fullscreen-plan.md §3): MODS cuts the user half.
        "fullscreen-compose",
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
        "dnd-compose", "pickers-compose", "sliders-compose",
        # The task manager: a RUST app by design (docs/tasks-plan.md §0).
        "tasks-compose",
        # What survives a relaunch (docs/tasks-s4-plan.md P7): the same
        # guest, the PLAIN door.
        "taskspersist-compose",
        "tooltips-compose",
        "search-compose",
        # The secure field (docs/secure-entry-plan.md §5).
        "secure-compose",
        # The reveal toggle (docs/reveal-plan.md §5).
        "reveal-compose",
        # The segmented control (docs/segmented-plan.md §6).
        "segmented-compose",
        # The expander (docs/expander-plan.md §5).
        "expander-compose",
        # The toast (docs/toast-plan.md §6).
        "toast-compose",
        # The safe area and the keyboard (docs/safe-area-plan.md §5): `bleed`,
        # and the task manager and the content-type form with the keyboard up,
        # upright and in an app pinned to landscape (FLAGS).
        "safearea-compose", "taskskeyboard-compose", "autofillkeyboard-compose",
        "taskskeyboardland-compose", "autofillkeyboardland-compose",
        # And under the emulator's tall cutout, upright and in landscape (§5.5).
        "autofillkeyboardcutout-compose", "autofillkeyboardcutoutland-compose",
        # The content type (docs/autofill-plan.md §5).
        "autofill-compose",
        "submit-compose",
        # The notification conformance scene: rust-only for now, so it
        # rides the compose suite alone (docs/tasks-s3-plan.md §5).
        "notify-compose",
        # The app's icon badge (docs/app-badge-plan.md): the count rides the
        # showing notification.
        "badge-compose",
        # The emoji button (docs/emoji-picker-plan.md R1): androidx's picker.
        "emoji-compose",
        # A URL that opens the app on the thing it names
        # (docs/app-links-plan.md L5): the same tasks guest, warm through
        # the app's own startActivity and cold through `am start -a VIEW`.
        "links-compose",
        # The rich text scene (docs/rich-text-plan.md R9): rust-only for
        # now — no python, go or jvm guest spells a Document yet — so it
        # rides the compose suite alone, and it is an IME_SCENES member,
        # which is what puts the helper keyboard under its `compose` step.
        "richtext-compose",
        # The app-owned undo scene (docs/rich-text-plan.md §14): rust-only
        # for richtext's reason, so it rides the compose suite alone.
        "ownundo-compose",
        # The rich LABEL scene (docs/rich-text-plan.md §15): rust-only for
        # richtext's reason, and no IME_SCENES member — a label takes no
        # user edit at all.
        "richlabel-compose",
        "notes-compose",
        # THE RICH ROWS (docs/rich-text-plan.md §19): rust-only for
        # richtext's reason, and no IME_SCENES member — the copy's act is
        # the harness's format verb.
        "richrows-compose",
        "sheet-compose",
        # The formatter door and the catalog (docs/compliance-plan.md §6):
        # rust-only until the eight bindings' fmt lands, the same guest
        # under the everyday locale and two more through SCENE_LOCALE.
        "format-compose", "formatde-compose", "formatar-compose",
        # The task manager in Arabic (docs/compliance-plan.md §6): no drag,
        # no notification, so pooled where tasks-compose is exclusive.
        "tasksrtl-compose",
        # The scroll guest's sideways strip in Arabic (docs/hscroll-plan.md §4).
        "scrollrtl-compose",
        # And at twice the text size, the tasks screens and the format
        # guest (docs/compliance-plan.md §6; SCENE_TEXT_SCALE).
        "tasksbig-compose", "formatbig-compose",
        "clock24-compose",
        # The media suite (docs/media-plan.md §7a) against the lane's own
        # local server (tools/lib/media_server.py's LANE_PORTS). NOT EXCLUSIVE:
        # the media key goes to the emulator's own media button session, which
        # no other lane and no other device of the pool shares.
        "media_formats-compose", "media_delivery-compose", "media_session-compose",
        "media_tracks-compose", "media_feed-compose",
        # The reader and the canvas's images (docs/media-plan.md §8).
        "media_reader-compose",
        # A picked clip played (docs/media-plan.md §2): rust-only, DocumentsUI.
        "media_picked-compose",
        # The bound (docs/media-plan.md §7c): rust-only.
        "media_timeout-compose",
        # Network images (docs/network-images-plan.md §5): the affordance
        # scene, and the row helper against the lane's server.
        "netimage-compose", "netimage_http-compose",
        # The skin (docs/styling-pass-plan.md §5), the gradient in the dark too.
        "grounds-compose", "groundsdark-compose", "shapes-compose", "cards-compose",
        "tracks-compose", "dock-compose",
        # The capture (docs/capture-plan.md §7): the emulator's own cameras
        # and microphone carrying the synthetic devices
        # (tools/lib/emulator_capture.py).
        "capture-compose", "capture_denied-compose",
    ],
    "jvm": [
        "jvm", "a11y-jvm", "entry-jvm",
        "gallery-jvm", "todos-jvm", "remount-jvm",
        "reorder-jvm", "feed-jvm", "grow-jvm",
        "align-jvm", "layout-jvm", "stall-jvm",
        "confirm-jvm", "nav-jvm", "scroll-jvm",
        "progress-jvm", "select-jvm", "radio-jvm",
        "grid-jvm", "textarea-jvm", "search-jvm", "secure-jvm", "reveal-jvm", "segmented-jvm", "expander-jvm", "safearea-jvm", "toast-jvm", "autofill-jvm", "submit-jvm", "scrollto-jvm", "fullscreen-jvm", "sections-jvm",
        "menus-jvm", "toolbar-jvm", "identity-jvm",
        "listdetail-jvm", "commands-jvm", "clipboard-jvm",
        "background-jvm", "undo-jvm", "filedialog-jvm",
        "remount-filedialog-jvm",
        "table-jvm", "save-jvm", "dirty-jvm",
        "ranges-jvm", "styling-jvm", "typeface-jvm",
        "assets-jvm", "dnd-jvm", "pickers-jvm", "sliders-jvm", "tooltips-jvm",
        "sheet-jvm",
        "format-jvm", "formatde-jvm", "formatar-jvm",
        "timecode-jvm", "numberfield-jvm", "numberfieldde-jvm", "colorpicker-jvm",
        "range-jvm", "rangertl-jvm",
        "media_formats-jvm", "media_delivery-jvm", "media_session-jvm",
        "media_tracks-jvm", "media_feed-jvm", "media_reader-jvm",
        "netimage-jvm", "netimage_http-jvm",
        "grounds-jvm", "shapes-jvm", "cards-jvm", "tracks-jvm", "dock-jvm",
        "capture-jvm", "capture_denied-jvm",
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
        "textarea-go", "search-go", "secure-go", "reveal-go", "segmented-go", "expander-go", "safearea-go", "toast-go", "autofill-go", "submit-go", "scrollto-go", "fullscreen-go", "sections-go", "menus-go",
        "toolbar-go", "identity-go", "listdetail-go",
        "commands-go", "clipboard-go", "background-go",
        "undo-go", "filedialog-go", "save-go",
        "dirty-go", "ranges-go", "editor-go", "chat-go",
        # The chat app with the keyboard up, upright and pinned to landscape
        # (docs/safe-area-plan.md A5, A17).
        "chatkeyboard-go", "chatkeyboardland-go",
        "dnd-go", "pickers-go", "sliders-go", "tooltips-go",
        "sheet-go",
        "format-go", "formatde-go", "formatar-go",
        "timecode-go", "numberfield-go", "numberfieldde-go", "colorpicker-go",
        "range-go", "rangertl-go",
        "media_formats-go", "media_delivery-go", "media_session-go",
        "media_tracks-go", "media_feed-go", "media_reader-go",
        "netimage-go", "netimage_http-go",
        "grounds-go", "shapes-go", "cards-go", "tracks-go", "dock-go",
        "capture-go", "capture_denied-go",
    ],
    "python": [
        "varied-python", "portfolio-python", "music_home-python", "music_playlist-python",
        "music_header-python", "music_headerdark-python", "music_dock-python",
        "music_artist-python", "music_artistdark-python", "music_search-python",
        "music_dockdark-python",
    ],
}

# A python scene whose guest file is another's, staged under the scene's
# name, the one the host's main.py runs (tools/pyhost-main.py).
PYTHON_GUESTS = {"portfolio": "portfolio", "varied": "varied", "music_home": "music",
                 "music_playlist": "music", "music_header": "music", "music_dock": "music",
                 "music_artist": "music", "music_search": "music"}

# The locale a scene runs under, the knob the leg carries as an intent
# extra (docs/compliance-plan.md §4); the reads ask the platform, never
# this.
SCENE_LOCALE = {"formatde": "de-DE", "formatar": "ar-EG", "tasksrtl": "ar-EG",
                "scrollrtl": "ar-EG", "numberfieldde": "de-DE", "numberfieldar": "ar-EG",
                "rangertl": "ar-EG"}

# The text-scale knob a scene carries (docs/compliance-plan.md §2.1): the
# forced Configuration's fontScale and the Density every sp reads.
SCENE_TEXT_SCALE = {"tasksbig": "2", "formatbig": "2"}

# THE PLATFORM'S OWN DOOR FOR A SECOND ACT (docs/tasks-s9-plan.md R6, R7),
# per scene that carries a `relaunch`: this lane's is a real tap on the
# notification's row in SystemUI's shade, taken once act one's process is
# gone — the `notification_activate` verb's one hand, one act later.
# tools/check-steps.py reads this beside the other lanes' doors; the
# runner refuses a scene whose door it does not open, and a door named
# for a scene with no `relaunch`.
RELAUNCH_DOOR = {"tasks": "notify_tap", "taskspersist": "launch",
                 # The cold link door: `am start -a VIEW -d <url>`,
                 # narrowed to this package (docs/app-links-plan.md
                 # §4; docs/traps.md on the chooser).
                 "links": "link"}

# THE RECREATION LEGS' SCENE and the statement they cut in half:
# `todos` because the model it re-projects is EARNED, and the cut is
# after `expect_focused`, the last statement that reads view-local
# state (docs/deferred.md's mount entry).
REMOUNT_SCENE = "todos"
REMOUNT_STEP = 7
REMOUNT_LINE = "KAYA_REMOUNT: recreating after step 7 (expect_focused entry#0)"

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
    # THE PICKER ACROSS A RECREATION: the result belongs to the
    # ActivityRecord, which a recreation keeps, while the launcher
    # belonged to the Activity INSTANCE it destroyed — measured
    # 2026-09-06 losing a RESULT_OK the process had already received,
    # with the core's one-live-dialog slot never retired and the guest
    # waiting for the life of the process (docs/deferred.md's
    # dialog-family WATCH). Step 3 is the click that opens the picker.
    "remount-filedialog-jvm": {
        "scene": "filedialog",
        "remount": (4, "KAYA_REMOUNT: recreating after step 4 "
                       "(click button#0)")},
    # The dark half of expect_ink's frozen string, one leg instead of a
    # lane re-run (check-appearance holds the leg here).
    "canvasdark-compose": {"scene": "canvas", "appearance": "dark"},
    "tintsdark-compose": {"scene": "tints", "appearance": "dark"},
    "groundsdark-compose": {"scene": "grounds", "appearance": "dark"},
    "music_headerdark-python": {"scene": "music_header", "appearance": "dark"},
    "music_artistdark-python": {"scene": "music_artist", "appearance": "dark"},
    "music_dockdark-python": {"scene": "music_dock", "appearance": "dark"},
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
    # A LANDSCAPE LEG PINS ITS APP, NEVER THE DEVICE (docs/safe-area-plan.md
    # §5.4): KAYA_ORIENTATION, and the runner reads the display's rotation
    # back with the app in front, and again on the next leg on that device.
    "taskskeyboardland-compose": {"scene": "taskskeyboard", "orientation": "landscape"},
    "autofillkeyboardland-compose": {"scene": "autofillkeyboard", "orientation": "landscape"},
    "chatkeyboardland-go": {"orientation": "landscape"},
    # THE CUTOUT IS THE EMULATOR'S OWN OVERLAY (docs/safe-area-plan.md §5.5),
    # on for the leg's device before its launch and off when it ends, each
    # read back by the runner.
    "autofillkeyboardcutout-compose": {"scene": "autofillkeyboard", "cutout": "tall"},
    "autofillkeyboardcutoutland-compose": {"scene": "autofillkeyboard", "cutout": "tall",
                                           "orientation": "landscape"},
}

# The fullscreen scene's app-only way back after the cut, the same steps as
# tools/lib/lanes/ios.py's FULLSCREEN_APP_TAIL: no user change arrives, so
# the label still says so.
FULLSCREEN_APP_TAIL = ('click button#0;expect label#0 "asked for a window";'
                       'expect_fullscreen off;click button#1;'
                       'expect label#2 "pings 2";'
                       'expect label#1 "no change from the user";')

# Script modifiers, keyed by SCENE and shared by every suite that runs it
# — the two mobile lanes take the same list and grammar, since two
# answers to one question is how lanes drift. `cut` is
# (verb, keep, extra-for-validation); `drop` is a TUPLE OF BLOCKS, each
# (step specs, keep, reason), each spec a leading run of words naming
# exactly one step and the specs of one block together one contiguous
# run; `append` rides after the cut's prefix. The reasons live at the
# runner's sites and the plans.
MUSIC_SEARCH_TAIL = ('select_section 1;expect_placeholder search@find "Artists, albums or tracks";expect_ax search@find "field/Search";expect label@search_status "Search Jamendo for artists, albums and tracks.";expect_segments segmented@chips "[All]|Albums|Artists|Tracks";click search@find;expect_focused search@find;type "David";expect label@search_status "2 albums · 1 artist · 3 tracks";expect_image_phase image@found_album_art[149020] shown;expect_shape image@found_album_art[149020] rounded;expect label@found_album_name[149020] "David Amber and Friends, Vol. 1";expect label@found_album_name[154466] "David Amber and Friends, Vol. 2 Instrumentals";expect_text_lines label@found_album_name[154466] 3 whole;expect_same_width column@found_album[154466] column@found_artist[476280];expect_same_height column@found_album[154466] column@found_album[149020];expect label@found_artist_name[476280] "David Amber";expect label@found_track_name[1243462] "Gnarly (feat. Devyn Rush)";expect label@found_track_time[1243462] "0:20";expect_image_phase image@found_track_art[1243462] shown;expect_no_clipping;choose segmented@chips 1;expect_segments segmented@chips "All|[Albums]|Artists|Tracks";expect label@search_status "2 albums";expect_no_target column@found_artist[476280];expect_no_target row@found_track[1243462];choose segmented@chips 2;expect label@search_status "1 artist";expect_image_phase image@found_artist_art[476280] shown;expect_shape image@found_artist_art[476280] circle;expect_no_target column@found_album[149020];choose segmented@chips 3;expect label@search_status "3 tracks";expect_no_target column@found_artist[476280];click row@found_track[1243462];expect label@dock_title "Gnarly (feat. Devyn Rush)";expect_tint label@found_track_name[1243462] accent;click row@dock_open;expect_sheets 1;toggle checkbox@like on;dismiss_sheet;expect_sheets 0;expect_toast "Added to Liked Songs|Undo";toast_action;expect_no_toast;click row@dock_open;expect_sheets 1;expect_checked checkbox@like off;toggle checkbox@like on;dismiss_sheet;expect_sheets 0;expect_toast "Added to Liked Songs|Undo";choose segmented@chips 0;expect label@search_status "2 albums · 1 artist · 3 tracks";clear_search search@find;expect search@find "";expect label@search_status "Search Jamendo for artists, albums and tracks.";expect_segments segmented@chips "[All]|Albums|Artists|Tracks";expect_no_target column@found_album[149020];expect_no_target row@found_track[1243462];click search@find;expect_focused search@find;type "zzqxv";expect label@search_status "No results for “zzqxv”.";expect_no_target column@found_artist[476280];set_text search@find "David";expect label@search_status "2 albums · 1 artist · 3 tracks";expect label@found_artist_name[476280] "David Amber";click column@found_artist[476280];expect_ax label@artist_name "heading/David Amber";back;expect label@search_status "2 albums · 1 artist · 3 tracks";select_section 0;expect_title "Music";')

MODS = {
    "sections": {"cut": ("expect_windows",
                         "expect_section expect_section_symbol", "")},
    "adaptive": {"cut": ("resize_window",
                         "expect_axis=row@dash expect_axis=column@steady",
                         'expect_axis row@narrow "vertical"; expect_grid_columns grid@sheet 1; '
                         'expect_grid_columns grid@fit 1'),
                 "append": 'expect_axis row@narrow "vertical"; expect_grid_columns grid@sheet 1; '
                           'expect_grid_columns grid@fit 1;'},
    "portfolio": {"cut": ("resize_window", "expect_window=column@ledger",
                          "expect_folded column@summary column@ledger"),
                  "append": "expect_folded column@summary column@ledger;"},
    "dirty": {"cut": ("close_window", "expect_dirty", ""),
              "append": 'expect_title "dirty"'},
    # THE DETENT IS THE PHONES' TO ANSWER (docs/sheet-plan.md §4): the
    # shared script asserts the desktops' `none`; this lane drops that
    # step and reopens the medium sheet at the end to read the platform's
    # own anchor back, then cancels it through back.
    "sheet": {"drop": ((("expect_sheet_detent none",), "expect_sheet",
                        "the phones answer the detent"),),
              "append": "click button#0;expect_sheets 1;"
                        "expect_sheet_detent medium;dismiss_sheet;"
                        "expect_sheets 0;"},
    "editor": {"cut": ("close_window", "expect_dirty", "")},
    # A PHONE HAS NO USER DOOR OUT OF IMMERSIVE MODE (docs/fullscreen-plan.md
    # §2): the swiped-in bars are transient. The cut takes the user half, and
    # the append runs the app's own way back, which reads the insets again.
    "fullscreen": {"cut": ("user_fullscreen", "expect_fullscreen", ""),
                   "append": FULLSCREEN_APP_TAIL},
    # A PHONE'S NUMBER FIELD HAS NO STEPPING DOOR (docs/number-field-plan.md
    # §3 rule 7): the scene steps last, so the cut takes the steps alone.
    "timecode": {"cut": ("nudge", "expect_value", "")},
    "numberfield": {"cut": ("nudge", "expect_focused expect_ax", "")},
    "numberfieldde": {"cut": ("nudge", "expect_focused expect_ax", "")},
    # A PHONE'S SLIDER HAS NO KEYBOARD DOOR (docs/range-plan.md §5, the
    # number field's precedent): each arrow and what it feeds.
    "range": {"drop": (
        (("nudge range#0", 'expect_value range#0 "3 4.5"',
          'expect label#1 "commits: 5'),
         "expect_thumb expect_ax", "a phone's slider has no keyboard door"),
        (("nudge slider#1", 'expect_value slider#1 "0.5"',
          'expect label#2 "volume: 0.5"', 'expect_thumb slider#1 "0.5"'),
         "expect_thumb=range#0 expect_axis expect_ax",
         "a phone's slider has no keyboard door"),
    )},
    "identity": {"drop": ((("expect_title window#1",), "expect_app_icon",
                           "no auxiliary windows"),)},
    # A phone has no pointer (docs/styling-pass-plan.md §5): the cards leg
    # ends at its first hover.
    "cards": {"cut": ("hover", "expect_selected expect_ax", "")},
    # An image ground at a screen's top runs under the status bar
    # (docs/media-player-plan.md M15).
    "grounds": {"append": 'expect_ground_reach column@hero top;expect_system_bars "legible/legible";'},
    # The macOS native table's own keyboard (docs/styling-pass-plan.md Y4,
    # AMENDED 2026-10-17): this tier's table has no selection of its own to move.
    "tracks": {"cut": ("press down", "expect_tint expect_rows", "")},
    # The media player demo on a phone (docs/media-player-plan.md M6): no
    # pointer, and the library is the Library section, not the sidebar.
    "music_playlist": {"cut": ("expect_title", "expect_tint", ""),
                       "append": "expect_columns column@tracks \"#|Title|Time\";expect_rows column@tracks \"4,Seven Chimes/Pierce Murphy,0:20|7,Athens/Pierce Murphy,0:20\";back;expect_selected column@card_201715 on;click column@card_581719;expect_rows column@tracks \"1,A Serpent I Did Hear/Pierce Murphy,0:20|2,Persimmon/Pierce Murphy,0:20\";back;select_section 2;click row@saved[201715];expect_rows column@tracks \"4,Seven Chimes/Pierce Murphy,0:20|7,Athens/Pierce Murphy,0:20\";back;expect_selected row@saved[201715] on;"},
    "music_header": {"cut": ("click row@go_home", "expect_ground expect_shape", ""),
                     "append": "expect_ground_reach column@album_header top;expect_system_bars \"legible/legible\";expect_title \"Through The Olive Branches\";back;expect_system_bars \"legible/legible\";expect_title \"Music\";click column@card_581719;expect_checked checkbox@favorite off;back;click column@card_201715;expect_checked checkbox@favorite on;toggle checkbox@favorite off;expect_checked checkbox@favorite off;expect_pref music.favorites \"\";"},
    # The dock's phone half: a tap opens the full player, which holds the rest.
    # The dock's progress line follows the player (docs/media-player-plan.md M17); its height is M18's.
    "music_dock": {"cut": ("click button@play_pause", "session_send expect_now_playing expect_dock", ""),
                   "append": 'expect_dock_height 64;expect_image_size image@dock_art "48x48";click row@dock_open;expect_sheets 1;expect_sheet "Now Playing";expect_inset column@full_player 16;expect_image_phase image@full_art shown;expect label@full_title "In Tune";expect_help button@full_play_pause "Pause";expect_help button@previous "Previous";expect_help button@full_next "Next";expect_help checkbox@shuffle "Shuffle";expect_help checkbox@repeat "Repeat";expect_help checkbox@like "Like";click button@full_play_pause;expect_ax button@full_play_pause "button/Play";set_value slider@progress 0.5;expect_value slider@progress "0.5";expect label@elapsed "0:10";expect label@remaining "-0:10";expect_dock_line 0.5;click button@full_play_pause;expect_ax button@full_play_pause "button/Pause";hold slider@progress at 0;settle 1000;expect_value slider@progress "0";click button@full_play_pause;expect_ax button@full_play_pause "button/Play";release slider@progress;expect_value slider@progress "0";expect label@elapsed "0:00";expect label@remaining "-0:20";expect_dock_line 0;expect_ax checkbox@shuffle "toggle/Shuffle";expect_checked checkbox@shuffle off;toggle checkbox@shuffle on;expect_checked checkbox@shuffle on;toggle checkbox@shuffle off;expect_checked checkbox@shuffle off;expect_ax checkbox@repeat "toggle/Repeat off";expect_checked checkbox@repeat off;expect_symbol checkbox@repeat "repeat";toggle checkbox@repeat on;expect_ax checkbox@repeat "toggle/Repeat all";expect_checked checkbox@repeat on;expect_symbol checkbox@repeat "repeat";toggle checkbox@repeat off;expect_ax checkbox@repeat "toggle/Repeat one";expect_checked checkbox@repeat on;expect_symbol checkbox@repeat "repeat_one";toggle checkbox@repeat off;expect_ax checkbox@repeat "toggle/Repeat off";expect_checked checkbox@repeat off;expect_symbol checkbox@repeat "repeat";expect_ax checkbox@like "toggle/Like";toggle checkbox@like on;expect_checked checkbox@like on;click button@full_next;expect label@full_title "Owl Time";expect_checked checkbox@like off;click button@previous;expect label@full_title "In Tune";expect_checked checkbox@like on;click button@full_next;expect label@full_title "Owl Time";expect_ax button@full_play_pause "button/Pause";click button@full_play_pause;expect_ax button@full_play_pause "button/Play";set_value slider@progress 0.5;expect label@elapsed "0:10";click button@previous;expect label@full_title "Owl Time";expect label@elapsed "0:00";click button@previous;expect label@full_title "In Tune";dismiss_sheet;expect_sheets 0;expect label@dock_title "In Tune";select_section 2;expect label@liked_count "1 song";click row@dock_open;expect_sheets 1;click button@full_next;expect label@full_title "Owl Time";toggle checkbox@like on;expect_help checkbox@like "Remove from Liked Songs";dismiss_sheet;expect_sheets 0;expect_toast "Added to Liked Songs|Undo";expect label@liked_count "2 songs";click row@go_liked;expect_ax label@liked_title "heading/Liked Songs";expect label@liked_about "2 songs, 40 sec";expect_rows column@liked_tracks "1,Owl Time/Kellee Maize,0:20|2,In Tune/Kellee Maize,0:20";expect_tint label@liked_track_name[989873] accent;click row@dock_open;expect_sheets 1;toggle checkbox@like off;dismiss_sheet;expect_sheets 0;expect_toast "Removed from Liked Songs|Undo";expect label@liked_count "1 song";expect_no_target row@liked_track[989873];expect_rows column@liked_tracks "1,In Tune/Kellee Maize,0:20";toast_action;expect_no_toast;expect label@liked_count "2 songs";expect_rows column@liked_tracks "1,Owl Time/Kellee Maize,0:20|2,In Tune/Kellee Maize,0:20";click row@liked_track[989871];expect label@dock_title "In Tune";expect_tint label@liked_track_name[989871] accent;back;expect label@liked_count "2 songs";select_section 0;'},
    "music_artist": {"cut": ("expect_title", "expect_ground expect_fill expect_shape expect_tint", ""),
                     "append": 'expect_ground_reach column@artist_header none;expect_system_bars "legible/legible";expect_columns column@top_tracks "#|Title";expect_rows column@top_tracks "1,In Tune (J. Glaze Remix)/Kellee Maize|2,In Tune/Kellee Maize|3,Owl Time/Kellee Maize|4,Mad Humans (J. Glaze Remix)/Kellee Maize";back;expect_ax button@album_artist "button/Kellee Maize";back;expect_title "Music";'},
    # Search is the phone's second section; the like is the full player's, read
    # once the sheet is down (docs/toast-plan.md T8: a toast sits below a modal).
    "music_search": {"cut": ("click row@go_search", "expect_image_phase=image@art_116452",
                             MUSIC_SEARCH_TAIL),
                     "append": MUSIC_SEARCH_TAIL},
    "music_home": {"cut": ("hover", "expect_ax expect_grid_columns", ""),
                   "append": "expect_title \"Music\";click column@card_201715;back;expect_selected column@card_201715 on;expect_selected column@card_581719 off;expect_fill column@card_201715 selected;click column@card_139585;back;expect_selected column@card_139585 on;expect_selected column@card_201715 off;select_section 2;expect_selected row@saved[139585] on;expect_selected row@saved[201715] off;expect_image_phase image@saved_art[139585] shown;expect_shape image@saved_art[139585] rounded;click row@saved[201715];back;expect_selected row@saved[201715] on;select_section 0;expect_selected column@card_201715 on;expect_selected column@card_139585 off;"},
    # A phone app is handed no FOREIGN drag source (docs/dnd-plan.md D9),
    # so the file drop and the one assertion it feeds do not run here;
    # every drag between this app's own widgets does.
    # THE FRAME IS THE DESKTOPS' (docs/tasks-s4-plan.md §4): a phone has no
    # window frame, so the resize in act one and the size assertion in act
    # two both go. TWO BLOCKS AND NOT A CUT — they sit on opposite sides of
    # the `relaunch`, and a tail cut at `resize_window` would take the whole
    # second act with it, which is the thing this leg exists for.
    "taskspersist": {"drop": (
        (("resize_window",), "relaunch expect_pref",
         "the system owns the surface on a phone"),
        (("expect_window_size",), "expect_pref expect_no_pref",
         "a phone window has no frame to remember"),
    )},
    # THE INSETS ARE THE DEVICE'S (docs/safe-area-plan.md A8, A18): the pool
    # phone's status bar and gesture bar, then what immersive mode leaves.
    "safearea": {"append": 'expect_insets "bar/bar";click button@full;'
                           'expect label@caption "fullscreen";expect_fullscreen on;'
                           'expect_insets "none/none";expect_safe image@picture bleeds;'
                           'expect_safe canvas@ground bleeds;expect_safe label@caption;'},
    "dnd": {"drop": ((("drag_file",
                       'expect label#4 "files target got dropped.txt '
                       'dropped bytes (copy)"'),
                      "expect_order expect=label#5 expect=label#0",
                      "no foreign drag source reaches a phone app"),)},
}

# Machine-derived by tools/lib/android-leg-order.py from the shared
# verbs: the scenes that leave the app for DocumentsUI or read what an
# assistive service is handed (the accessibility service), and the one
# that opens a composing region (the helper IME).
A11Y_SCENES = ["chat", "filedialog", "save", "editor", "media_picked", "toast"]
IME_SCENES = ["ranges", "richtext"]

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


def unisolated_setting_legs(alone=None, exclusive=None):
    """Setting legs in neither isolated set: a pooled one would change the
    device under its neighbours (the runner's scene_setting)."""
    isolated = (ALONE if alone is None else alone) | (EXCLUSIVE if exclusive is None else exclusive)
    return sorted(leg for leg in legs()
                  if scene_of(leg) in SCENE_SETTINGS and leg not in isolated)


if unisolated_setting_legs():
    raise SystemExit(f"lanes/android.py: {', '.join(unisolated_setting_legs())} "
                     f"run(s) under a SCENE_SETTINGS device setting but sit in "
                     f"neither ALONE nor EXCLUSIVE; add each to one of them")
