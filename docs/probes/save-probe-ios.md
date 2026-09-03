# SAVE PROBE — iOS (SwiftUI backend, iOS half)

Repo HEAD `aeb135a`. Platform arm: **ios**. Probe arm — measure, do not build.
Every claim tagged MEASURED / DOCUMENTED / ASSUMED.

---

## Part A — WRITE MODE TODAY

### A.1 The path, end to end (source read)

Rust core, platform-independent half:

- `crates/kaya/src/wire.rs:225-227` — the three mode codes (`FILE_MODE_READ` 0,
  `FILE_MODE_WRITE` 1, `FILE_MODE_READ_WRITE` 2). DOCUMENTED (source).
- `crates/kaya/src/capi.rs:1403-1435` — `kaya_open_picked` maps the u32 to
  `protocol::FileMode`, rejects anything else with EINVAL(22), and delegates to
  `source.open(mode)`. DOCUMENTED (source).
- `crates/kaya/src/protocol.rs:111-142` — `PickedSource` trait: `open`, `name`,
  `local_path`, `locator`. DOCUMENTED (source).
- `crates/kaya/src/capi.rs:1642-1695` — `register_picked`, "THE ONE PLACE THE
  PLATFORM SOURCE IS CHOSEN". iOS arm (`capi.rs:1672-1677`) builds
  `swiftui_host::UrlSource { name, locator }`. DOCUMENTED (source).

iOS-specific half:

- `crates/kaya/src/swiftui_host.rs:51-113` — `UrlSource` (cfg `target_os = "ios"`).
  Its `open` calls the backend through `PICKED_OPENER`, passing
  `protocol::picked_mode_code(mode)` — **all three modes are forwarded**, no
  filtering, no read-only clamp. `local_path()` returns `""` deliberately.
  DOCUMENTED (source).
- `crates/kaya/src/swiftui_host.rs:260-264` — `PICKED_OPENER` is resolved by
  `dlsym(handle, "kaya_swiftui_open_picked")` at backend load, and is OPTIONAL:
  a backend without it makes redemption fail with a sentence, not a crash.
  DOCUMENTED (source).
- `swift/KayaSwiftUI.swift:2175-2212` — `kaya_swiftui_open_picked`. **This is
  where write mode is actually implemented on iOS.**

### A.2 The finding the string-grep missed

The coordinator measured that `FILE_MODE_WRITE` appears zero times in
`KayaSwiftUI.swift`. TRUE, and MISLEADING: the Swift side matches the
**numeric** codes, not the C macro names (`swift/KayaSwiftUI.swift:2195-2201`):

```swift
let flags: Int32
switch mode {
case 0: flags = O_RDONLY
case 1: flags = O_WRONLY | O_CREAT | O_TRUNC
case 2: flags = O_RDWR
default: return refuse("unknown open mode \(mode)")
}
let fd = open(url.path, flags, 0o644)
```

So on iOS write mode is CODED. Whether it WORKS is the measurement below.
The mode numbers are pinned on the Rust side by a unit test
(`crates/kaya/src/protocol.rs:1817-1820`), and the Swift comment at 2193-2194
names `picked_mode_code` as the contract — but nothing mechanically checks the
Swift literals against the Rust constants. (See "guard gap" at the end.)

### A.3 Security scope — where it is, and where it is not

MEASURED (grep over the whole repo, `*.swift` + `*.rs`): the ONLY call sites of
`startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`
in shipping code are `swift/KayaSwiftUI.swift:2191-2192`:

```swift
let scoped = url.startAccessingSecurityScopedResource()
defer { if scoped { url.stopAccessingSecurityScopedResource() } }
```

Start, open, stop — all inside the one call, correctly balanced (the `defer`
stops only if the start returned true). The only other occurrences in the repo
are in the hand-run hardware probe `tools/ios/scopeprobe/main.swift`.

MEASURED: `bookmarkData`, `resolvingBookmarkData`, `NSURLBookmark` appear
**zero times anywhere in the repo**. There is no bookmark machinery of any
kind. Consequence for restarts is in A.6.

### A.4 What the existing lane already proves (read mode)

The `filedialog` scene runs on the iOS lane: the rust suite loop
(`tools/ios/run-sim.py:1886-1889`) builds the module's examples —
`filedialog` among them (`tools/lib/lanes/ios.py:63`) — and queues
`filedialog-swiftui`. The scene
(`tools/scenes/filedialog.steps:66-67`) asserts the guest read the real bytes
back out of the descriptor ("1 picked bytes"), and its header says the scene
uniquely proves the capability SURVIVES CROSSING A THREAD.

