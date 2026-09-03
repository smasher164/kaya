# film-android — the kaya EDITOR on Android (editor-go leg)

> SUPERSEDED AS THE SHIPPING FILM, 2026-08-17 16:32. §9's defect was
> fixed and the leg re-filmed; see film-android-2.md. The two files §7
> names are now **editor-android-STALE-TITLE.mp4** and
> **editor-android-STALE-TITLE-web.mp4** — editor-android.mp4 and
> -web.mp4 are the new, fixed film. §8's three stills are UNCHANGED and
> still under their own names; still-2.45.png is the defect frame this
> document and KayaCompose.kt both cite, and it is also copied to
> films/defect-frame-stale-title.png.

Charge: a short film of the editor's byte-frozen scene running on the
Android emulator, the `editor-go` leg. RUN-ONLY: no repo edits.
Device: emulator-5554 ONLY. Boot nothing, kill nothing.

## 0. What the leg is (read out of tools/android/run-emulator.py)

- Leg name `editor-go`, lines 1748-1752. APK
   ```
  `android/gohost/build/outputs/apk/debug/gohost-debug.apk`,
   ```
  component `dev.kaya.gohost/.MainActivity`, `KAYA_SELFTEST editor`.
- The steps variant is **not** the whole `tools/scenes/editor.steps`: it is
  `scene_script_cut editor close_window expect_dirty` — everything ABOVE the
  first `close_window` step, folded into `;` (intent extras carry no
  newlines). The cut drops the window's own unsaved-work door, which a
  phone has not got; `expect_dirty` is the keep verb and both of its
  spellings (false and true) survive above the cut.
- Launch shape (run_apk_on, lines 514-704): install -r, force-stop app +
  both DocumentsUI packages, `logcat -c`, arm the harness accessibility
  service (retried, bounded wait on `dumpsys accessibility` /
  `Bound services:.*kaya`), then
  `am start -W -n <component> --es KAYA_SELFTEST <scene> --es KAYA_SELFTEST_SCRIPT '<script>'`,
  then `logcat -s kaya:* -e 'KAYA_SELFTEST: (OK|FAILED)' -m 1`.
- The editor leg needs the picker in BOTH modes (ACTION_OPEN_DOCUMENT and
  ACTION_CREATE_DOCUMENT), so the accessibility service arm is mandatory.

## 1. Emulator state at start

    $ nix develop -c adb devices
    List of devices attached
    emulator-5554	device
    emulator-5556	device
    emulator-5558	device
    emulator-5560	device

Four warm instances, qemu pids 1856/1859/1862 (+ tablet), etime ~21 days —
they predate this session. I boot none and kill none. Saved verbatim to
scratchpad/chrome/films/adb-before-editor.txt (gone).

## 2. The script that was filmed

`scene_script_cut` was not retyped — the runner's own python body was
extracted from tools/android/run-emulator.py by locating the function and
its `<<'PY'` heredoc, and run with the leg's arguments
(`editor close_window expect_dirty`). Output:
scratchpad/chrome/films/scene_script_cut.py (gone) (the extract),
editor-cut.txt (96 steps), editor-script.txt (97 = + `settle 8000`).

What the cut declines, printed by the runner's own code
(films/editor-notrun.txt):

    NOT RUN on this host (after `close_window`): close_window window#0
    NOT RUN on this host (after `close_window`): expect_alert "unsaved changes"
    NOT RUN on this host (after `close_window`): alert_choose cancel
    NOT RUN on this host (after `close_window`): expect_windows 1
    NOT RUN on this host (after `close_window`): expect_dirty true
    NOT RUN on this host (after `close_window`): expect_ax label#0 "label/new file"

So the leg's LAST run step is `expect_dirty true` after `type "q"`, and
that is the film's final visible state. The film shows exactly what the
leg runs — no more, no less — plus the trailing settle.

## 3. Artifacts were verified before anything ran

    tools/build-id.py --verify --component compose \
   ```
      android/gohost/build/outputs/apk/debug/gohost-debug.apk   rc=0
   ```
    tools/build-id.py --verify \
   ```
      android/gohost/src/main/jniLibs/arm64-v8a/libkaya.so            rc=0
   ```

