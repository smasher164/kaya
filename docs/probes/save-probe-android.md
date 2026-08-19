# Save probe — ANDROID arm

Repo `/Users/akhilindurti/Projects/kaya` at HEAD `aeb135a`. Probe arm:
nothing in the repo was changed. Device: `emulator-5554`, AVD `kaya`,
API 35 / Android 15, `sdk_gphone64_arm64` google_apis, headless
(`-no-window`), standing since before this session.

Raw logs (kept):
`scratchpad/log-A.txt (gone)` (write), `log-B1.txt` (create), `log-B2.txt`
(createname, createcollide-crash), `log-B3.txt` (createcollide, persist,
plain2), `log-C.txt` (persist2, reopen), `log-D.txt` (createcancel,
createempty).

Every line below is tagged MEASURED (I ran it here), DOCUMENTED (repo
file:line, or a vendor URL), or ASSUMED.

---

## VERDICT A — WRITE MODE TODAY = **works**

Not "partially": on Android the write path is complete, correct, and
already truncating the way the other four platforms do. What it has
never had is a caller.

### The path, end to end (DOCUMENTED, file:line)

1. Guest calls `kaya_open_picked(handle, FILE_MODE_WRITE, …)` —
   `crates/kaya/src/capi.rs:1406`; the mode decode accepts all three
   values at `capi.rs:1420-1423`, so nothing rejects Write earlier.
2. `UriSource::open` — `crates/kaya/src/android.rs:277`. Android has no
   path: the source holds the `content://` URI and opens per redemption.
3. Mode string — `crates/kaya/src/protocol.rs:217-222`:
   Read→`"r"`, Write→`"wt"`, ReadWrite→`"rw"`. `wt` and not `w`
   deliberately: `PathSource` truncates (`protocol.rs:235`), so a bare
   `w` would make one `FileMode` mean two things (docs/traps.md:2344).
4. `open_through_resolver` — `android.rs:307-345`: JNI static call into
   `KayaPresent.openPickedUri`, exception read and cleared, negative fd
   turned into an io error.
5. `KayaPresent.openPickedUri` —
   `android/kaya/src/main/kotlin/dev/kaya/KayaPresent.kt:152-163`:
   `contentResolver.openFileDescriptor(Uri.parse(uri), mode)` then
   `detachFd()`; ownership crosses to the guest.
6. The grant that makes step 5 legal is asked for at pick time —
   `KayaCompose.kt:2136-2139` adds
   `FLAG_GRANT_READ_URI_PERMISSION or FLAG_GRANT_WRITE_URI_PERMISSION`
   to the `ACTION_OPEN_DOCUMENT` intent.
7. Every binding can name the mode: Rust `FileMode`
   (`protocol.rs:83`), Go `PickedFile.Open(mode uint32)`
   (`bindings/go/runtime.go:316`, constants `kaya_wire.go:89-91`),
   Python (`bindings/python/kaya/__init__.py:1359`), Swift
   (`KayaApp.swift:721`), Java (`KayaApp.java:583`), C#
   (`Kaya.cs:34,257`), OCaml (`kaya_runtime.ml:118`), Haskell
   (`KayaApp.hs:349`). MEASURED by grep: 8/8 expose the mode.

So "unimplemented" is wrong. What is true (MEASURED by the coordinator,
re-confirmed here): no scene, leg, guest or unit test has ever passed
`FILE_MODE_WRITE`, and `FILE_MODE_WRITE` appears in no backend file.

### Driven, on the device (MEASURED)

A throwaway app (`dev.kaya.saveprobe`, copy of `tools/android/
pickerprobe` + its accessibility service, same manifest shape, NO
storage permission) launched kaya's picker intent VERBATIM, clicked
`picked.txt` through the same accessibility drive the harness uses, and
then reproduced kaya's open exactly: `openFileDescriptor(uri, mode)` →
`detachFd()` → `FileOutputStream` on the adopted fd → close. Read-back
both through a fresh `"r"` redemption and off the filesystem directly.