So the chain pick → `emit_file_dialog_result` → `register_picked` →
`UrlSource` → `PICKED_OPENER` → `kaya_swiftui_open_picked` → fd is already
exercised green on iOS **for mode 0**. The only untested link for write is the
mode number and the flags it selects — which is what the probe drives directly.

### A.5 The harness bridge (why iOS is special, and what it costs)

MEASURED (source): iOS's picker is a REMOTE view controller, publishes zero
accessibility elements in-process, and iOS has no installable accessibility
service. So the harness's eyes live on the HOST:

- `tools/ios/simdrive/main.swift (gone)` — reads the picker's tree through
  CoreSimulator + AccessibilityPlatformTranslation, taps through
  SimulatorKit's HID client. CLI: `simdrive <udid> <app-pid> <verb>`,
  verbs `state|choose <name>|cancel|describe|navstrip|press <label>`
  (`main.swift:459-461, 523-640`).
- `swift/KayaSwiftUI.swift:2006-2076` — the in-app half. Request/response is a
  pair of files in the app's own container; the trailing newline is the commit.
- `swift/KayaSwiftUI.swift:5358-5366` — `file_choose` routes to
  `kayaSimdriveDrive` on iOS; the macOS arm drives NSOpenPanel in-process.

**There is no `type`/text-entry verb in simdrive.** MEASURED: the verb switch
(`main.swift:523-640`) has exactly six cases and none of them enters text; the
only `setValue` calls in the file are the AX bridge-token plumbing. This is the
single most important harness fact for part B — see B.4.

### A.6 THE DRIVE — write mode, measured against the shipped artifact

Probe: a throwaway iOS-simulator app that `dlopen`s the shipped
`libkaya_swiftui_ios.dylib` and calls the production
`kaya_swiftui_open_picked` directly, for every mode. The dylib was
`tools/build-id.py --verify --component swiftui`'d first (rc=0), so what was
driven is the artifact built from the current sources, not a stale one.

Run on `kaya-sim-0` (iOS 26.5 simulator), 2026-08-09. ALL MEASURED:

| # | call | result |
|---|---|---|
| A1 | mode 0 (READ) on a 12-byte file | `fd=3 seekable=1`, read back `"picked bytes"` |
| A2 | mode 1 (WRITE) on a 20-byte file | `fd=3 seekable=1`; wrote 2 bytes; **size 20 → 2**, content `"hi"` |
| A3 | mode 2 (READ_WRITE) on a 10-byte file | `fd=3 seekable=1`; read `'0'`, wrote `'Z'`; **size still 10**, `"Z123456789"` |
| A4 | mode 99 | `fd=-1`, error `"unknown open mode 99"` |
| A5 | mode 1 on a path that does not exist | **`fd=3`, and the file was CREATED** |
| A6 | mode 1 twice on the same locator | second open `fd=3` — redeems for write more than once |

So on iOS: **write mode works, truncates like the desktops, read-write works
and does not truncate, a bogus mode is refused with a sentence, and a locator
is redeemable for write repeatedly.** A2 and A3 are the two claims that
matter, and both hold.

**What the simulator CANNOT prove, stated so the reader does not over-read
the table.** The simulator does not enforce the app sandbox at all
(docs/traps.md:1719-1737, measured 2026-07-27), so nothing above is evidence
about security scopes. The probe reported
`startAccessingSecurityScopedResource` returning **true** on an ordinary
temp file, which is exactly the vacuity: it says yes to a URL that is not
scoped. The table therefore measures the PLUMBING — mode number → open flags
→ descriptor → truncation semantics — which is not sandbox-dependent.

The sandbox half was already measured ON HARDWARE and is not re-litigated
here: DESIGN.md:1085-1092 (iPhone 17 Pro, iOS 26.5.2, 2026-07-27, behind a
vacuity guard that required EPERM first) records that `NSURLIsWritableKey`
answers true, `open(O_RDWR)` succeeds, the write lands, and the write
descriptor outlives the scope. **THE OPEN PICKER GRANTS WRITE**, contrary to
the published material — see docs/traps.md:1756-1765.

### A.7 THE DEFECT — one FileMode, two meanings

A5 is a real divergence, and it is the same class as a bug this repo already
caught once.

