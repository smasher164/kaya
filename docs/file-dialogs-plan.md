# File dialogs — the executable plan

Status: LANDED 2026-07-31 — all five backends (§6d Compose, §6e iOS)
and all eight bindings (§6f), `tools/scenes/filedialog.steps` on every
runner. The continuation note that tracked the tail of §6 is
docs/handoff-filedialogs-6d.md, itself spent.

**WAS BLOCKED ON docs/background-work-plan.md, deliberately**, and that
block cleared when the post primitive landed 2026-07-28. Working
through §0 below is what found the real gap: kaya had no way to do work
off the app thread and post the result back, so a late-arriving result
had to be delivered as a callback, and then the READ after it had
nowhere to go either. Every shape considered here was an attempt to
invent that primitive privately. Building it first made most of §0
disappear: the open became an ordinary blocking call on a thread the
guest chose.

The design is RATIFIED and lives in DESIGN.md's "File dialogs" section;
read it first, this file does not repeat it. Measurements behind it are
in that section and in docs/traps.md. Nothing below is a design
decision except §0.

Sequencing follows CLAUDE.md's depth-then-breadth rule: protocol, one
backend (SwiftUI on mac), one binding (Rust), the scene, green on mac.
Only then fan out.

## §0 — what was left to settle before spec.rs was touched

Two of the three original questions are answered. `size` is OUT (Akhil,
2026-07-28: nothing needs a pre-open size, and the rule that killed
`writable` reaches it too), so the picked record is three fields. And
(a) below is mostly answered by building the post primitive first — the
long history is kept because the reasoning is what found that gap, and
because someone will otherwise re-propose the callback shape.

**(a) How does the OPEN cross the ABI?** Note first what is NOT in
question: the PICKER is asynchronous, on the alert grammar, tx ->
apply -> occurrence. Only the open is at issue.

RATIFIED 2026-07-28 (Akhil): a plain blocking C FUNCTION.
It does the work and returns the descriptor to its caller, on the
caller's thread. Not a submission with a completion elsewhere — that
was the earlier proposal (option C below) and it is REJECTED. The rest
of this subsection is the road that got there; skip it unless
re-opening the question.

WHY NOT THE SUBMISSION SHAPE, which is where this design sat for a
while. Three reasons, the first decisive:

  - THE DESCRIPTOR WOULD LAND ON THE WRONG THREAD. Completions are
    occurrences, and occurrences drain on the APP thread. But the guest
    called open from a worker precisely so it can READ there, so the fd
    would have to be shipped straight back out — a round trip through
    the one thread this whole design exists to keep free.
  - NO SPEC CHANGE AT ALL. A C ABI function is not a record: the hash
    does not move, the eight emitters do not regenerate, neither
    interpreter needs an arm, check-verbs is not involved, and no
    harness verb appears. The submission shape touches every one of
    those.
  - NO SECOND ID SPACE. The pick already has an id with a lifetime; a
    submission would add an unrelated one plus its retirement rules.

TWO COSTS ACCEPTED, stated rather than hidden. CANCELLATION: with no
request id there is nothing to name in a cancel, so adding one later
means adding the id after all — acceptable because a slow open now
occupies only a thread the guest spawned on purpose. AND A PROCESS
SPLIT: a C function does not translate over a socket where a record
would. Narrow and speculative — nothing on the roadmap needs it, and
over an actual NETWORK the descriptor itself cannot travel, so the
capability design is local-only by construction either way. WHAT WOULD
REOPEN THIS: an out-of-process guest on the same machine, where
SCM_RIGHTS makes fd passing real. Then open becomes a submission, gains
a request id, and cancellation arrives with it.

WHAT SURVIVES THE FUNCTION SHAPE, checked rather than assumed: the
stall diagnostic. DESIGN gets it free from the transport — "the core
reads the app's log-consumer cursor, and undrained for N seconds is the
health signal". A guest that blocks the APP thread on a slow open stops
draining and trips it, correctly, on exactly the misuse worth catching;
a guest that opens on its own worker keeps draining and stays quiet.
The signal gets sharper here rather than being given up.

