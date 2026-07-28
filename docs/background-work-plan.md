# Background work — the executable plan

Sequenced BEFORE file dialogs (docs/file-dialogs-plan.md), which is
where the gap was found. The ledger entry in docs/deferred.md has the
evidence; this file is the slice.

**THE HOLE.** A kaya app cannot do work off the app thread and show the
result. Nothing posts back: `App` is not thread-safe, no binding has a
post primitive, and the app thread's only wake-up is
`kaya_wait_occurrences`, blocked in C. So today a guest either blocks
the app thread — the window keeps drawing while input stops doing
anything, which is the worst failure mode because it looks alive — or
computes on its own thread and cannot write the answer anywhere.

**WHY IT COMES FIRST.** File dialogs kept trying to invent this
privately. Without a post, the open has to arrive as a callback, and
then the READ after it has nowhere to go either, so an app ends up in
continuation-passing style one step at a time. With a post, the open is
an ordinary blocking call on a thread the guest chose, and the file
design collapses to something small. The same is true of clipboard,
notifications, and any app that wants to make an HTTP call.

**NO BACKEND WORK.** Not one line of SwiftUI, Compose, GTK or WinUI.
This is the core's ring, the C ABI, eight bindings, and a scene.

## §1 — the wake, in the core

`ring.rs`'s `wait_nonempty` is a condvar loop over `head != tail` with a
`shutdown` flag. Add a wake alongside it: a flag the waiter clears, so
`wait_nonempty` returns "go look at your own queue" rather than "the
ring has something". Then `kaya_wake()` sets it and notifies the same
condvar. Roughly fifteen lines plus the header regen.

CLOSURES NEVER CROSS THE C ABI, deliberately. The floor says only "wake
up"; every binding keeps its own queue of its own closure type. A
function-pointer-plus-void-star queue in C would be one uniform
mechanism, and it would also be the worst spelling available in seven of
the eight languages.

## §2 — the per-binding queue

Each binding grows a thread-safe queue and drains it in the occurrence
loop it already runs, before blocking:

```
loop {
    drain_posted()          // run each closure as its own transaction
    if ring has a record { dispatch it; continue }
    if !wait()             { return }   // shutdown
}
```

The Go shape, for reference — its loop is in `App.Run`, the dispatch is
`a.dispatch(fn)`, which is already "run this closure as a transaction".
Posting is therefore `a.dispatch` deferred, not a new concept.

## §3 — what must be ratified before code

- **THE NAME.** The literature is consistent — Android `Handler.post`,
  Qt `postEvent`, Win32 `PostMessage`, Swing `invokeLater` — but every
  one of those posts to the UI thread, and kaya's target is the APP
  thread. A name that implies the wrong thread is worse than a duller
  one that does not.
- **It runs as its own transaction.** Falls out of dispatch already
  calling the transaction entry, and it is what makes a posted closure
  atomic exactly like a handler.
- **Ordering.** FIFO among posts. Between a post and an occurrence there
  is no natural order — they arrive on different queues — so promise
  NOTHING rather than promise something that must then be enforced.
- **Shutdown.** What happens to posts still queued when the core stops.
- **Posting from inside a handler.** Queues for after; never nests.

## §4 — the guard, which is half the point

The rule: **from a background thread a guest may call exactly ONE
method, the post. Everything else needs a `Tx`, and a `Tx` exists only
inside a transaction on the app thread.** Ids — signals, widgets — are
values and are meant to be captured; that is how a posted closure
addresses state.

Uniform semantics, spelled per language:

- **Rust already enforces it at compile time, for free.** `Tx<'a>`
  borrows `&'a AppCtx`, and `AppCtx` holds `Cell`/`RefCell`, so it is
  `!Sync`, so `Tx` is `!Send`, so `thread::spawn` refuses it. Nobody
  designed this; pin it with a `compile_fail` doctest before it
  evaporates under some future refactor.
