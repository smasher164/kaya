# Save probe — WINDOWS arm (kaya @ aeb135a)

Tags: **MEASURED** = I ran it and read the output; **DOCUMENTED** = a
vendor page or a repo line I read, cited; **ASSUMED** = inference, and no
verdict rests on one.

Platform: Windows 11 26200.8875 on aarch64 (the lane VM, 192.168.64.2),
non-packaged win32 process, `/it /rl highest` scheduled task — the same
runner the windows lane uses.

Probe: `saveprobe.exe`, a standalone crate cross-compiled with
`cargo xwin --target aarch64-pc-windows-msvc`, modelled on
`tools/win/dialogprobe`. Raw logs quoted inline; artifacts deleted (see
Cleanup).

---

## VERDICT A — WRITE MODE TODAY = **WORKS in the core and in 3 of the 5
## languages this lane carries; BROKEN BY CONSTRUCTION in Java; NEVER
## EXERCISED anywhere.**

### A.1 The path, end to end (MEASURED by reading, file:line)

- `wire.rs:225-227` FILE_MODE_READ=0 / WRITE=1 / READ_WRITE=2, mirrored
  in all 8 bindings and `include/kaya.h:414-418`.
- `capi.rs:1403-1435` `kaya_open_picked` decodes the three modes
  (1419-1424), EINVAL otherwise, then `source.open(mode)`.
- `winui/mod.rs:2785-2800` the Windows backend registers
  `protocol::PathSource { name, path }` for every picked file — there is
  **no Windows-specific open at all**; it is the same generic path
  opener GTK uses (`gtk.rs:3406`, `gtk.rs:4622`).
- `protocol.rs:230-244` `PathSource::open`: Read → `read(true)`;
  Write → `write(true).truncate(true)`; ReadWrite → `read(true).write(true)`;
  then `raw_handle(file)`.
- `protocol.rs:179-183` on Windows that is `file.into_raw_handle() as i64`
  — a **Win32 HANDLE**, deliberately not a CRT fd (the reasoning is at
  `protocol.rs:115-126` and DESIGN.md:1176-1184).

### A.2 The three modes, driven on the VM (MEASURED)

The probe transcribes `PathSource::open` and `file_from_raw` line for
line, then writes through the rebuilt `File`:

```
A existing READ:       open OK handle=0x198 seekable=true
A existing READ:       read "picked bytes"
A existing READ:       WRITE FAILED Access is denied. (os error 5)
A existing READ:       file is now 12 bytes "picked bytes"
A existing READ_WRITE: open OK handle=0x19c seekable=true
A existing READ_WRITE: read "picked bytes"
A existing READ_WRITE: write OK
A existing READ_WRITE: file is now 12 bytes "WROTEd bytes"
A existing WRITE:      open OK handle=0x198 seekable=true
A existing WRITE:      write OK
A existing WRITE:      file is now 5 bytes "WROTE"
```

So: WRITE opens, truncates and writes; READ_WRITE reads then overwrites
in place without truncating; READ refuses the write with ERROR_ACCESS_DENIED.
That is exactly the POSIX semantics the other desktops give, including
the truncation rule `android_open_mode`'s `wt` exists to preserve
(`protocol.rs:185-197`).

Refusals (MEASURED):

```
A missing  WRITE: OPEN FAILED raw_os_error=Some(2) kind=NotFound
A missing: exists afterwards = false
A readonly WRITE: OPEN FAILED raw_os_error=Some(5) kind=PermissionDenied
A readonly READ_WRITE: OPEN FAILED raw_os_error=Some(5)
A directory WRITE: OPEN FAILED raw_os_error=Some(5)
```

**WRITE mode cannot create a file.** Rust maps `write+truncate` without
`create` to `TRUNCATE_EXISTING`, so a path that does not exist fails
ERROR_FILE_NOT_FOUND and nothing is created — uniform with POSIX
`O_WRONLY|O_TRUNC` and therefore *correct*, but it means the mode set as
it stands **cannot serve a save-as**, which is the whole point of (B).

### A.3 The guest side: does each runtime accept a write HANDLE?

The windows lane carries five languages for `filedialog`
(`deploy-win.sh:1433-1441`: rust, python, go, csharp, java).

Driven on the VM against a real GENERIC_WRITE / TRUNCATE_EXISTING handle,
using each binding's own conversion line (MEASURED):

