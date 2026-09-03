# SAVE PROBE — mac arm (SwiftUI backend + capi)

Repo HEAD `aeb135ab1825dc1da1256be8190ff8be25a08815`, clean. PROBE ARM: no
repo file changed; everything built and run out of the session scratchpad.
Every claim is tagged MEASURED / DOCUMENTED / ASSUMED.

Machine at probe time: macOS, Darwin 25.5.0. `NSNavPanelFileListModeForOpenMode2`
= 3 (icons); `NSNavPanelFileListModeForSaveMode2` and
`NSNavPanelExpandedStateForSaveMode` both **absent** from NSGlobalDomain —
MEASURED (`defaults read -g`), and re-read after the probes to confirm the
probe wrote none of them.

---

## VERDICTS

**(A) WRITE MODE TODAY = WORKS** on macOS, all the way to the bytes, for
the only thing it can be asked today (a picked file that already exists).
**With one measured hole that is exactly the save case:** the open never
passes `O_CREAT`, so a destination that does not exist yet fails ENOENT in
all three modes. Save-BACK works; save-AS cannot be expressed.

**(B) SAVE DIALOG = `NSSavePanel`**, which is the class `NSOpenPanel`
already inherits from, presented through the same `beginSheetModal(for:)`
call kaya already makes. It answers with ONE `URL` and creates nothing on
disk. Size: the mac arm is a **depth slice**; the feature across the repo
is a **milestone**.

---

## (A) WRITE MODE

### The path, end to end (macOS), all MEASURED by reading

1. `crates/kaya/src/wire.rs:219-221` — `FILE_MODE_READ=0`, `WRITE=1`,
   `READ_WRITE=2`.
2. `swift/KayaSwiftUI.swift:1666-1712` — the mac half of
   `kayaPresentFileDialog` is `NSOpenPanel`; on `.OK` it answers with
   `urls.map { $0.path }` as locators and `lastPathComponent` as names,
   through `KayaHost.api.emit_file_dialog_result`. THE LOCATOR IS A PLAIN
   POSIX PATH on this platform.
3. `crates/kaya/src/capi.rs:1613-1632` — `kaya_emit_file_dialog_result`
   → `register_picked`.