- iOS (`swift/KayaSwiftUI.swift:2198`): `case 1: flags = O_WRONLY | O_CREAT | O_TRUNC`
- desktops (`crates/kaya/src/protocol.rs:235`): `FileMode::Write => opts.write(true).truncate(true)`
  — `std::fs::OpenOptions` with no `.create(true)`, so a missing path is ENOENT.
- Android (`crates/kaya/src/protocol.rs:220`): `FileMode::Write => "wt"` into
  `ContentResolver.openFileDescriptor`, which resolves an existing document.

MEASURED on iOS (A5): opening a NON-EXISTENT path in write mode **succeeds and
creates the file**. On the three desktops the same `FileMode::Write` fails.
Same mode, two meanings across platforms — precisely what
`protocol.rs:185-197` forbids in its own words, in the comment written when
the `w`-vs-`wt` divergence was found and closed for Android:

> "Same `FileMode`, two meanings, which is exactly the divergence the binding
> conventions forbid; the `t` is what makes them one."

Reachability is narrow but real: the file is deleted or moved between the pick
and the open (another app, a sync client, an atomic save by another editor).
The desktop guest gets ENOENT and can tell the user the document vanished; the
iOS guest silently creates an empty file and reports success, and the editor
then "saves" into a file nobody asked for. For an editor milestone that is the
wrong failure mode.

Note the O_CREAT is not obviously wrong in isolation — it is what a SAVE flow
would want. It is wrong because nothing decided it uniformly. Whichever way it
is settled (all create, or none create), it should be settled in one place with
a test, the way `android_open_mode` was.

### A.8 Across app restarts — bookmarks

MEASURED (repo grep): kaya creates NO bookmarks. `bookmarkData`,
`resolvingBookmarkData` and `NSURLBookmark` appear zero times in the repo.
`kayaPickedURLs` (`swift/KayaSwiftUI.swift:2106`) is an in-memory
`[String: URL]` on the backend, and `capi.rs:1360` registers into a
process-lifetime table whose miss "FAILS LOUDLY" (`capi.rs:1381-1386`).

So a picked file's handle **dies with the process**. There is no reopen-on-
relaunch story on any platform today, and DESIGN.md does not claim one —
`docs/file-dialogs-plan.md:626-631` lists "persistence across restarts for a
recents list" as deferred, and names the trap.

I verified that trap against the SDK rather than the docs
(`.../iPhoneSimulator.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSURL.h`):

- line 428 — `NSURLBookmarkCreationWithSecurityScope API_AVAILABLE(macos(10.7), macCatalyst(13.0)) API_UNAVAILABLE(ios, watchos, tvos)`
- line 436 — `NSURLBookmarkResolutionWithSecurityScope … API_UNAVAILABLE(ios, watchos, tvos)`
- line 444 — plain `bookmarkDataWithOptions:…` IS available, `ios(4.0)`
- line 437 — `NSURLBookmarkResolutionWithoutImplicitStartAccessing … ios(14.2)`,
  documented as disabling "implicitly starting access of the ephemeral
  security-scoped resource during resolution"

DOCUMENTED (SDK): on iOS you make a PLAIN bookmark; the security-scope flags
are macOS-only, and resolution implicitly starts the access. So the mechanism
exists on iOS and is spelled differently from macOS — which is a design
decision for a later milestone, not something write mode needs.

---

## Part B — THE SAVE DIALOG

### B.1 There is no save request on the wire

`crates/kaya/src/spec.rs:827-850` — `show_file_dialog` (kind 34) carries
`window, dialog, multiple, reserved, filters`. Open-only, exactly as the
charge says. Two things worth noting for sizing:

- **There is already a `reserved: U32` in the record**, read and discarded at
  `crates/kaya/src/wire.rs:774` (`let _reserved = r.u32();`). A save/open
  discriminant fits it with **no change to the record's byte layout** — the
  spec hash still moves (the field is renamed), but nothing re-lays-out.
- The result side needs nothing new at all. See B.3.

DESIGN.md has already ruled on the split (DESIGN.md:1337-1355):

> "SAVE-BACK NEEDS NO SPECIAL MACHINERY … saving is the same call as opening
> with a different mode … What remains genuinely different about SAVE is
> creating a document that does not exist yet, which is why it is deferred."

That is the correct division and part A confirms its first half on iOS: the
write mode an editor needs to save an OPENED document already works.

### B.2 The API kaya would call on iOS

DOCUMENTED, from the SDK the repo compiles against
(`.../iPhoneSimulator.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIDocumentPickerViewController.h`),
which is the standard this repo already applies to picker claims
(DESIGN.md:1108-1111 verified multi-select the same way):