- **Go currently fails SILENTLY and must not.** `tx.Write` and
  `tx.Signal` append to `tx.records` without checking the `closed` flag
  the Widget chain methods do check, so a write through a captured `Tx`
  vanishes with no panic and no error. Fix, then audit every `Tx`
  method.
- **The other six**: same audit, same negative test. A language that
  cannot make it a compile error makes it a loud failure.

This is invariant 3 in its usual form: the failure class gets a
structural guard at the strongest tier each language allows, plus a
negative test, rather than a note asking people to remember.

## §5 — the scene

`tools/scenes/background.steps` (name follows the primitive's). NO NEW
HARNESS VERBS — `click` and `expect` carry all of it, which is worth
protecting: every new verb costs an arm in BOTH interpreters.

THE DESIGN PRINCIPLE: a wrong implementation must DEADLOCK, not merely
disagree. The worker parks until a CLICK releases it, and a click can
only be processed by a live app thread. So a binding that lets
background work occupy the app thread cannot reach the end of the
script at all — it cannot even deliver its own release. That is much
stronger than observing a different value, and it is what stops the
scene passing for an implementation that simply blocked.

```
expect label#0 "idle"
click button#0
expect label#0 "working"          # the worker started and PARKED

# THE CLAIM. The worker is parked, nothing is posted, and the app
# thread must still be serving input.
click button#1
expect label#1 "alive"

# Nothing has been posted YET. This separates a real background post
# from a guest that computed everything eagerly on the app thread and
# only pretended to park — that guest reaches here already showing the
# final value.
expect label#0 "working"

click button#2                    # release
expect label#0 "123"              # three posts, IN ORDER

# A post from INSIDE a handler QUEUES; it never nests. The handler
# appends "a", posts a closure appending "b", appends "c" — so the
# handler commits "ac" and the posted closure commits "acb". A nested
# implementation runs the closure between them and can only ever
# produce "abc"; the two strings are unreachable from each other.
click button#3
expect label#2 "acb"

# One real-tree read, because every assertion above is kaya's own
# model and would pass for an arm that ran and drew nothing.
expect_ax label#2 "label/acb"
```

WHAT EACH LINE KILLS, checked adversarially:

- posts dropped, or drained only when an occurrence happens to arrive
  -> the "123" expect polls its five seconds and fails;
- a LIFO queue instead of FIFO -> "321", deterministic, not a race;
- `Post` running the closure inline on the caller -> the nesting test
  gives "abc". This is the discriminator for the whole roster, since a
  thread-identity assertion is not expressible in a scene;
- a guest that fakes the background thread -> the mid-script "working"
  expect catches it, because its value would already be final;
- background work occupying the app thread -> deadlock, as above.

WHAT THE SCENE CANNOT GATE, stated so nobody believes otherwise. THE
WAKE ITSELF is not deterministically exercised here. After the release
click the app thread is freshly awake, and whether it re-enters
`wait_nonempty` before the worker posts is a genuine race won either
way on a multicore host — so a missing `kaya_wake()` would fail this
scene only sometimes, and a flaky gate is worse than an honest gap.
The wake belongs in `cargo test`, where the waiter can be observed
parked before the post is issued, and that observation is the only new
test-only surface this slice needs.

TRAP TO AVOID IN THE JVM GUESTS: a parked NON-DAEMON thread keeps the
JVM alive. On a passing run the worker is released and exits, so it
never shows; on a FAILING run the guest hangs instead of reporting,
which converts a clear failure into a timeout. Make the worker a
daemon thread in the Java and Kotlin guests.

## §6 — the ladder

`cargo test -p kaya --features harness --locked`, the fast gates,
`tools/validate-mac.sh`, then the eight-language sweep with an explicit
do/can't/defer verdict each, then `tools/validate-all.sh`. Then file
dialogs, whose §0 shrinks to almost nothing once this exists.