| what | mode | result (MEASURED) |
|---|---|---|
| picked URI | — | `content://com.android.externalstorage.documents/document/primary%3ADocuments%2Fkaya-saveprobe%2Fpicked.txt` |
| kaya's write | `wt` | fd=109, regular file, **size-at-open 0** (truncated), 26 B written; re-read through the URI = `"KAYA-WROTE-THIS-THROUGH-wt"`; on disk 26 B, same bytes |
| truncation, from the other side | `wt` over 20 B | file is 5 B `"SHORT"` — truncates |
| the non-truncating trap | `w` over 20 B | file is 20 B `"SHORT56789ABCDEFGHIJ"` — confirms docs/traps.md:2344 and confirms `wt` is the right string |
| READ_WRITE | `rw` | opens, writes in place, no truncation (`"RW23456789ABCDEFGHIJ"`) — matches `PathSource`'s `.read(true).write(true)` at `protocol.rs:236` |
| second redemption, then write | `wt` | fd=115, 17 B, read-back `"SECOND-REDEMPTION"` — save-back needs no descriptor pinned at pick time |
| `openOutputStream(uri,"wt")` | — | works too (9 B `"OUTSTREAM"`) |

Reproduced identically in a second run (`log-B3.txt`, variants `persist`
and `plain2` — three independent picks, same numbers).

**`openOutputStream` is reachable but kaya does not need it** (MEASURED
+ DOCUMENTED): it is a wrapper over `openAssetFileDescriptor`, and it
returns a *stream*, not a descriptor — it cannot serve a vocabulary
whose promise is "the guest gets a real fd and kaya leaves the data
path" (DESIGN.md, File dialogs; `capi.rs:1389-1396`). The existing
`openFileDescriptor` + `detachFd` is strictly more general and is what
Go's `os.NewFile` needs.

### The one thing that is genuinely missing: grant lifetime

MEASURED, and it is the finding that matters for an editor:

| URI | persisted? | fresh process (after force-stop) |
|---|---|---|
| picked, no `takePersistableUriPermission` | no | `SecurityException` on **read** and on **write** — "requires that you obtain access using ACTION_OPEN_DOCUMENT or related APIs" |
| picked, `takePersistableUriPermission(uri, READ\|WRITE)` | yes | `"r"` reads, `"wt"` writes 24 B, read-back correct |