AND IT IS ALL RUST. `extern "C"` fixes the calling convention and name
mangling; the body, the table and the lock are ordinary Rust behind a
cbindgen-generated declaration. capi.rs already holds four tables of
this kind — `kaya_blob_register` is the same shape line for line
(monotonic counter, `Mutex<HashMap<u64, _>>` behind a `OnceLock`,
integer to the guest) with bytes where this has an `NSURL`, a `Uri` or
a path. So "no spec change" is stronger than it sounds: no wire
records, no emitters, no interpreters, no verbs — a Rust function, a
Rust table, and one line in kaya.h.

The record grammar's three channels are tx (mutate the tree), apply
(tell the presentation), and occurrence (report an event). The open is
none of them: it is a query returning a file descriptor to the caller,
inline. There is precedent for living outside the grammar —
`kaya_capabilities()` returns a bitmask, `kaya_blob_data` reads
presentation-side. PROPOSAL: a direct C function,

```c
int32_t kaya_open_picked(uint64_t handle, uint32_t mode,
                         int32_t *out_fd, uint32_t *out_seekable);
```

with `mode` a spec'd enum (the `alert_choice` precedent) so all eight
bindings inherit one spelling and check-verbs can pin it. Rejected
alternative: a tx plus an occurrence pair, because a descriptor is not
an event, `File::open` blocks in all eight guest languages, and forcing
it through the ring makes every guest write a continuation for a value
it asked for directly — the one place the design would go back on
reusing the language's own file APIs.

BLOCKING IS ALREADY ALLOWED, which is what makes that safe: the
threading model gives app logic its own thread and requires it to be
blockable, "because occurrence consumption blocks by design". That
thread is not the UI thread on any platform, Android included, where
the dispatcher attaches to the Looper thread and app logic lives
elsewhere. A slow open costs queued occurrences, not a frozen window
and not an ANR.