```objc
/// Initializes the picker for exporting local documents to an external location.
/// The new locations will be returned using `didPickDocumentAtURLs:`.
/// @param asCopy if true, a copy will be exported to the destination, otherwise
///        the original document will be moved to the destination. For performance
///        reasons and to avoid copies, we recommend you set `asCopy` to false.
- (instancetype)initForExportingURLs:(NSArray <NSURL *> *)urls asCopy:(BOOL)asCopy
    NS_DESIGNATED_INITIALIZER API_AVAILABLE(ios(14.0)) API_UNAVAILABLE(tvos, watchos);
```

Swift: `UIDocumentPickerViewController(forExporting: [URL], asCopy: Bool)`.
`directoryURL` and `shouldShowFileExtensions` are properties on the class, so
they serve the export picker exactly as they serve the open one — which
matters, because `file_dialog_goto` already drives `directoryURL`
(`swift/KayaSwiftUI.swift:1968-1970`).

**THE ONE SHAPE CONSTRAINT: iOS has no "create an empty file with this name"
picker.** Every export initializer takes URLs that ALREADY EXIST locally. So
the iOS save flow is necessarily: guest writes bytes to a container-local
file, kaya presents the export picker, the platform answers with the
destination. This is the same constraint Android's SAF `CreateDocument`
does NOT have, and it is the real content of DESIGN.md's deferral.

### B.3 What it answers with — MEASURED

Driven end to end in the simulator: present the export picker, tap the real
Save button, capture the delegate.

```
B presenting UIDocumentPickerViewController(forExporting:asCopy:true) with draft.txt
B presented
B export didPickDocumentsAt count=1
B export   destination absoluteString=file:///…/Application/944F1834-…/Documents/draft.txt
B export   lastPathComponent=draft.txt
B export   scoped=true exists=true size=13
B export   open(O_WRONLY) on destination: fd=3
B export   source still exists=true
```

The findings, each MEASURED:

1. **The answer arrives through `documentPicker(_:didPickDocumentsAt:)` — the
   SAME delegate method the open picker uses**, with a list of URLs.
2. Those URLs are the **new destination**, not the source.
3. The destination **exists and carries the bytes** (size 13 = "saved by kaya").
4. The destination is **writable through an ordinary `open(O_WRONLY)`** (fd=3),
   so the answer is a real capability and not a receipt.
5. `asCopy: true` leaves the source in place, as the header says.
6. The picker **leaves** after Save (`describe` → "no picker"), so the
   "panel must be gone" postcondition every other backend asserts holds here.

**This is why the save side is cheap on iOS.** kaya's whole result path is
already shaped for it: `KayaPickerDelegate.answer(urls)`
(`swift/KayaSwiftUI.swift:2134-2164`) stringifies each URL, retains the object
in `kayaPickedURLs`, and calls `emit_file_dialog_result`. A save answer is a
list of URLs — byte-identical in shape. The saved file comes back as an
ordinary picked-file handle the guest opens in write mode, which part A just
proved works. **No new result record, no new source type, no new open path.**

### B.4 The harness story — and a FALSE GREEN sitting in the road

MEASURED, and this is the part that costs real work.

What simdrive can already see of the export picker (`describe`):

```
AXApplication  Files
AXStaticText   Folder is Empty
AXStaticText   Save as        {{97, 729.7}, {46.7, 15.7}}
AXTextField                   {{97, 746.3}, {136, 22}}      <- the filename field
AXButton       Tags
```

and (`navstrip`): `On My iPhone`, `Search`, `SaveProbe, Actions Menu`, `More`,
**`Save` at {323.8, 92}**.

Three measured facts:

1. **The real Save button is NOT in the flattened overlay tree.** `describe`
   does not list it; only `navigationStrip` finds it. Same split the `cancel`
   verb already documents (`simdrive/main.swift:598-609`).
