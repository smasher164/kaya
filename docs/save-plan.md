# Saving a file — the design pass

The editor's last prerequisite. Probe reports (2026-08-09, five arms,
every claim tagged measured/documented/assumed):
scratchpad/save-probe-{mac,ios,linux,windows,android}.md.

## §0 — what the probes found

**Write mode is implemented everywhere, and has never been exercised
anywhere.** The coordinator's "FILE_MODE_WRITE appears zero times in
any backend" was an artifact of grepping a name only Rust uses: mac and
windows hand back plain paths and never see the mode (the core opens
them through `OpenOptions`), while iOS and Android forward it to
platform openers that match on the NUMBERS. Two arms drove it end to
end and watched bytes land. But no guest, scene, leg or test passes
anything but READ — and the one unit test is gated `cfg(all(test,
unix))`, so Windows has never executed it.

**The hole is exactly the save case.** No open arm passes `create`:
opening a path that does not exist fails with errno 2 (ERROR_FILE_NOT_
FOUND on Windows) in EVERY mode, measured on mac and windows. And a
desktop save panel ANSWERS WITH A PATH THAT DOES NOT EXIST — measured
on mac: `exists=false` after a clean Save, and pressing Replace does
not truncate either. So today a save destination cannot be opened at
all. Writing to an ALREADY-PICKED file works; saving does not.

**Three defects found on the way, none of them about saving:**
1. **Java's handle is read-only in every mode, on every platform** —
   `bindings/java/dev/kaya/KayaApp.java:581-589` returns a
   `FileInputStream` for write and read-write alike. A Java app cannot
   write to a picked file anywhere.
2. **The Swift backend matches mode NUMBERS as bare literals**
   (`swift/KayaSwiftUI.swift:2195-2201`) while Rust pins them by test,
   with nothing checking the two agree. Renumbering a mode silently
   opens files the wrong way on Apple platforms.
3. **The only test of `kaya_open_picked` is unix-gated** and passes
   READ, so the API's write half is untested everywhere and unrun on
   Windows.

**The save dialog per platform** (all measured against the open
picker's existing machinery):
| backend | API | answers with | harness story |
|---|---|---|---|
| mac | `NSSavePanel` (the class `NSOpenPanel` already inherits) | ONE URL, file not created | AX ids identical to the open panel; the filename field `saveAsNameTextField` is AX-settable, verified |
| iOS | `UIDocumentPickerViewController` export/create | a URL to a created file | **BLOCKED: simdrive has six verbs and none enters text** |
| linux | GTK4 `FileDialog` save | one path, not created | the AT-SPI path the open picker already uses |
| windows | `IFileSaveDialog` (NOT `FileSavePicker` — its start location is an enum, it needs an owner HWND unpackaged) | a path that does not exist | the UIA machinery deploy-win already drives |
| android | `ACTION_CREATE_DOCUMENT` | a content locator to a CREATED document | the existing picker legs |

## §1 — the decisions (RATIFIED by the maintainer, 2026-08-09, as a set)

### D1 — a save destination is openable, and the platforms' disagreement is absorbed by the core

Uniform semantics: **after a save dialog, opening the result for write
succeeds and yields an EMPTY file**, on all five. The platforms
disagree underneath — Android and iOS hand back a document that already
exists, mac/linux/windows hand back a path to nothing — so the core's
source for a save result opens with create-and-truncate rather than
plain write. The guest sees one behaviour.

REJECTED: a new `FILE_MODE_CREATE`. Creation is a property of the
DESTINATION (the dialog promised it), not of the caller's intent, and a
fourth mode would let a guest ask for creation on a file it merely
opened — which is how "save" quietly becomes "clobber".

### D2 — one new request record, mirroring the open picker

`show_save_dialog { window, dialog, suggested_name, filters }`,
answering on the same request/result grammar as the open dialog (the
alert precedent), with ONE locator. Same one-live-dialog-per-process
rule; same guest-chosen ids.

### D3 — the three found defects are fixed in this milestone, not ledgered

They are all in the path the editor is about to walk: Java's handle
(a defect for every language user of write mode), the Swift literals
(a gate: the interpreter's mode numbers must be checked against the
spec's, watched failing), and the unix-gated test (unlock it, and pass
WRITE somewhere a lane runs).

### D4 — iOS's driver gains a text-entry verb

A save panel's whole point is typing a name, and simdrive cannot type.
The verb is added to the host-side driver, not worked around in the
scene — a scene that avoided typing would assert a save dialog nobody
could name a file in.

### D5 — the scene proves the round trip, not the dialog

`save.steps`: open a file, edit it, save it back (the already-picked
path — which works today and has NEVER been tested), then Save-As to a
new destination, and reopen the result to prove the bytes are there.
Byte-frozen strings; the C floor spells it explicitly.

## §2 — sequencing

Depth: the spec record + the core's create-capable save source + the
Rust surface + the mac arm + the scene, green on mac. Breadth: the
four other backends, the seven other bindings (Java's fix rides here),
the two gates, the iOS driver verb. Then the matrix.

## §3 — deliberately not designed

- No file-system API for guests. kaya hands back a handle for a file
  the USER chose; it is not becoming a filesystem library.
- No bookmark/persistence machinery (reopening a file across restarts
  without re-picking). Real on iOS and Android, wanted by an editor's
  "recent files", and out of scope here — ledger it.
- No directory picker.
