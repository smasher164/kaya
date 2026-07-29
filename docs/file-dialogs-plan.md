# File dialogs — the executable plan

**BLOCKED ON docs/background-work-plan.md, deliberately.** Working
through §0 below is what found the real gap: kaya has no way to do work
off the app thread and post the result back, so a late-arriving result
has to be delivered as a callback, and then the READ after it has
nowhere to go either. Every shape considered here was an attempt to
invent that primitive privately. Build it first and most of §0
disappears: the open becomes an ordinary blocking call on a thread the
guest chose.

The design is RATIFIED and lives in DESIGN.md's "File dialogs" section;
read it first, this file does not repeat it. Measurements behind it are
in that section and in docs/traps.md. Nothing below is a design
decision except §0.

Sequencing follows CLAUDE.md's depth-then-breadth rule: protocol, one
backend (SwiftUI on mac), one binding (Rust), the scene, green on mac.
Only then fan out.

## §0 — what is left to settle before spec.rs is touched

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

New `tools/scenes/filedialog.steps`. THE HARD PART IS THAT A FILE
DIALOG IS MODAL AND SYSTEM-OWNED, exactly like alerts — so copy the
alert verbs' shape: a verb that reads the REAL panel, and a verb that
answers it. Do not stamp a verdict the arm wrote about itself
(check-verbs' stamped-observation rule exists for this).

Open question to answer when writing it: what file does the scene pick?
It must exist on all five lanes and be byte-identical, so it probably
has to be created by the runner rather than shipped.

## §6 — green on mac, then fan out

`cargo test`, the fast gates, `tools/validate-mac.sh`. Expect
check-verbs and check-sugar-surface to be RED between §1 and the
sweep — they are designed to hold the remaining work open, and that is
not a regression (CLAUDE.md, Sequencing). Only after mac is green:
Compose, GTK, WinUI, then the seven remaining languages with an
explicit do/can't/defer verdict each, then `tools/validate-all.sh`.

## What is already done and needs no re-litigating

The vocabulary, the deferred open with its measured 256-descriptor
justification, mode-on-open, `seekable` riding the open, `local_path`
as a re-openable name, cancel as the empty list, filters as advisory,
kaya's own selection structure, and the seven on-device measurements
including that the open picker DOES grant write. All in DESIGN.md.

Deferred with stated reasons, also in DESIGN.md: save (creating a
document that does not exist yet), directory selection, explicit handle
release, and persistence across restarts for a recents list — which has
three different spellings and a trap, since the macOS security-scope
bookmark flag is `API_UNAVAILABLE(ios)` and iOS uses a plain bookmark
instead.