4. `crates/kaya/src/capi.rs:1577-1577` — the `#[cfg(not(any(android,
   ios)))]` arm builds `protocol::PathSource { name, path }`. **macOS takes
   this arm**: no `UrlSource`, no `kaya_swiftui_open_picked` round trip, no
   security scope. (`swiftui_host.rs:41-90` and `protocol.rs:205`
   `picked_mode_code` are both cfg'd to iOS.)
5. `crates/kaya/src/capi.rs:1332-1367` — `kaya_open_picked` maps the u32 to
   `FileMode` (anything else → EINVAL 22), resolves under the lock,
   releases, then opens.
6. `crates/kaya/src/protocol.rs:224-241` — `PathSource::open`:
   `Read → read(true)`, `Write → write(true).truncate(true)`,
   `ReadWrite → read(true).write(true)`; `seekable = metadata().is_file()`;
   `into_raw_fd` transfers ownership.

So on macOS "write mode" is entirely `std::fs::OpenOptions` against a path
the user just chose in a real NSOpenPanel. That is why `FILE_MODE_WRITE`
appears zero times in `KayaSwiftUI.swift`: **the mac backend never sees the
mode.** It hands over a path; the core does the open. Nothing is missing
from the backend.

Two corrections to the brief, both MEASURED:

- `capi.rs:1482` — the existing unit test already redeems the same handle a
  second time with `FILE_MODE_READ_WRITE` and asserts rc 0. What is true is
  narrower: **nothing ever writes through the descriptor**, and no scene,
  leg or guest asks for a non-read mode.
- No sandbox is in play. The mac guests are bundle-less command-line
  binaries run from a terminal under `.accessory` policy
  (`tools/validate-mac.py:89-98` stages them), so App Sandbox — which is opt-in via
  the `com.apple.security.app-sandbox` entitlement (DOCUMENTED:
  https://developer.apple.com/documentation/security/app-sandbox) — is off,
  and the powerbox grant that would otherwise decide writability never
  applies. A path is a path.

DESIGN.md already commits to this working: line 1337, "SAVE-BACK NEEDS NO
SPECIAL MACHINERY … the document the user opened can be opened `O_RDWR`
through the ordinary handle, the write lands"; lines 1085-1092 record iOS
measurements 6 and 7 (the OPEN picker grants write, measured on device).
DOCUMENTED. The mac arm was never measured, and no leg drives it.

### THE DRIVE — MEASURED, end to end

A throwaway copy of `guests/python/filedialog.py` with one change: the
worker opens the picked handle for `FILE_MODE_READ_WRITE` and then
`FILE_MODE_WRITE` instead of `FILE_MODE_READ`, writes through both, and
puts what the file on disk says afterwards into the status label. Real
NSOpenPanel, real AX selection of `picked.txt` over the decoy, real thread
hop — the shipped path unchanged, driven by the shipped harness.

```
KAYA_HARNESS: +0ms    expect label#0 "no file"
KAYA_HARNESS: +30ms   file_dialog_goto $TMP/kaya-picked-$PID
KAYA_HARNESS: +31ms   click button#0
KAYA_HARNESS: +31ms   expect_file_dialog kaya-picked-$PID decoy.txt picked.txt
KAYA_HARNESS: +673ms  file_choose picked.txt
KAYA_HARNESS: +1059ms expect label#0 "reading"
KAYA_HARNESS: +1059ms click button#2
KAYA_HARNESS: +1059ms expect label#0 "rw seek 1 RWcked bytes then w seek 1 W"
KAYA_SELFTEST: OK (no file, file dialog "kaya-picked-32184" ["decoy.txt",
  "picked.txt"], reading, rw seek 1 RWcked bytes then w seek 1 W)
```

The label is the file's bytes read back with ordinary Python after each
write, so the assertion is the disk:

| mode | asked | descriptor | disk after |
|---|---|---|---|
| `FILE_MODE_READ_WRITE` (2) | read all, `seek(0)`, write `b"RW"` | opened, `seekable=1` | `RWcked bytes` — **positioned write, no truncation** |
| `FILE_MODE_WRITE` (1) | write `b"W"` | opened, `seekable=1` | `W` — **truncated, as `truncate(true)` says** |

A working fd, not an error and not a read-only fd that fails on first
write. The two modes are also *distinguishable* on disk, which is what
rules out "it silently did the same thing twice".

### THE HOLE: the open never creates — MEASURED

`PathSource::open` builds its `OpenOptions` with no `.create(true)` on any
arm. Against a path that does not exist yet — which is precisely what a
save panel hands back — a standalone Rust probe running `protocol.rs`'s
exact option sets says:

```
PROBE MISSING  mode=0 ERR errno=Some(2) No such file or directory
PROBE MISSING  mode=1 ERR errno=Some(2) No such file or directory
PROBE MISSING  mode=2 ERR errno=Some(2) No such file or directory
PROBE EXISTING mode=0 OK seekable=true
PROBE EXISTING mode=1 OK seekable=true
PROBE EXISTING mode=2 OK seekable=true
PROBE missing-exists-after=false
```

So the moment a save dialog exists and registers its destination as a
`PathSource`, `kaya_open_picked` refuses it with errno 2 and the guest sees
"No such file or directory" for a file the user just named. The fix is a
decision, not a line: either `Write`/`ReadWrite` gain `.create(true)`
(which changes the semantics of the OPEN picker's modes too — today
`Write` on a picked file that vanished between pick and open fails, and
with `create` it would silently make a new one), or the save result
registers a source type whose `open` creates. It has to be answered the
same way in all four backends: Android's SAF path already creates at the
`ACTION_CREATE_DOCUMENT` step, WinUI's `FileSavePicker` returns a
`StorageFile` that **exists**, and only the two path platforms (macOS,
GTK) hand back a name for a file nobody has made. That asymmetry is where
the uniform-semantics work is.

---

## (B) SAVE DIALOG

### The API

`NSSavePanel` — and `NSOpenPanel` is a **subclass of `NSSavePanel`**
(DOCUMENTED: https://developer.apple.com/documentation/appkit/nssavepanel,
https://developer.apple.com/documentation/appkit/nsopenpanel). So this is
not a parallel mechanism: kaya's `kayaLiveOpenPanel: NSOpenPanel?` slot and
its whole presentation block already operate on a save panel; widening the
slot's type to `NSSavePanel?` covers both, and `canChooseFiles` /
`allowsMultipleSelection` are the two lines that are open-only.

Presentation is the identical call kaya already makes at
`swift/KayaSwiftUI.swift:1711-1717`:

```swift
panel.beginSheetModal(for: host) { response in ... }   // .begin { } with no host
```

Configuration that matters, all present on the class (DOCUMENTED, and
`directoryURL` / `nameFieldStringValue` / `allowedContentTypes` /
`canCreateDirectories` exercised by the probe): `directoryURL` (the same
`file_dialog_goto` arming already works — see below), `nameFieldStringValue`
(the suggested filename), `nameFieldLabel`, `allowedContentTypes` (the same
advisory filters), `canCreateDirectories`, `isExtensionHidden`,
`showsTagField`, `prompt`, `message`. `isExpanded` is READ-ONLY.

### What it answers with — MEASURED

| | NSOpenPanel (today) | NSSavePanel (measured) |
|---|---|---|
| answer | `panel.urls` — a LIST | `panel.url` — exactly ONE, or nil |
| cancel | `response != .OK`, empty list | `response == 0`, `url` nil |
| does the file exist afterwards? | yes, the user picked it | **NO** — `exists=false` after a clean Save |
| existing file + Replace | n/a | file **untouched**: still `"OLD BYTES"` |

Probe log lines:

```
completion response=1 (.OK=1) url=…/kaya-savepanel-probe-33140/probe-ax.txt
round1 path=…/probe-ax.txt exists=false bytes="<none>"
round2 (did the panel touch the file?) path=…/exists.txt exists=true bytes="OLD BYTES"
round3 response=0 url=<nil>
```

**The panel neither creates nor truncates.** "Replace" is the user's
consent and nothing more (DOCUMENTED agrees: the panel returns a location,
the app writes). This is what makes the `O_CREAT` hole above load-bearing
rather than theoretical: on macOS the ONLY thing that will ever create the
saved file is kaya's own open.

**A path trap, MEASURED.** For a name that did not exist, `panel.url` came
back `/var/folders/9h/…/probe-ax.txt`; for a name that did, it came back
`/private/var/folders/9h/…/exists.txt` — the same directory, canonicalized
through the `/var → /private/var` symlink. A leg (or a guest) that compares
the returned locator against a path it computed itself will match one and
not the other. The `filedialog` scene never met this because it compares
the *basename* and the "where" popup's *suffix*; a save scene that asserts
on a full path would be a flake generator.

### The accessibility tree — MEASURED (this is the harness story)

Collapsed (the DEFAULT — `panel.isExpanded=false`,
`NSNavPanelExpandedStateForSaveMode` absent):

```
AXSheet id=save-panel  desc="save"
  AXSplitGroup
    AXStaticText     id=whereLabel                        value="Where:"
    AXPopUpButton    id=where popup                       value="<the directory>"
    AXDisclosureTriangle id=NS_OPEN_SAVE_DISCLOSURE_TRIANGLE desc="show more options"
    AXStaticText     id=nameFieldLabel                    value="Save As:"
    AXTextField      id=saveAsNameTextField               value="probe-new"
    AXStaticText     id=tagsLabel                         value="Tags:"
    AXTextField      id=_NS:8                             desc="tag editor"
    AXButton         id=CancelButton                      title="Cancel"
    AXButton         id=OKButton                          title="Save"
```

Four facts to build on:

1. **The sheet identifier is `save-panel`**, where the open panel's is
   `open-panel` (`swift/KayaSwiftUI.swift:1293`). One more constant, same
   `kayaPanelFind` walk.
2. **`OKButton`, `CancelButton` and `where popup` are the SAME identifiers
   the open reader already uses** (`kayaPanelOkId`, `kayaPanelCancelId`,
   `kayaPanelWhereId`, lines 1489-1491). The press machinery, the
   `kAXErrorCannotComplete`-is-not-a-failure rule, and the "where" read
   port over unchanged.
3. **The filename field is `saveAsNameTextField`**, and it is DRIVEABLE:
   setting `kAXValueAttribute` returned err 0, the element read back
   `"probe-ax.txt"`, `panel.nameFieldStringValue` agreed, and the URL the
   completion delivered was `…/probe-ax.txt`. So the harness can type the
   name the way a user would and prove it took — three independent reads.
   Note the field's value is the STEM when the extension matches
   `allowedContentTypes` (`"probe-new"`, not `"probe-new.txt"`), so an
   assertion on it must not assume the extension is there.
4. **THERE IS NO FILE BROWSER AT ALL.** Collapsed is the default, and the
   collapsed panel publishes no `ListView`/`IconView`/`ColumnView` — the
   `KayaPanelShape` reader finds nothing and `kayaOpenPanelState` would
   return nil forever.

Expanded (pressed the disclosure triangle, the human route —
`isExpanded` went false → true):

```
AXSheet id=save-panel
  AXSplitGroup
    AXScrollArea _NS:61 → AXOutline _NS:8 desc="sidebar"
    AXBrowser    id=ColumnView  desc="column view"      ← the SAME three shapes
    AXMenuButton id=View Options
    AXMenuButton id=Group or Sort By
    AXPopUpButton id=where popup     value="<the directory>"
    AXDisclosureTriangle NS_OPEN_SAVE_DISCLOSURE_TRIANGLE desc="show less options"
    AXTextField/AXSearchField id=Search
    AXStaticText id=nameFieldLabel   value="Save As:"
    AXTextField  id=saveAsNameTextField value="expanded-probe.txt"
    AXButton     id=NewFolderButton  title="New Folder"
    AXButton     id=CancelButton / AXButton id=OKButton
```

`saveAsNameTextField` survives expansion with the same identifier and is
still settable (err 0, panel agrees). The browser that appears carries the
**same view-mode identifiers the open panel uses** — here `ColumnView`.

**This is the 2026-08-06 trap with a worse default.** The open panel's
shape is decided by a machine-wide preference; the save panel's *existence
of a browser at all* is decided by another one
(`NSNavPanelExpandedStateForSaveMode`), and the box this ran on has it
unset. A reader written on a developer's box where someone once expanded a
save panel would require rows and hang on a fresh machine; a reader written
here would break the day someone expands one. The rule the save reader
needs, stated once: **rows are optional on a save panel, and when they are
there they are `KayaPanelShape` again.** `kayaAwaitOpenPanelState`'s
`requireRows` flag already has exactly this distinction built in
(lines 1800-1812) — the save side must always pass `false`.

### The overwrite prompt — MEASURED

Pressing Save on a name that exists does NOT complete. A **second
`AXSheet`, sibling of the save panel and carrying NO identifier**, appears:

```
AXSheet id=-
  AXImage      id=_NS:35  desc="com.apple.appkit.xpc.openAndSavePanelService critical alert"
  AXStaticText id=_NS:74  value="“exists.txt” already exists. Do you want to replace it?"
  AXStaticText id=_NS:58  value="A file or folder with the same name already exists in the
                                 folder “…”. Replacing it will overwrite its current contents."
  AXButton     id=action-button-2  title="Cancel"
  AXButton     id=action-button-1  title="Replace"
```

The completion handler fired only after `action-button-1` was pressed, with
`response=1` and the canonicalized URL. Notes a leg must encode:

- The buttons have STABLE IDENTIFIERS (`action-button-1` = the destructive
  default, `action-button-2` = Cancel) and LOCALIZED titles. Drive by
  identifier; the repo's existing alert reader has the same choice to make.
- The prompt's sheet has no identifier, so it is found as "the AXSheet that
  is not `save-panel`", not by name.
- `kayaLiveOpenPanel != nil` is still true while the prompt is up, and the
  panel's own tree is still fully readable underneath it — so a
  state-reading verb must not treat "panel still live" as "the press was
  swallowed" (that is exactly what `file_choose`'s postcondition poll does
  today, `harness.rs:2124-2140`). The save verb's postcondition is "the
  panel is gone OR the replace prompt is up", and the two are different
  steps.

### What a HARNESS LEG must do

A save scene is the `filedialog` scene's shape with two extra obligations,
and both are the same class of obligation as the existing decoy file: they
make a wrong implementation fail rather than pass quietly.

1. **Name the file, and prove the name took.** New action verb in
   `set_text`'s tier — `file_dialog_name <name>` — writing
   `saveAsNameTextField`, plus a reader that puts the name field into the
   state so an assertion can read it back. The observation verb
   `expect_save_dialog <dir> <name>` reads BOTH the "where" popup and the
   name field. Without the read-back, a backend that silently ignored the
   name would save under the SUGGESTED name and every downstream assertion
   about the bytes would still pass — the exact `file_choose` failure mode
   that the row-listing guard exists to catch.
2. **Save over an existing file at least once.** The prompt path is a
   different code path in the backend (a second sheet, a second press) and
   a scene that only ever writes new names never exercises it. This is the
   decoy rule again: `tools/scenes/filedialog.steps` needed a second file
   before `file_choose` could fail; a save scene needs a second SAVE — one
   to a fresh name (completion fires immediately, no prompt) and one over
   an existing name (prompt, `file_replace` / `file_save replace`), plus a
   cancel. Three legs of grammar, and the assertion in every one is the
   BYTES ON DISK read back by the guest, never "a dialog closed".
3. **Never require rows.** See the expanded/collapsed measurement above.
4. **Assert the basename, never the full path.** See the
   `/var` vs `/private/var` measurement.

Where it goes, all four layers, because this is the historic miss layer:
`swift/KayaSwiftUI.swift` (constants, panel reader, drive function,
step-verb arm) and `android/.../KayaCompose.kt (gone)` (the same four), plus the
`Stage` trait in `crates/kaya/src/harness.rs` (`file_dialog_state`,
`choose_file`, `goto_directory` today — MEASURED: three methods, no
defaults, implemented in `gtk.rs` and `winui/mod.rs`) and both Rust-native
backends. `tools/check-verbs.py` will hold both interpreters to the new
verbs; `tools/check-steps.py` will hold the scene to them.

### Honest size

**The mac arm alone is a DEPTH SLICE**: widen `kayaLiveOpenPanel` to
`NSSavePanel?`, add the `save-panel` sheet id, a `kayaSavePanelState` that
reads the where popup and the name field and tolerates a missing browser, a
`kayaSavePanelDrive(name:replace:)`, the presentation arm, one spec record
(or a mode field on `show_file_dialog`), the `capi` result path, the Rust
binding, a scene and its steps. Everything it needs from the platform is
measured above; there is no unknown left on this platform.

**The feature is a MILESTONE.** The count, from the repo as it stands:
one spec change and its regeneration (`spec.rs` is the root, so wire + C
header + all generated surfaces move in lockstep), 4 backends (SwiftUI
mac + iOS's `UIDocumentPickerViewController(forExporting:)`, GTK's
`GtkFileDialog.save`, WinUI's `FileSavePicker`, Compose's
`ACTION_CREATE_DOCUMENT`), 8 bindings (MEASURED: 7 binding files mention
the picker — `bindings/{csharp, go, haskell, java, ocaml, python, swift}` — plus
Rust in `crates/kaya/src/app.rs`) and the C floor, 6 guests today for
`filedialog` plus the two missing (C, C#/Java share) for the new scene, the
harness verbs in both interpreters and three `Stage` impls, and the gate
sweep (`check-verbs`, `check-steps`, `check-sugar-surface`,
`check-stubs`). The one genuinely undecided thing is not mac-shaped: it is
the `O_CREAT` question above, where two platforms hand back a name for a
file that does not exist and two hand back an object for one that does.
DESIGN.md's deferral (line 1347: "SAVE is designed alongside but comes
second, because creating a document through SAF is a different request …
and the error surface is the real work") named that correctly.

---

## Probe artifacts

- `saveprobe/probe_write.py` + `probe_write.steps` — the (A) drive. NOTE:
  this file was overwritten mid-session by a concurrent arm sharing the
  scratchpad; the run above completed before that and its transcript is
  quoted verbatim here.
- `saveprobe/probe_mac_savepanel.swift` + `savepanel.log` — (B) rounds 1-3.
- `saveprobe/probe_mac_savepanel_expanded.swift` + `savepanel-expanded.log`
  — (B) the expanded panel.
- `saveprobe/probe_mac_create.rs` — the `O_CREAT` measurement.

## Cleanup — MEASURED

**Processes.** Three GUI processes were started (one python guest under the
SwiftUI interpreter, two standalone Swift probes); all three exited on
their own and the listing is empty:

```
$ ps -Ao pid,etime,pcpu,command | grep -Ei "probe_mac_savepanel|probe_write|saveprobe|filedialog" | grep -v grep
NONE
```

The three long-running processes at the top of `ps` sorted by CPU (the
android emulator at 13 days etime, the UTM/QEMU Windows VM at 5 days,
Firefox at 7 days) all predate this session by days and are not this
arm's.

**Windows.** No window is up: each probe either cancelled its panel and
called `exit(0)`, or ran the harness leg to a verdict, which closes the
guest. Verified by the empty process list above — a live panel needs a
live process.

**Machine state.** `defaults read -g` for
`NSNavPanelFileListModeForOpenMode2` (3), `NSNavPanelFileListModeForSaveMode2`
(absent) and `NSNavPanelExpandedStateForSaveMode` (absent) read the same
after the probes as before. The expanded-panel probe pressed the
disclosure triangle and pressed it back, and its own defaults domain wrote
no plist (`~/Library/Preferences` has no `probe_mac_savepanel*.plist`).
The one file macOS did touch is
`~/Library/Preferences/com.apple.appkit.xpc.openAndSavePanelService.plist`,
which the panel service rewrites for any app that presents a panel — the
existing mac legs do the same thing on every run; it carries no probe key
and was left alone.

**Disk.** Probe temp directories deleted:
`$TMPDIR/kaya-savepanel-probe-33140`, `$TMPDIR/kaya-savepanel-exp-33676`,
`$TMPDIR/kaya-picked-32184` — `ls` after the delete finds none. (Older
`kaya-picked-*` directories in `$TMPDIR` are earlier validate-mac runs'
leftovers, not this arm's, and were left alone.) The three compiled probe
binaries and the `createdir` fixture are deleted. **This arm's remaining
artifacts total 40K** — three probe sources, two AX logs, one steps file,
kept as the evidence behind the measurements.

`scratchpad/saveprobe/ (gone)` itself measures 180M, but it is SHARED with
concurrent platform arms and 180M of it is theirs: `target/` 163M (another
arm's cargo build) and `app/` 17M (another arm's gradle build). Same
sharing overwrote `saveprobe/probe_write.py` mid-session. The scratchpad
root is 256M.

**Repo.** `git status --porcelain` empty, HEAD still
`aeb135ab1825dc1da1256be8190ff8be25a08815`; `target/debug/libkaya.dylib`
and `target/swiftui/libkaya_swiftui.dylib` both still stamped Aug 9 18:50,
i.e. nothing in this arm rebuilt or replaced a repo artifact.