BUT IT CAN BLOCK FOR A LONG TIME, and this is the part the design pass
missed. A cloud provider may have to DOWNLOAD the file before it can
hand back a descriptor: Android says so structurally by offering
`openFileDescriptor(uri, mode, CancellationSignal)`, and iCloud
materialization on iOS is the same story. So the two real questions
here are neither of them sync-versus-async:

  1. **May the guest call it off the app thread?** It touches no tree
     and takes no transaction, so it can be deliberately thread-safe —
     the first C entry for which that is true. On Android the open must
     reach `ContentResolver` through JNI, so an arbitrary calling thread
     means `AttachCurrentThread`; that is real work and should be priced
     before promising it. PROPOSED ANSWER: yes, and then ONE BLOCKING
     FLOOR with each sugar wrapping it in that language's async idiom
     where the language has one — Swift `func open(_:) async throws`,
     Kotlin `suspend` on `Dispatchers.IO`, C# `Task<Stream>
     OpenAsync()`; Rust, Go, Python and the rest block, and the caller
     backgrounds it the way they would any file open (which is exactly
     what gio asks of its users today: "It's a blocking call, you should
     call it on a separated goroutine"). Same observable semantics
     everywhere, one descriptor or one error; blocking versus suspending
     is spelling, the line alerts already live on.

     NOT AN EFFECT SYSTEM, and worth saying because the reactive
     frameworks make it tempting. Compose's `LaunchedEffect`, SwiftUI's
     `.task` and Flutter's futures are all VIEW-LIFECYCLE-SCOPED: the
     effect belongs to a view and dies with it. kaya has no view-scoped
     effects — app logic owns a thread and handlers are transactions —
     so importing that framing would mean importing a scheduler kaya
     does not have. kaya's effect boundary is already in the right
     place: THE PICK is the effect (request out, occurrence back), and
     the open is a plain call on the value it produced.
  2. **Can a slow open be cancelled?** Android hands us the mechanism.
     The other three have no equivalent, so a uniform cancel would be
     kaya inventing one. Deferred with that stated — and much less
     pressing once a slow open occupies only a thread the guest spawned
     on purpose.

HOW THAT RESOLVED. Question 1 is answered by the post primitive rather
than by choosing a shape: the guest opens on its own thread and posts
the result back, so kaya never decides who waits. Question 2 shrinks to
a deferral.

AND THE ANDROID JNI NOTE IS CLOSED, smaller than three messages of mine
made it sound. The open reaches `ContentResolver.openFileDescriptor`
through JNI, so the calling thread needs a `JNIEnv` — which is
`vm.attach_current_thread()`, returning an `AttachGuard` that detaches
on drop (jni 0.21). Two lines on the Android path, not architecture;
native code calls into Java from arbitrary threads constantly. Use the
SCOPED guard: a permanently-attached thread that exits without
detaching can take the JVM down.

REJECTED: dispatching the open to a long-lived backend worker. It looks
like it avoids the attach, and it breaks the feature — ONE worker
SERIALIZES opens, so a guest that spawned five threads to open five
files in parallel would get them one at a time, losing exactly the
concurrency it created. The fix for that is a pool, and a pool is kaya
owning a scheduler, which this design rejected twice already (the
effect-system framing, and an async runtime). The guest's own threads
ARE the concurrency; kaya supplies none.

Android's "do not call openFileDescriptor on the main thread" is then
satisfied for free: the guest calls from a thread it spawned, and the
warning is about the MAIN thread.

WHY THE FLOOR IS SYNC AND STAYS SYNC, since an async-first language will
raise it again. SYNC COMPOSES UPWARD INTO ASYNC; ASYNC DOES NOT COMPOSE
DOWNWARD INTO SYNC. Wrapping a blocking call in a Promise, a Task or an
`async fn` is mechanical. Going the other way on a single-threaded event
loop does not merely cost something, it DEADLOCKS: you block waiting for
a completion only the loop you just blocked can deliver.

The roster's own async surface is already sketched and agrees — the Node
entry in docs/deferred.md puts app logic in a WORKER, which is a real
thread with its own loop and can block, so the sync floor works there
unchanged; promises and `for-await` are layer 3 wrapping it, exactly as
Swift's `async` and C#'s `Task` do.

What the sync floor does NOT promise is that callers are on a background
thread. Blocking is the caller's choice, as `File::open` is in all nine
languages. On the app thread it costs QUEUED OCCURRENCES, not a frozen
window. The honest wart: a guest cannot tell a local file from a cloud
one — the picked record looks identical — so "is this open fast" is not
answerable before making it.

**(b) How does the picked LIST ride the occurrence?** `FieldTy::Values`
is already `{ u32 count; u32 reserved; count values }`, and its own doc
in spec.rs says it encodes "a key path or an entry's record". So N
files can ride as one flat `Values` read in fixed-size groups, using
the existing `VALUE_I64` and `VALUE_STR` tags. PROPOSAL: groups of
three, `(I64 handle, Str name, Str local_path)`. Rejected alternative:
a new repeated-record `FieldTy`, which is new wire machinery, a new
generator arm in seven emitters, and buys nothing the grouping does
not.

**(c) `size` — SETTLED, it is OUT.** (Akhil, 2026-07-28: "i'm not sure
why size is there tbh.") The rule that killed `writable` reaches it:
`fstat` on the descriptor answers it, and nothing on the roadmap needs
the answer BEFORE opening. The one case that would have justified it —
listing hundreds of picked files with sizes while opening none — is not
the text editor, and admission here is trigger-gated. So the picked
record is three fields, and the group in (b) is three.

**(d) THE SUGAR'S NAME — settled: `pick_files`.** (Akhil, 2026-07-28.)
`open_files` was the working name and it is wrong twice: it promises
OPEN files and delivers references that are opened later, contradicting
the deferred-open design; and it collides with the call that really does
open, four lines away —

```
sel, _ := app.OpenFiles(...)    // opens nothing
file, _ := f.Open(kaya.Read)    // opens
```

`pick` is also the platform's own word: `FileOpenPicker` (WinUI),
`UIDocumentPickerViewController` (iOS), `FilePicker.PickMultipleAsync`
(MAUI), `OpenFilePickerAsync` (Avalonia), `pickFiles` (Flutter).
`ChooseFiles` is gio's and old GTK's `GtkFileChooser` — real, narrower.

The WIRE record stays `show_file_dialog`: at that level a dialog
genuinely is being shown, and it matches `show_alert`. The sugar is
`pick_file` / `pick_files`, with the alert chain's terminal `.show()`.

## §1 — spec.rs, and the hash moves

Model on the alert grammar, which is the same request/result shape
(`show_alert` tx 21, `present_alert` apply 11, `alert_result` occ 7):

- **tx `show_file_dialog`**: `window` U64, `dialog` U64, `multiple` U32,
  `reserved` U32, `filters` Values. Guest-chosen id; ONE live per
  process; the id retires when the result fires. Filters are advisory
  `(label, extensions)` pairs.
- **apply `present_file_dialog`**: the same fields, already validated by
  the core.
- **occurrence `file_dialog_result`**: `dialog` U64, `count` U32,
  `reserved` U32, `files` Values per §0(b). CANCEL IS COUNT ZERO, not a
  sentinel — no platform can confirm an empty selection, so the empty
  list is faithful and needs no extra encoding (contrast `alert_choice`,
  which needed one because dismissal is not an action index).
- **enum `file_mode`**: read, write, read_write.

Then the workflow in docs/HACKING.md §"The regeneration workflow":
`cargo test -p kaya --features harness --locked` fails until
protocol.rs / wire.rs / capi.rs carry matching arms; the compiler's
non-exhaustive matches are the checklist. Then `tools/gen-header.sh`,
`tools/gen-bindings.sh`, `cargo build --lib`, and `tools/gen-guests.sh`
if guest-visible surfaces moved. Commit generators WITH their outputs.

## §2 — the core

- Validate at the root the way alerts do: one dialog live per process,
  guest-chosen id, retire on result.
- A HANDLE TABLE, which is the genuinely new state. A handle maps to
  the platform object the backend is holding: a path, a `content://`
  URI, an `NSURL`. It is process-lifetime and holds nothing the kernel
  counts (DESIGN.md says why explicit release is deferred).