2. **`press Save` FALSELY SUCCEEDS.** Measured: it printed
   `pressed AXStaticText Save as … in overlay` and exited 0 — it matched the
   static-text LABEL "Save as" by `description.contains("Save")`
   (`main.swift:665-672`) — while the picker stayed up and the delegate never
   fired. A save leg written on today's `press` would go green having pressed
   nothing. This is CLAUDE.md invariant 4 ("a gate that can be satisfied
   without exercising the real thing is a bug in the gate") and it is already
   true today, before anyone writes the leg.
3. **A navstrip-press verb fixes it, and it is small.** I added a throwaway
   `navpress` (exact match on the strip label, reusing `navigationStrip` and
   `Tapper` — about 12 lines) and it tapped `Save at {323.8, 92}`, the delegate
   fired, and the picker left. Note the exact match is load-bearing: a prefix
   match sent the tap to **"SaveProbe, Actions Menu"** on the first try, which
   opened a context menu instead — measured, not hypothesised.
4. **Filename entry has no verb, but the keys are visible.** After the stray
   tap raised the keyboard, `describe` listed the on-screen keys as
   `AXButton q`, `AXButton w`, … So a filename CAN be typed by tapping keys
   through the existing Tapper; there is simply no verb that does it. That is
   the honest cost: either a key-tapping `type` verb, or a save scene whose
   filename is whatever the source file was called (which the export picker
   pre-fills, and which needs no typing at all).

The cheapest credible iOS save leg therefore needs **one new simdrive verb**
(navstrip press) and can avoid the second (typing) by asserting the
pre-filled name — with `expect_save_dialog` reading the AXTextField's value
to prove the name is right before pressing Save.

---

## VERDICTS

### (A) WRITE MODE TODAY = **WORKS** on iOS, with one uniformity defect

- The path is fully implemented: `UrlSource::open` forwards all three modes
  (`swiftui_host.rs:59-92`), and `kaya_swiftui_open_picked` implements them
  (`KayaSwiftUI.swift:2195-2211`). The coordinator's zero-hits grep for
  `FILE_MODE_WRITE` is true but misleading — the Swift side matches numeric
  codes, not macro names.
- MEASURED against the build-id-verified shipped dylib: write opens, writes
  and truncates (20 → 2 bytes); read-write opens, reads and writes without
  truncating; a bogus mode is refused with a sentence; a locator redeems for
  write repeatedly. Security scope IS acquired and released around the open,
  correctly balanced.
- The sandbox half was measured on hardware in 2026-07 and holds: the open
  picker grants write and the write fd outlives the scope.
- **Defect:** iOS write mode passes `O_CREAT` where `PathSource` does not
  create, so a missing file is created on iOS and ENOENT on the desktops.
  MEASURED (A5). One `FileMode`, two meanings.
- **No cross-restart persistence anywhere** (no bookmarks in the repo); on
  iOS the mechanism would be a PLAIN bookmark, since the security-scope
  flags are `API_UNAVAILABLE(ios)`.

Caveat stated plainly: no guest, scene or leg drives write mode, so nothing
in the lanes would notice if it broke tomorrow. It works and it is unguarded.

### (B) SAVE DIALOG = **A DEPTH SLICE on iOS**, not a milestone

- **API:** `UIDocumentPickerViewController(forExporting: [URL], asCopy: Bool)`.
- **Answers with:** destination URLs through
  `documentPicker(_:didPickDocumentsAt:)` — the same delegate method, the same
  shape, as the open picker. MEASURED. Destination exists, carries the bytes,
  and is writable.
- **Harness:** one new simdrive verb (navstrip press). Plus a fix to `press`,
  which today reports success for a tap that does nothing.
- **Size, in this repo's units:** the iOS ARM is a depth slice — the wire
  record has a spare field, the result path is unchanged, the backend change
  is one initializer plus a delegate that already exists, and the harness cost
  is one verb. What makes the FEATURE a milestone is not iOS: it is the
  create-a-new-document semantics DESIGN.md deferred (DESIGN.md:1347-1351),
  the SAF `CreateDocument` request on Android, the 8-binding `save_file` sugar
  fan-out (all 8 have `pick_file`/`pick_files` today), a new scene, and the
  two interpreter backends. iOS is the cheap arm precisely because its save
  picker returns the same thing its open picker does.

---

## GUARD GAPS FOUND (offered, not built — this is a probe arm)

1. **The Swift mode literals are unchecked against the Rust constants.**
   `protocol.rs:1817-1820` pins `picked_mode_code`; `KayaSwiftUI.swift:2196-2200`
   spells `case 0/1/2` with a comment naming that function and nothing that
   fails if they drift. A check-verbs-style text assertion would close it.
2. **Write mode has no leg on any platform.** The `filedialog` scene reads
   only (`tools/scenes/filedialog.steps:67`). A write clause in the shared
   scene would cover all five lanes at once, and would have caught A5.
3. **`press` can pass without pressing anything.** Measured above. It should
   refuse a match on a non-actionable role, or require an observable
   postcondition the way `choose` requires the picker to be gone.