- MEASURED: the picker's result intent carries `flags=0x43` =
  `FLAG_GRANT_READ` \| `FLAG_GRANT_WRITE` \| **`FLAG_GRANT_PERSISTABLE`**
  — in *every* variant, including the one whose request asked only for
  read+write (i.e. kaya's exact intent at `KayaCompose.kt:2136`).
  So `takePersistableUriPermission` **succeeds today with no change to
  the intent**. kaya never calls it, so kaya's handles are
  session-scoped.
- DOCUMENTED (developer.android.com/training/data-storage/shared/
  documents-files): "the system gives your app a URI permission grant
  for that file, which lasts until the user's device restarts"; to
  survive a restart the app must "take" the persistable grant with
  `contentResolver.takePersistableUriPermission(uri, takeFlags)`.
- What I measured is stronger than the doc: a force-stop (task
  destroyed) already kills the non-persisted grant. An editor that
  wants "reopen and save to the file you had open yesterday" needs the
  persistable take; an editor that only saves within one run does not.
- ASSUMED (not measured, deliberately — the emulators are standing and
  I will not reboot one): reboot survival of the persisted grant. The
  vendor doc is explicit that this is exactly what persisting buys.
- Note for the sweep: this is a per-platform capability question, not a
  spelling one — iOS has the same shape (security-scoped bookmarks),
  the desktops keep paths and need nothing. If kaya ever grows
  "remember this file across launches", it is a new vocabulary item
  (a bookmark blob), not a flag.

---

## VERDICT B — SAVE DIALOG = ACTION_CREATE_DOCUMENT, and it is cheap on this platform

### The API and what it answers with (MEASURED)

`Intent(Intent.ACTION_CREATE_DOCUMENT)` + `CATEGORY_OPENABLE` +
`setType("text/plain")` + `EXTRA_TITLE` (the proposed name) +
`EXTRA_INITIAL_URI` (same document-uri trick as the open arm,
`KayaCompose.kt:2219`) + the same grant flags. It answers through the
same `onActivityResult`/`ActivityResultRegistry` path the picker
already uses.

| question | answer (MEASURED) |
|---|---|
| what comes back | ONE `content://` URI in `data.data`, e.g. `…/document/primary%3ADocuments%2Fkaya-saveprobe%2Fkaya-saved.txt`; `flags=0x43` (read+write+persistable) |
| does the file exist yet | yes — DocumentsUI creates it at Save; the first `"wt"` open reports **size 0**, then the guest's write lands (26 B, read-back verbatim) |
| display name | `OpenableColumns.DISPLAY_NAME` = `kaya-saved.txt` — the same query the picker arm already does (`KayaCompose.kt:2196-2205`) |
| the name the user typed | honoured: `ACTION_SET_TEXT` to `kaya-renamed.txt` → result URI ends `kaya-renamed.txt` |
| collision with an existing name | **no prompt, no overwrite**: asking for `picked.txt` answers `picked (1).txt`, display name `picked (1).txt` |
| empty name | **not refused**: SAVE stays enabled, and the document created is literally named `(invalid).txt` |
| cancel | BACK, 3 backs from that depth, panel gone; result `code=0, data=null` — identical shape to the open picker, so "empty is cancel" needs no new sentinel |
| after Save | the panel is gone (`picker still up after save: false`) |
| write-back to the created doc | `wt` writes, read-back correct; `takePersistableUriPermission` succeeds |

**A trap worth writing down** (MEASURED): a file created through SAF in
shared `Documents/` is NOT readable by the app through ordinary file
I/O — `File(dir, "kaya-saved.txt").readText()` throws
`EACCES (Permission denied)`, and the file does not even appear in
`File.list()`, while the app's OWN files in the same directory read
fine. The document belongs to the provider, not to the app. My first
`createcollide` run crashed on exactly this. Consequence for a scene:
**a save leg cannot verify the bytes by reading the path from the
guest on Android** — it must read back through the handle. That is a
cross-platform scene-design constraint (invariant 6: the .steps file is
shared byte-for-byte), not an Android detail to paper over.

### The harness story (MEASURED — this is the good news)

The save panel is DocumentsUI, the same package, and it publishes the
same tree the picker does. From `log-B1.txt`:

```
id=breadcrumb_text  TextView  "sdk_gphone64_arm64" / "Documents" / "kaya-saveprobe"
id=header_title     TextView  "Files in kaya-saveprobe"
id=item_root        CardView  clickable=true   (one per row; /title under it)
id=container_save   ViewGroup
id=title            EditText  "kaya-saved.txt"  editable=true clickable=true
id=button1          Button    "SAVE"            clickable=true enabled=true
```

- `expect_file_dialog <dir> <names...>` works UNCHANGED on the save
  panel: `KayaHarnessAccessibility.pickerState()`
  (`KayaHarnessAccessibility.kt:111-119`) reads the last
  `breadcrumb_text` and the `item_root`/`title` rows, and both are
  present and correct here (MEASURED: rows
  `[decoy.txt, kaya-saved.txt, picked.txt, …]`, breadcrumb
  `kaya-saveprobe`).
- `file_dialog_goto` works unchanged: `EXTRA_INITIAL_URI` aims the save
  panel exactly as it aims the picker (MEASURED — header said
  "Files in kaya-saveprobe" every time).
- `file_choose cancel` works unchanged: BACK, bounded, gone-is-the-proof
  (MEASURED: 3 backs, `RESULT_CANCELED`, null data).
- What is NEW is one verb, the analogue of `file_choose <name>`:
  type a name into `android:id/title` and press `android:id/button1`.
  Both actions are MEASURED to work from the service:
  `ACTION_SET_TEXT` → true, and the field re-reads as the typed value;
  `ACTION_CLICK` on the Button → true, and the panel leaves.
  Nothing needs UI Automator, no new permission, no new service.
- The Android backend needs NO new JNI on the result side:
  `KayaPresent.emitFileDialogResult(dialog, uris, names)`
  (`KayaPresent.kt:67-71`) already carries exactly (one URI, one name),
  and `kaya_emit_file_dialog_result` (`capi.rs:1720`) mints the same
  `UriSource`. A saved document is a picked file with a different
  provenance.

### Honest size, in this repo's units

**A depth slice, not a milestone — for the Android arm.** The whole
Android cost is: one new apply-record branch beside
`APPLY_PRESENT_FILE_DIALOG` (`KayaCompose.kt:1273`), a
`kayaPresentSaveDialog` twin of `kayaPresentFileDialog`
(`KayaCompose.kt:2121-2171`, ~40 lines, same registry/launch/answer
shape), and one new harness verb arm (`KayaCompose.kt:4022`) calling two
accessibility actions. The read verbs, the result path, the source, the
open, and the write are all already there and all MEASURED working.

**The MILESTONE is everywhere else**, and the invariants make that
mandatory rather than optional:

- spec.rs is the root (invariant 7): a save is a new record or a new
  field on `show_file_dialog` (`spec.rs:829`, kind 34) — the record
  needs a suggested NAME, which the open request has no field for, and
  arguably a suggested type. Spec hash moves; header, bindings and
  guest surfaces regenerate in lockstep.
- The request surface must be swept across all 8 bindings (invariant
  2) — Go's `TxShowFileDialog` (`bindings/go/kaya_wire.go:560`) is
  generated, but the sugar (`bindings/go/app.go:1708`) is not.
- Four other backends: SwiftUI (`NSSavePanel` / `.fileExporter`),
  GTK (`FileChooserAction.SAVE`), WinUI (`FileSavePicker`), iOS
  (`UIDocumentPickerViewController(forExporting:)`) — one arm each,
  each with its own harness story. That is what made file dialogs a
  milestone the first time (docs/file-dialogs-plan.md §6a-§6e).
- A new scene (`tools/scenes/save.steps`) shared byte-for-byte by
  five platforms, plus the guest arms in 8 languages, plus
  check-verbs/check-steps/check-stubs updates.

Rough shape: **Android ≈ 1 depth slice (a day-ish); the feature ≈ 1
milestone**, the same size and shape as the file-dialog milestone that
landed §6a-§6e.

### Two design questions this measurement raises (for the maintainer)

1. **Save-as vs save.** `ACTION_CREATE_DOCUMENT` is "choose a
   destination and create"; overwriting a file the user picked earlier
   is the WRITE path in verdict A and needs no dialog at all. The
   editor needs both, and they are different vocabulary items.
2. **Collision policy is the platform's, not kaya's** (MEASURED:
   Android silently renames to `name (1).ext`; macOS asks "Replace?").
   The uniform semantics kaya can promise is "the result names the
   document you actually got, ask it for its name" — which is what the
   existing `PickedFile.name` already does.

---

## Cleanup (this arm)

- Probe app `dev.kaya.saveprobe` uninstalled from `emulator-5554`
  (uninstall drops its URI grants with it).
- `/sdcard/Documents/kaya-saveprobe/` removed from the device.
- `settings secure enabled_accessibility_services` restored to
  `dev.kaya.milestone2go/dev.kaya.KayaHarnessAccessibility`,
  `accessibility_enabled` restored to `1` (saved before the run in
  `scratchpad/a11y-before-5554.txt (gone)`).
- No emulator was booted, deleted or rebooted; all four standing
  instances are still up.
- The GUI lock was NOT taken: the emulators run `-no-window`
  (MEASURED from their command lines), so this arm put nothing on the
  user's screen, and an arm that does need the screen should not have
  been made to wait behind it. My first attempt DID wait on the lock,
  found it held by another arm for 7 minutes, and I killed the waiter
  rather than break someone else's lock at the 10-minute mark.
- Scratchpad: the probe's gradle tree (16 MB) is deleted; this arm's
  remaining footprint is 58.7 KB in 8 files (6 logs, this report, the
  saved a11y setting). The scratchpad as a whole is 175 MB, almost all
  of it other arms' and earlier sessions'.
- Processes: the emulator app is uninstalled (device `ps` shows no
  saveprobe process); on the host, the `KotlinCompileDaemon` my first
  build spawned (pid 32695, idle, 2 h auto-shutdown) was killed and
  `ps` confirms none remains. The Gradle daemon (pid 80812) predates
  this arm by ~2.5 h and was left alone.
- Repo: `git status --porcelain` is empty.
- MID-RUN INCIDENT worth telling the coordinator: every platform arm
  was given the SAME probe path (`scratchpad/saveprobe/ (gone)`). Mine was
  deleted out from under me mid-session by a sibling arm (the iOS and
  Windows arms show up as `saveprobe-ios/` and `saveprobe-windows/`).
  Only the build tree was lost — all six logs survived — and the last
  two measurements were re-taken in `saveprobe-android/`. Give arms
  distinct scratch paths.