- WHY A TABLE AND NOT JUST A STRING, since that is the obvious question.
  On the desktops a path IS the name, and on Android a `content://` URI
  is textual and re-parses fine (the grant is per-process, keyed by the
  URI). IOS IS WHAT FORCES IT: there the picked thing is an `NSURL`
  whose AUTHORITY belongs to the object, not to its text — measurement 4
  found re-opening by path denied with EPERM, while measurement 5 found
  the object can re-acquire and open again. Stringify it and you hold
  something that looks usable and is dead. One mechanism everywhere
  beats strings on three platforms and handles on the fourth.
- WHY NOT HAND OVER THE POINTER, which is the fair follow-up — an
  `NSURL*` could cross as a `uintptr_t`. It is possible and it buys
  four problems. LIFETIME: the object is refcounted, so kaya retains on
  the guest's behalf and the guest must say when to release — a manual
  protocol spelled nine times. VALIDATION: a bogus `uintptr_t` is
  undefined behaviour where a bogus integer is a clean error. IT IS NOT
  ONE KIND OF POINTER: ObjC retain/release, a JNI reference, WinRT
  AddRef/Release, and a `char*` to free — four disciplines behind one
  `void*`, and uniform semantics means the guest cannot see which.
  AND JNI IS WORSE STILL: a local `jobject` is valid only on its
  creating thread and frame, so it must be promoted to a global ref and
  then explicitly deleted or it leaks. Decisive for this codebase: every
  id here is ALREADY an integer with a core-side table — widgets,
  signals, collections, alerts, menu items, windows, entries, sections —
  so a pointer would be the protocol's sole exception and its first
  place a wrong value crashes rather than fails.
- THE TABLE IS CORE-SIDE AND MUTEX-GUARDED, which is what lets the open
  be a plain function: any thread must be able to resolve a handle. The
  platform objects it holds are then safe to use off-thread — an
  `NSURL` is immutable, a path is a string, and Android's URI needs the
  scoped `attach_current_thread` from §0(a).