```
GO raw HANDLE = 0x158            # bindings/go/runtime.go:323
GO Write -> n=5 err=<nil>          os.NewFile(uintptr(raw), name)
GO file is now 5 bytes "WROTE"
PY raw HANDLE = 0x1c0            # bindings/python/kaya/runtime.py:192-199
PY open_osfhandle -> 3             msvcrt.open_osfhandle(raw, O_RDWR)
PY write -> 5                      os.fdopen(fd, "wb")
PY file is now b'WROTE'
```

- **Rust** — `File`; measured above. ✅
- **Go** — measured. ✅ (the editor's language)
- **Python** — measured. ✅
- **C#** — `Kaya.cs:262-269` picks `FileAccess.Read/Write/ReadWrite` by
  mode and hands the raw handle to `SafeFileHandle(ownsHandle: true)`.
  Correct by construction; **not driven** — code-level verdict only.
- **Java** — `KayaApp.java:581-589`:
  ```java
  public Opened open(int mode) throws java.io.IOException {
      java.io.FileDescriptor fd = KayaRing.openPicked(handle, mode, seekable);
      return new Opened(new java.io.FileInputStream(fd), seekable[0] != 0);
  }
  public record Opened(java.io.FileInputStream stream, boolean seekable) {}
  ```
  **A `FileInputStream`, whatever the mode.** Ask for FILE_MODE_WRITE in
  Java and you get a write-only OS handle wrapped in a read-only stream:
  you cannot write, and reading will fail at the OS with ERROR_ACCESS_DENIED.
  This is a *type-level* defect, visible without running anything, and it
  is **not Windows-specific** — Java is broken this way on every
  platform. The JNI half is fine (`jvm.rs:248-298` sets the `handle`
  long field on Windows, the `fd` int elsewhere); only the Java wrapper
  is wrong.

  Sweeping the other three languages the windows lane does not carry:
  Swift returns `FileHandle` ✅, OCaml a `Unix.file_descr` ✅, Haskell a
  `Handle` from `fdToHandle` ✅ — all writable, all POSIX-only anyway.
  So the sweep verdict is **7 do / 1 (Java) can't-as-written**.

### A.4 Two smaller findings

1. **The EINVAL fallback is a nonsense error on Windows.** `capi.rs:1437-1440`
   returns 22 for a bad handle or a bad mode, commented "EINVAL without
   pulling in libc: the value is stable across every platform kaya
   targets". Windows `raw_os_error`s are Win32 codes, not errnos.
   MEASURED on the VM:
   ```
   A errno22: from_raw_os_error(22) = Uncategorized /
              The device does not recognize the command. (os error 22)
   ```
   Rust, Python and .NET all turn rc into the platform's error, so a
   guest that names a dead handle is told the device does not recognize
   the command. The right value here is ERROR_INVALID_PARAMETER (87) on
   Windows / 22 elsewhere.

2. **Nothing has ever run this.** `capi.rs:1443` gates the only test of
   `kaya_open_picked` behind `#[cfg(all(test, unix))]`, so **the Windows
   lane's `cargo test` has never executed it at all** — and even on unix
   the two calls pass READ (1467) and READ_WRITE (1482). FILE_MODE_WRITE
   is passed to `kaya_open_picked` by no test, no guest, no scene and no
   leg on any platform: `guests/*/filedialog.*` and `guests/*/clipboard.*`
   all pass the read constant, and `FILE_MODE_WRITE` appears zero times
   in gtk.rs, winui/mod.rs, KayaSwiftUI.swift and KayaCompose.kt.

**Verdict A, stated plainly:** on Windows the write path *works* — the
core opens, truncates, writes, refuses read-only files with the
platform's own error, and hands back a HANDLE that Go, Python and Rust
all write through. It is unimplemented only in the sense that **no
artifact has ever asked for it**, and one binding (Java) could not use it
if it did. It is not broken and not partial in the core.

---

## VERDICT B — SAVE DIALOG = **`IFileSaveDialog`, not `FileSavePicker`.
## It answers with a PATH TO A FILE THAT DOES NOT EXIST. The Windows arm
## is a depth slice (~100 lines, every call measured working); the
## FEATURE is a milestone, and the expensive part is not Windows.**

### B.1 Which API — measured and documented

**`IFileSaveDialog`** (CLSID_FileSaveDialog `c0b4e2f3-…`), the Shell's
common item dialog, sibling of the `IFileOpenDialog` the backend already
drives at `winui/mod.rs:2464-2592`.

Measured working on the VM, in the same sequence and the same one-STA
apartment shape the open arm uses (`winui/mod.rs:2736`):

```
CoCreateInstance(FileSaveDialog) → GetOptions/SetOptions(|FOS_FORCEFILESYSTEM)
→ SetFileTypes(COMDLG_FILTERSPEC[]) → SetDefaultExtension("txt")
→ SetFileName("untitled.txt") → SHCreateItemFromParsingName + SetFolder
→ Show(None) → GetResult() → GetDisplayName(SIGDN_FILESYSPATH)
```

```
B-new  #32770 title="Save As"
B-new  typed "fresh.txt" into the Edit at id=1001
B-new  pressing id=1 text="&Save"
B-new  RESULT OK path="C:\kaya\saveprobe-dir\fresh.txt"
              exists_after_show=false size=Err(NotFound)
B-cancel RESULT ERR at Show hresult=0x800704c7 (ERROR_CANCELLED)
B-noext typed "bare"  → RESULT OK path="…\bare.txt"   (SetDefaultExtension works)
```

**Why not the WinRT `FileSavePicker`** — four charges, three measured:

1. **The start location is an enum.** MEASURED: `SetSuggestedStartLocation`
   takes `PickerLocationId`, a list of well-known folders; it cannot be
   aimed at `<temp>/kaya-picked-<pid>`. This is the *same* charge
   `winui/mod.rs:6067-6073` already records against `FileOpenPicker`, and
   it alone decides it — the filedialog scene aims the dialog at a
   directory it just made.
2. **A non-packaged desktop app must hand it an owner window.** DOCUMENTED,
   vendor: "In a desktop app, before using an instance of this class in a
   way that displays UI, you'll need to associate the object with its
   owner's window handle."
   (https://learn.microsoft.com/en-us/uwp/api/windows.storage.pickers.filesavepicker)
3. **It does not work elevated.** DOCUMENTED, same page: "The file and
   folder picker APIs (Windows.Storage.Pickers) in the Windows SDK don't
   work when apps run as administrator (elevated mode)." Every lane leg
   runs `schtasks … /rl highest` (`deploy-win.sh:993`), i.e. elevated.
4. It is async (`IAsyncOperation`), so it wants a pump on the STA rather
   than the blocking modal `Show()` the apartment thread already runs.

MEASURED, as a bonus: activation itself is fine non-packaged
(`RoActivateInstance` succeeds), and `PickSaveFileAsync` refuses first on
a different ground — `0x80004005 "The FileTypeFilters property must have
at least one file type filter specified."`, which matches the vendor
page's "Important" note.

And Microsoft's own documented remedy for a desktop app is the API this
verdict picks: the FileSavePicker page's elevated-app workaround is
literally `CoCreateInstance(FileSaveDialog) → SetFileTypes → SetFolder →
SetFileName → SetDefaultExtension → Show(hWnd) → GetResult →
GetDisplayName(SIGDN_FILESYSPATH)`.

### B.2 What it answers with — and the design question that follows

MEASURED, three runs, three names: **`exists_after_show=false` every
time.** `IFileSaveDialog` returns an `IShellItem` whose
`SIGDN_FILESYSPATH` is the chosen path, and it **does not create the
file**. (DOCUMENTED corroboration: `FOS_NOTESTFILECREATE` exists to turn
off a *test* creation, and the doc for it says "If this flag is not set,
the calling application must handle errors, such as denial of access,
discovered when the item is created" — the item is created by the app.
https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/ne-shobjidl_core-_fileopendialogoptions)

That collides with kaya's vocabulary in exactly one place, and it is the
crux of the whole feature:

- A `PickedFile` handle is redeemed with `kaya_open_picked(mode)`.
- Every mode either opens an existing file or fails: MEASURED above,
  WRITE on a nonexistent path is ERROR_FILE_NOT_FOUND and creates
  nothing.
- So a save result is a handle that **no existing mode can open**.

Two shapes, and the choice is not Windows's to make:

- **(a) a creating mode** (a fourth `file_mode`, write-truncating-create).
  Natural on the three desktops, where the answer is a path.
- **(b) the backend creates the file when the result is emitted**, so the
  existing WRITE mode works. Natural on the phones — Android's
  `ACTION_CREATE_DOCUMENT` *does* create the document and hands back its
  URI, and iOS's export/save flow likewise yields a URL to a real file.
  Costs: a cancelled-then-crashed flow can leave a zero-byte file, and
  "the picker created it" has to be true on every platform or the
  semantics diverge.

DESIGN.md already names this as the deferred part and for this reason:
"SAVE is designed alongside but comes second, because creating a document
through SAF is a different request from opening one and the error surface
(permissions, disk full, a revoked scope) is the real work"
(DESIGN.md:1347-1351). The Windows measurement confirms the desktop half
of that and adds the concrete detail: on Windows the dialog gives you a
path and *nothing else happens*.

### B.3 The harness story on Windows — measured, and one real gap

The brief said "the open dialog UIA machinery already in deploy-win.sh".
That is not what is there, and the difference matters: **UI Automation is
forbidden against this dialog** (`winui/mod.rs:2218-2237`, `9194-9199`,
and the deliberate absence of the `Win32_UI_Accessibility` feature at
`crates/kaya/Cargo.toml:69-83`) because attaching any UIA client makes
the Shell's DirectUI raise a NONCONTINUABLE
`RPC_E_CANTCALLOUT_ININPUTSYNCCALL` that kills the JVM leg. The windows
harness drives the dialog with **classic control ids and POSTED
messages** (`winui/mod.rs:9222-9271`) and reads its contents through the
Shell's own `IServiceProvider → IShellBrowser → IShellView → IFolderView`
(`winui/mod.rs:2262-2306`). A save arm inherits all of that.

Both id maps measured in ONE session, same code, same VM:

| | OPEN dialog | SAVE dialog |
|---|---|---|
| default options | `0x1808` = FILEMUSTEXIST\|PATHMUSTEXIST\|NOCHANGEDIR | `0x880a` = NOREADONLYRETURN\|PATHMUSTEXIST\|NOCHANGEDIR\|**OVERWRITEPROMPT** |
| title | `"Open"` | `"Save As"` |
| commit button | id=1 `"&Open"` | id=1 `"&Save"` |
| cancel | id=2 | id=2 |
| **file-name box** | **id=1148**, as `ComboBoxEx32`/`ComboBox`/`Edit` | **id=1001, class `Edit`** — there is **no id 1148 at all** |
| address bar | id=1001 `ToolbarWindow32` | id=1001 `ToolbarWindow32` |
| list host | id=1121 `SHELLDLL_DefView` | id=1121 `SHELLDLL_DefView` |

(The measured defaults match the vendor table exactly: FOS_OVERWRITEPROMPT
and FOS_NOREADONLYRETURN are documented "default value for the Save
dialog", FOS_FILEMUSTEXIST "default value for the Open dialog".)

Three consequences for the harness, all measured:

1. **`choose_file` cannot name a file in a save dialog as written.**
   `winui/mod.rs:9246` looks up `dialog_control(dialog, ID_FILENAME=1148,
   "Edit")`; MEASURED: `NO Edit with id 1148 — cannot name a file`. The
   fix is one more (id, class) pair — and note `dialog_control` already
   matches on id **and** class, which is what keeps (1001,"Edit") from
   colliding with the (1001,"ToolbarWindow32") address bar. Small, but it
   is a silent failure today, not an error.
2. **The overwrite confirmation is a second top-level window and it is
   NOT a classic dialog.** MEASURED: saving over an existing name puts up
   a separate `#32770` titled `"Confirm Save As"` whose 17 descendants are
   a `DirectUIHWND` plus `CtrlNotifySink`-wrapped `Button`s **with
   id=0** — so no id lookup finds them:
   ```
   C-conf #32770 title="Confirm Save As" descendants=17
   C-conf   id=0 class=DirectUIHWND visible=true
   C-conf   id=0 class=Button visible=true text="&Yes"
   C-conf   id=0 class=Button visible=true text="&No"
   C-conf route1: Button "&Yes" id=0
   C-conf route1 (BM_CLICK on the Yes button) DISMISSED it
   C-conf RESULT OK path="…\existing.txt" exists_after_show=true size=Ok(12)
   ```
   Finding it **by class+text** and posting `BM_CLICK` works. Until it is
   answered, `Show()` never returns — measured, in an earlier run where
   the typing failed: `B-over RESULT timed out — Show never returned`,
   and the process had to die to clear it. So a save scene that
   overwrites needs either a verb that answers the confirmation or
   `FOS_OVERWRITEPROMPT` cleared; doing neither wedges the leg.
   (`exists_after_show=true` there is the *pre-existing* 12-byte file —
   the dialog still created and truncated nothing.)
3. **The folder read probably carries over, but I did not measure it.**
   The save dialog hosts the same `SHELLDLL_DefView` (id 1121), so
   `sample_folder_view`'s `IShellBrowser → IFolderView` walk should work
   unchanged — **ASSUMED**, not measured, because `expect_file_dialog`
   was not run against a save dialog. It is the one thing I would measure
   before writing the scene.

### B.4 Honest size, in this repo's units

**The Windows arm is a DEPTH SLICE.** Every call is measured working and
it reuses the machinery that exists:

- `winui/mod.rs`: a `file_save_show` beside `file_dialog_show` — same
  options/filters/`SetFolder` code with `SetFileName` +
  `SetDefaultExtension` added, ~60 lines. It rides the **same** one-STA
  `dialog_apartment`, the **same** `DIALOG_QUEUE` + doorbell, the
  **same** `file_dialog_retire` + `Occurrence::FileDialogResult` emit,
  and registers the **same** `PathSource`. `DialogRequest` grows a field.
- harness: a save arm in `choose_file` (the 1001 Edit) plus answering
  "Confirm Save As" by class+text, ~20 lines.
- Total Windows cost ≈ 80-100 lines, no new dependency, no new feature
  flag, no new thread.

**The FEATURE is a MILESTONE**, and none of what makes it one is Windows:

- the wire moves (`spec.rs:827-850`), so the spec hash moves and all 8
  bindings + `include/kaya.h` regenerate in lockstep — though note
  `show_file_dialog` already carries a spare `reserved: U32`
  (`spec.rs:834`) and its `filters` field is a `Values` list, so a save
  variant may need **no new record and no size change**;
- the not-yet-existing file has to get one semantics across five
  platforms (§B.2) — either a fourth `file_mode` or "the backend creates
  it", and that decision propagates into `FileMode`, `android_open_mode`,
  the iOS interpreter's mode codes and every binding's enum;
- four backends (SwiftUI serving mac+iOS, Compose, GTK, WinUI);
- 8 bindings' request sugar (`PickFile()`/`PickFiles()` gains a sibling);
- at least one new harness verb, which by house rule must appear in
  `harness.rs` (parser + `Step` + `Stage` method + the three test stubs),
  in gtk.rs, winui/mod.rs, **and re-implemented in both interpreter
  backends** (`KayaSwiftUI.swift:5317`, `KayaCompose.kt:4022` both carry
  their own `file_choose`), plus `tools/check-verbs.sh`;
- one new shared scene under `tools/scenes/`, compared byte-for-byte
  across five lanes and ported to all 8 guest languages;
- and the Java binding must stop returning `FileInputStream` before any
  of it can be called done (§A.3), which is a binding-surface change of
  its own.

---

## Cleanup

- VM: `saveprobe.exe`, `saveprobe*.cmd`, `guestprobe\`, `out_saveprobe*.txt`,
  `out_guestprobe.txt`, `saveprobe-dir\` deleted; scheduled tasks
  `kaya_saveprobe`, `kaya_saveprobe2`, `kaya_saveprobe3`,
  `kaya_guestprobe` deleted; `tasklist` shows no `saveprobe.exe`. The
  probe cancels every dialog it owns on every exit path and dies with a
  120 s watchdog; no window was left up.
- Mac: scratch crate + cargo target dir deleted; final size reported in
  the closing message.
- No repo file was modified (`git status` clean at start and end).

### Not measured (so nobody mistakes it for measured)

- The full end-to-end `kaya_open_picked(FILE_MODE_WRITE)` through the
  shipped `kaya.dll` with a handle minted by a real pick: the picked
  table is only fed by a real dialog and `picked_register` is
  `pub(crate)`, so driving it needs a guest that asks for write mode,
  which would have meant editing a repo guest. What *is* measured is the
  code on both sides of that call (§A.2, §A.3); the unmeasured segment is
  the mode `match` at `capi.rs:1419-1424` and a `HashMap` lookup, neither
  of which has platform behaviour.
- C# and Java were not driven; their verdicts are from the source.
- `expect_file_dialog`'s `IFolderView` read against a *save* dialog.