Both carry the id of the CURRENT sources (tree clean at 0254879), so no
rebuild was needed and none was done — this is a RUN-ONLY charge and the
lane's own staleness guard says the artifact on disk is the right one.
(The Go guest .so carries no marker by design; run-emulator.py:1558-1565
says why. It was written in the same build as the two above, 15:42.)

## 4. Dry run (timing, before committing to a recording window)

films/run-editor-leg.sh — the run_apk_on sequence by hand on 5554.

    a11y bound after 1 arm(s)
    ELAPSED_MS=11312      # am start -> verdict
    KAYA_SELFTEST: OK (...)

11.3s, of which 8.0s is the appended settle: the scene proper is ~3.3s.
That is what sized the recording window; nothing was guessed.

## 5. The filmed run

films/film-editor-leg.sh. The install and the accessibility arm happen
BEFORE the recorder starts, so the recording window covers only launch +
scene + settle.

THE RECORDER WAS NEVER SIGNALLED. `screenrecord --time-limit 22
--bit-rate 8000000` was allowed to reach its own limit and exit rc=0 —
the buffered-tail drop this repo measured cannot happen if nothing kills
it. Verified before trimming that the tail is really in the pulled file:
the 2fps contact sheet (films/probe/sheet2fps.png) shows the app still on
screen at 13.0s and the launcher from 13.5s, i.e. the app's own exit is
IN the recording, several seconds inside the file.

    raw: 320x640, h264, 21.60s, 2,514,468 bytes, 429 frames