- RESOLVE UNDER THE LOCK, RELEASE, THEN OPEN. The lock covers a map
  lookup — tens of nanoseconds against an open that is a syscall at
  best and a network download at worst. Holding it ACROSS the open
  turns the table into the serialization bottleneck it has no reason to
  be, and would undo the parallelism the guest created by spawning
  threads. Same discipline as drainPosted taking its batch before
  running any of it.
- `kaya_open_picked` resolves a handle, opens in the requested mode ON
  THE CALLING THREAD, and returns the fd plus `seekable`. Fallible in
  ways the pick is not; that is stated in the design and must reach the
  guest as the language's ordinary I/O error.

## §3 — SwiftUI on mac (the one depth backend)

`NSOpenPanel`, `allowsMultipleSelection` from the `multiple` field,
`allowedContentTypes` from the filters. On the result, register each URL
in the handle table and emit `file_dialog_result`. macOS gives real
paths, so `local_path` is populated here and `open` is plain POSIX. The
phones are where it gets interesting, and they come later on purpose.

## §4 — the Rust binding

Per DESIGN's selection rule: kaya's own structure, iterate it, open an
entry. Rust has no std filesystem trait, so this is a plain type with
`open(mode) -> io::Result<File>`, built from the raw fd. Nothing
adopted, nothing invented beyond what the floor already says.

## §5 — the scene

Both open questions have answers; the second needs a stated carve-out.

**WHICH FILE IT PICKS — the guest makes it.** The guest and the
interpreter are THE SAME PROCESS, so they can agree on a path with no
runner involvement at all: `<temp dir>/kaya-picked-<pid>/picked.txt`,
computed identically on both sides. The guest writes known bytes at
startup; the scene names the file by BASENAME only, so the script stays
byte-identical across five lanes whose temp dirs differ. The pid is
load-bearing — validate-mac runs legs in parallel, so a fixed name
would collide.

That also makes the assertion end-to-end rather than about the picker:
the guest opens the returned handle, reads it with its own file API,
and writes what it read into a signal. `expect label#0 "picked bytes"`
therefore proves the handle redeemed for a real descriptor carrying the
right file — the design's central claim, not just that a dialog closed.

**DRIVING THE PANEL — NO CARVE-OUT. It is real chrome, all of it.**
Measured 2026-07-28 with a probe rather than assumed, and the probe
overturned the design that was written here first. `NSOpenPanel`
publishes a full accessibility tree with stable identifiers, and every
step a user takes is drivable:

```
AXWindow  id=open-panel      title=Open
  AXOutline   id=ListView       <- the file list, one AXRow per file
  AXPopUpButton id=where popup  value=<the directory it is showing>
  AXButton    id=CancelButton   acts=[AXPress]
  AXButton    id=OKButton       acts=[AXPress]
```

The probe selected the row with `kAXSelectedRowsAttribute`, pressed
`OKButton` with `kAXPressAction`, and the panel's OWN completion fired
with the right URL:

```
WHERE = kaya-paneldrive
ROW texts=["picked.txt", "12 bytes", "Plain Text", ...]
SELECT rc=0
PRESS OPEN rc=-25204
COMPLETION response=OK urls=["picked.txt"]
```

THE TRAP IN THAT OUTPUT, worth keeping: `rc=-25204` is
`kAXErrorCannotComplete`, and it is NOT a failure. Pressing a button
that dismisses its own window tears the element down before the AX call
can finish its round trip, so the error is expected and the completion
firing is the proof. A future reader who treats that code as a failure
will "fix" a working drive.

AND THE SCENE GETS MORE THAN PLANNED. Both of these are readable, so
the hole the carve-out would have left is closed rather than merely
narrowed:
  - `id=where popup`'s value names the directory the panel is ACTUALLY
    showing — proof it was aimed correctly, not just that it opened;
  - the row's own text carries the filename — proof the list was
    POPULATED with the file, not empty.

A panel that presents pointed at the wrong place, or with a filter that
excludes everything, now fails the scene instead of passing it.

The probe is kept at tools/mac/paneldrive.swift for the next question
the tree can answer, the ScopeProbe precedent.

VERBS, one pair, mirroring the alert's: `expect_file_dialog` reads the
REAL live panel (never the request's copy — a backend that materialized
nothing must fail), and `file_choose <basename>` / `file_choose cancel`
answers it. check-verbs will require both in BOTH interpreters, which
is the usual mid-milestone red.

## §6 — green on mac, then fan out

`cargo test`, the fast gates, `tools/validate-mac.sh`. Expect
check-verbs and check-sugar-surface to be RED between §1 and the
sweep — they are designed to hold the remaining work open, and that is
not a regression (CLAUDE.md, Sequencing). Only after mac is green:
Compose, GTK, WinUI, then the seven remaining languages with an
explicit do/can't/defer verdict each, then `tools/validate-all.sh`.

## §6d — Compose, and the source a content:// URI needs — DONE

Landed 2026-07-31: the apply arm, the three verbs, and the URI-holding
source. The android lane runs 46 legs, the matrix 813, all pass. What
follows is the design record and the measurements behind it.

The accessibility service is landed and verified bound (docs/traps.md),
so the harness can read and drive DocumentsUI. What remained at the time
of writing was the apply arm and the source behind the handle, and the
second was the real design question — both answered below, and both
shipped in the same 2026-07-31 landing this section's heading records.

`kaya_emit_file_dialog_result` built a `PathSource` for every
interpreter platform, and that cannot work here: DocumentsUI
answers with a `content://` URI, and `PathSource::open` is
`std::fs::OpenOptions::open`, which has no idea what that is.

Two shapes, and the deciding constraint is RE-OPENABILITY. A handle is
redeemable more than once on purpose — that is what lets save-back work
without pinning a writable descriptor from the moment of the pick
(DESIGN.md, measurement 7).

- **The interpreter opens it and hands over a descriptor.** Simplest,
  needs no new JNI, and gives up re-openability: an already-open fd
  cannot be opened again. It would make Android the one platform where
  a second `open` fails, which is a semantics divergence the binding
  conventions do not allow.
- **A source holding the URI, opening through the ContentResolver.**
  `open()` calls into the JVM — `openFileDescriptor(uri, mode)` then
  `detachFd()` — so every redemption is a real open and the semantics
  matches the other four platforms exactly. Costs a global JVM
  reference per live handle and a Kotlin helper reached the way
  KayaPresent's natives already are.

The second is the one to build. The first is recorded only so nobody
re-derives it and mistakes it for the cheap option: it is cheap because
it drops the property the vocabulary promises.

### What the probe measured (tools/android/pickerprobe, API 35, google_apis)

Every arm before this one had an assumption overturned by measuring, so
this one was measured first. The probe is a throwaway app with its own
copy of the accessibility service; run.sh drives four variants of the
question, because the picker is modal and one run answers one.

1. **The picker's package is `com.google.android.documentsui`** on
   google_apis images. `KayaHarnessAccessibility.PICKER_PACKAGE` says
   `com.android.documentsui`, which is the AOSP spelling. Both exist;
   the reader has to accept either and say which windows it DID see when
   it finds neither.
2. **Shared storage is writable with ordinary file I/O**, from an app
   targeting 35 with no storage permission declared and
   `isExternalStorageManager` false: `Documents/` and `Download/` both
   take a `mkdirs` and a write. `/data/local/tmp` does not.
3. **`java.io.tmpdir` and the `TMPDIR` env var are the same string** —
   the app's cache dir — so Rust's `std::env::temp_dir` and
   KayaCompose's `kayaTempDir` DO agree, and the existing comment
   claiming so is right. It does not help: DocumentsUI cannot browse
   app-private storage, so the SCENE's directory cannot live under it.
   `$TMP` on Android has to mean the shared Documents directory, on both
   sides. `EXTERNAL_STORAGE=/sdcard` is in the process environment, so
   the guest finds it with `std::env::var` and no JNI.
4. **`EXTRA_INITIAL_URI` aims the picker**, given the ExternalStorage
   provider's document id (`primary:Documents/<dir>`). Aimed at a
   directory the platform hides — `Android/data/...` — it is accepted
   and SILENTLY lands on Recent instead. The first probe run did exactly
   that and read like the extra being ignored.