Device geometry is the lane's, unchanged by me: `wm size` 320x640 at
density 160 — run-emulator.py:72 ("every pool device is 320dp wide, an
unambiguously COMPACT width").

VERDICT (the filmed run's own line, in full):

    08-17 15:54:45.103  6497  6601 I kaya    : KAYA_SELFTEST: OK (new file, , ,
    dirty false, title "untitled", new file|, root fills, textarea#0 fills,
    2 menus, menu "Edit>Undo" disabled, textarea#0 focused, alpha 1 beta 22,
    dirty true, menu "Edit>Undo" enabled, save dialog "kaya-editor-6497"
    "untitled", save dialog "kaya-editor-6497" "draft", saved, 15 bytes,
    dirty false, title "draft", file dialog "kaya-editor-6497" [decoy, draft,
    notes], opened, 131 bytes, dirty false, title "notes", textarea#0 focused,
    dirty true, dirty false, textarea#0 focused, dirty true, saved, 134 bytes,
    dirty false, title "notes", no matches, , bad pattern, expect_highlights ,
    1 of 4, expect_highlights 4:5=7|66:68=13|129:131=42|132:134=99,
    expect_selection 4:5=7, 132:134 offscreen, 4 of 4, expect_selection
    132:134=99, 132:134 visible, 1 of 4, 4 of 4, scratch, no matches,
    expect_highlights , dirty true, , textarea#0 focused, , no matches, ,
    saved, 134 bytes|, inset row#0 8, alert "unsaved changes", scratch,
    dirty true, alerts 0, alert "unsaved changes", , new file, dirty false,
    title "untitled", alerts 0, textarea#0 focused, dirty true)

## 6. The trim, anchored IN BAND

No launch/stop wall time was used to place the cuts (the recording-mode
trap). Both boundaries were read off the FRAMES, at 20fps sheets:

- films/probe/start20fps.png (20fps from 2.00s): splash through 2.20,
  cross-fade at 2.25, the editor's own first drawn state ("untitled",
  TopAppBar, empty buffer, "new file") at 2.30, first typed character at
  2.35. **START = 2.20** — two frames of the arrival, then the scene.
- films/probe/end20fps.png (20fps from 5.00s): the second "unsaved
  changes" alert through 5.10, the discarded/empty buffer, and the `q`
  settled by ~5.60. Nothing changes again until the app leaves at ~13.3s
  (2fps sheet). **END = 7.60** — the last visible state held 2.0s so it
  can be read, and the 8s of dead settle dropped.

Film length 5.43s for a scene whose visible run is ~3.4s. Real time, no
retiming: the states are as brief on screen as the leg makes them.

## 7. Output

    editor-android.mp4      360x720 h264 High, yuv420p, 30fps CFR, 5.433s,
                            210,884 B, +faststart (moov@36 < mdat@2581)
    editor-android-web.mp4  360x720 h264 Main, yuv420p, 30fps CFR, 5.433s,
                            112,638 B, +faststart (moov@36 < mdat@2575)

720px-class = 720 on the long edge, which is the portrait phone's; the
source is 320x640 and is upscaled 1.125x with lanczos. Both are the same
cut; the web one is CRF 26 / Main@3.1 for size, the other CRF 18 / High.

## 8. Stills — extracted from the SHIPPED film and viewed

    still-0.60.png  t=0.60  TopAppBar "untitled" + ✓ and 🔍 promoted, ⋮ overflow;
                            buffer "alpha 1 beta|"; status "new file"
    still-2.45.png  t=2.45  the find bar: entry "[0-9]+", prev/next buttons,
                            status "saved, 134 bytes", tally "2 of 4", and the
                            match "13" highlighted green in the document
    still-3.60.png  t=3.60  the final state: buffer "q", status "new file"
    probe/lastframe.png     the film's own last frame — same state, cursor
                            after the q

All four read cleanly at 360x720; the two promoted actions and the
overflow are visible in every one of them.

## 9. One thing the film shows that no gate reads

Not my charge to fix, recorded because the film is where it is visible.

In still-2.45.png the platform ActionBar (top) reads **notes** while the
Compose M3 TopAppBar directly under it reads **untitled** — same frame,
two different titles. The cause is one line:
`KayaSceneModel.windowTitle` is a PLAIN field
(KayaCompose.kt:542 `var windowTitle: String = ""`), while every
neighbouring field a composable reads — `root`, `focusedId`,
`windowInset` — is `by mutableStateOf`. `KayaMenuTopBar`'s title is
`navEntries.lastOrNull()?.title ?: KayaSceneModel.windowTitle`
(KayaCompose.kt:9267) and the editor pushes no nav entries, so the bar
reads a non-observable field: it composes once and never recomposes when
the title moves.

The scene cannot catch it: `expect_title` reads `activity.title`
(KayaCompose.kt:5893-5903, "The REAL materialized title (the Activity
label)"), which line 1260 keeps current — so all four `expect_title`
steps pass green while the bar on screen is stale.

## 10. Cleanup, proven

    $ adb -s emulator-5554 shell am force-stop dev.kaya.gohost
    $ adb -s emulator-5554 shell "ps -A | grep gohost"      -> rc=1, no output
    $ adb -s emulator-5554 shell "ps -A | grep screenrecord"      -> rc=1, no output
    $ ps -Ao pid,etime,pcpu,command | grep screenrecord           -> rc=1, none on host
    $ adb -s emulator-5554 shell rm -f /data/local/tmp/kaya-editor-film.mp4
    $ adb -s emulator-5554 shell "ls -la /data/local/tmp/kaya-editor-film.mp4"
      ls: /data/local/tmp/kaya-editor-film.mp4: No such file or directory   rc=1

The device's /data/local/tmp now holds only what was there before me:
dalvik-cache, kaya-rec.mp4 (2026-07-17), kaya-sora-wght.ttf (2026-08-16).
Neither is mine and neither was touched.

    $ cmp adb-before-editor.txt adb-after-editor.txt   -> identical
    sha256 both: 6a40ef7c14b130abd3447d1557dbc32cf63074e1f0eca45cfbd0cccf29a7ca3c

Emulator pids unchanged and still ~21 days old: 1856 (5554), 1859 (5556),
1862 (5558), 63625 (5560 tablet). I booted none and killed none, and only
5554 was touched.

State I did change on 5554, all of it state the lane rewrites per leg:
the reinstalled debug APK (`install -r`, as run_apk_on does) and
`accessibility_enabled=1` with the harness service selected (run_apk_on
arms that on every leg).

Repo: `git status --short` empty. Nothing in the tree was edited.

Disk: scratchpad/chrome/films (gone) is 8.4M total, of which mine is ~3.0M
(2.5M raw recording kept as the unedited evidence, 1.6M probe sheets,
324K the two films, 221K stills). No large artifacts anywhere else.