5. **`activityResultRegistry.register` then `launch` works from a
   RESUMED activity**, which is when the apply pump runs. No
   lifecycle-scoped registration, no restructuring of the Activity.
6. **The service reads the picker's tree**: rows are `item_root` (a
   clickable CardView) with the basename on a descendant `title`; the
   directory is on the last `breadcrumb_text` and in `header_title`
   ("Files in <dir>").
7. **The click IS the answer** — `performAction(ACTION_CLICK)` on
   `item_root` returns the document immediately. There is no Open button
   to press, and with `EXTRA_ALLOW_MULTIPLE` a single click still
   answers through `data.data` with an empty clipData.
8. **Cancel is BACK, and one is not enough**: the first backs walk UP
   the directory tree, and only the one taken at the root dismisses.
   Three, from the depth the scene aims at. So it is a bounded loop with
   the picker being gone as the proof — the same shape the press already
   needed on every other platform.
9. **The drive must not run on the main thread.** `getWindows()` is
   refreshed on the service's main looper, which is this app's, so a
   drive that blocks main reads a FROZEN window list and reports the
   picker still up when it has already gone. Measured: the same cancel
   loop said `backs=8 gone=false` on the main thread and `backs=3
   gone=true` off it.
10. **The URI is re-openable** — the property the source design was
    chosen for, now measured rather than assumed: three redemptions
    (two on the main thread, one on a worker) each returned a fresh
    descriptor carrying the whole file. The descriptor is a regular
    file and seeks. `rw` and `w` both succeed when the intent carried
    `FLAG_GRANT_WRITE_URI_PERMISSION`.
11. **`w` does not truncate.** The file kept its 12 bytes. `PathSource`
    opens Write with `.truncate(true)`, so Android's mode string has to
    be `wt` or the same `FileMode::Write` means two different things on
    two platforms — exactly the divergence the binding conventions
    forbid.
12. The advisory filter is an EXTENSION on the wire and the intent wants
    MIME types: `MimeTypeMap` maps `txt` to `text/plain`, and the rows
    still list.

## §6e — iOS, and the eyes that had to go on the host

MEASURED FIRST, and the first measurement killed the obvious plan:
`UIDocumentPickerViewController` is a remote view controller and
publishes nothing in-process, so the harness cannot read or drive it
from inside the app the way every other backend does. iOS has no
accessibility service to install either. Full detail in docs/traps.md.

NO CARVE-OUT WAS NEEDED, which is the point worth recording. The
simulator's own frameworks — private, shipped inside Xcode, the same
surface `simctl` uses — expose both halves from the HOST:

- **Reading**: `-[SimDevice sendAccessibilityRequestAsync:...]` with an
  `AXPTranslator` bridge delegate. Hit-test a point to learn the
  picker's pid, `translationApplicationObjectForPid:` for its root, and
  `AXPMacPlatformElement` to read the tree through the legacy
  `accessibilityAttributeValue:` API.
- **Driving**: `IndigoHIDMessageForMouseNSEvent` sources a digitizer
  payload, re-enveloped as a single-touch message and delivered by
  `SimulatorKit.SimDeviceLegacyHIDClient`.

That is the iOS analogue of Android's accessibility service: a
validation-only capability that reaches outside the app, never shipped
to a user. It lives in tools/ios/simdrive, whose three verbs — `state`,
`choose <name>`, `cancel` — are proved against a throwaway app
(tools/ios/pickerprobe): the rows read out of DocumentsUI's process, and
both drives answered the picker for real.

Also measured, and both decide the arm: `directoryURL` DOES aim the
picker, and the app's own Documents directory is browsable by it when
the bundle declares `UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace` — so the guest writes the scene's
files there with ordinary file I/O, as it does everywhere else.

THE RISK, stated rather than discovered later: this is private API, and
idb's own source records that the HID client has RELOCATED between Xcode
versions. simdrive looks it up by name and fails loudly with the name it
could not find, which is the most a consumer of that surface can do.

§6e IS DONE. The apply arm presents the picker and aims it, the source
holds the security-scoped URL and starts/opens/stops on every redemption
(the path is never published, because it EPERMs once the scope drops),
the in-process verbs ask the host through a two-file bridge in the app's
own container, and the leg runs in the lane. The iOS lane is green, 42
legs.

Three things the first working driver did not survive, all now in
docs/traps.md: an unretired accessibility token stops the TAPS while the
reads keep working; multi-selection is select-then-confirm rather than
tap-to-answer; and a picker aimed into a subdirectory has no Cancel at
all, so the drive walks back to where one exists.

## §6f — the seven remaining guest languages, with verdicts

The wire records are generated for every binding already, so what each
language owes is three things: the request sugar (`pick_files` /
`pick_file` / `filter` / `show`), the result binding (`on_files`), and
`PickedFile.open(mode)` on top of `kaya_open_picked`, which is exported
and unit-tested today.

ONLY THE THIRD IS REALLY PER-LANGUAGE, and it is per-language BY DESIGN:
the opened handle is the OS's own integer — a descriptor on POSIX, a
HANDLE on Windows — precisely so each runtime converts it with its own
file API rather than through a CRT fd that only the CRT that minted it
would accept (DESIGN.md).

| language | how it takes the handle | verdict |
| --- | --- | --- |
| Python  | `os.fdopen`; `msvcrt.open_osfhandle` on Windows | do |
| Go      | `os.NewFile`, which takes a HANDLE on Windows    | do |
| C#      | `new FileStream(new SafeFileHandle(...))`        | do |
| Swift   | `FileHandle(fileDescriptor:closeOnDealloc:)`     | do |
| OCaml   | `Unix.file_descr`                                | do |
| Haskell | `System.Posix.IO.fdToHandle`, Windows branch     | do |
| Java    | a JNI-built `java.io.FileDescriptor`             | do |

JAVA WAS THE ONE IN DOUBT, and it is a `do` — measured 2026-07-31
rather than argued. Java has no public API for wrapping a descriptor,
and the obvious route is dead: reflecting into `java.io.FileDescriptor`'s
private `fd` throws `InaccessibleObjectException` on JDK 17, because
`java.base` is not open. Reaching it would mean every kaya Java app
launching with `--add-opens java.base/java.io=ALL-UNNAMED`, which is a
requirement a binding has no business imposing on its users.

JNI HAS NO SUCH RESTRICTION. A probe built for this — a native method
that constructs a `FileDescriptor` through its public no-arg constructor
and sets the private field with `SetIntField` — populated it with NO
flags of any kind, `valid()` answered true, and an ordinary
`new FileInputStream(fd)` read the file. That is the route kaya already
owns: the JVM tier's natives are registered from Rust
(`jvm.rs::register_ring_natives`), so this is one more entry on a
surface that exists, not a new mechanism. Android has an even shorter
path if wanted — `ParcelFileDescriptor.adoptFd` — but the JNI route is
one implementation for both JVMs.

Two details the JDK source settles, so they are not rediscovered:
`FileDescriptor` carries BOTH an `int fd` (Unix, and sockets on Windows)
and a `long handle` (Windows regular files), so the Windows arm sets the
other field; and the cleaner is registered SEPARATELY from setting the
descriptor — so leaving it unregistered is correct here, because the
guest owns the descriptor and closes it, and a JDK cleaner would close
it behind the guest's back.

The probe is not kept: unlike the platform probes, its question is about
the JDK rather than a device, and the answer above is the whole of it.

## What is already done and needs no re-litigating

The vocabulary, the deferred open with its measured 256-descriptor
justification, mode-on-open, `seekable` riding the open, `local_path`
as a re-openable name, cancel as the empty list, filters as advisory,
kaya's own selection structure, and the seven on-device measurements
including that the open picker DOES grant write. All in DESIGN.md.

Deferred with stated reasons, also in DESIGN.md: save (creating a
document that does not exist yet — DEFERRED NO LONGER: shipped
2026-08-10, docs/save-plan.md), directory selection, explicit handle
release, and persistence across restarts for a recents list — which has
three different spellings and a trap, since the macOS security-scope
bookmark flag is `API_UNAVAILABLE(ios)` and iOS uses a plain bookmark
instead.
