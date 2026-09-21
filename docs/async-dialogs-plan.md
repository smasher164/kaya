# Async dialogs beyond JS — approved design and implementation record

The ruling this document serves is R1 in docs/deferred.md's idiom entry:

> ASYNC DIALOGS beyond JS for Swift, C#, Java and Rust under one rule — no
> handler given, a dialog answers a future; the continuation runs on the app
> thread, with explicit transactions after suspension — with Python, Haskell and OCaml stated as the
> carve-out (no native async runtime on the app thread), the way
> docs/js-plan.md §4 names the languages that cannot spell the implicit
> transaction. Python's `await` form is the survey's one SEMANTICS finding and
> is not taken.

JS has the feature already (docs/js-plan.md §4, rule 2). This document says what
the same rule means in the other four, states each mechanism from zero before it
uses it, and ends with the rulings and the order of work. Akhil approved all seven
recommendations in §5 on 2026-09-19 ("go ahead"). The C# dialog APIs passed the
full five-lane matrix on 2026-09-20, followed by Swift and Java the same day.
Rust completed the four-tier implementation on 2026-09-21. The Swift executor
prerequisite has shipped (§2.1). The implementation order is recorded in §6.

Every claim about a platform below was MEASURED with a small probe, not recalled;
the probes are reproduced in §2 so a later session can re-run them.

**Amendment approved 2026-09-19; work resumed 2026-09-20:** the transaction is
the unit of atomicity, not the whole continuation. Akhil adopted the amendment
with three additions: Java completes futures outside transactions; this plan is
rewritten rather than annotated; all four new tiers share the honest failure
sentence in §1.4. The original probes measured scheduling, not rollback; the
real-binding evidence and nine-language assessment are in
docs/measurements/async-dialogs-csharp-2026-09-19.md. The other six approvals stand.

## §1 THE ONE RULE

### 1.1 What a dialog is today, from zero

A dialog in kaya is a REQUEST and a RESULT, never a blocking call. The guest, from
inside a transaction, asks the platform to show an alert (or a file picker, a save
panel, a clipboard read). The request carries an id the binding allocated. The
transaction commits, the app thread goes back to its loop, and the platform shows
the dialog with nothing waiting on it. When the user answers, the answer arrives on
the app thread as an occurrence carrying that id, and the binding routes it to the
one-shot handler that rode the request. The id retires with the answer.

Everything the guest sees is in that paragraph: the handler runs on the app thread,
it runs as its own transaction, and it runs exactly once. DESIGN.md's "Alerts"
section states the grammar and the one-live-dialog-per-process rule; the confirm
scene (tools/scenes/confirm.steps) exists to make the association visible — two
buttons, two dialogs, two handlers, no id inspection anywhere.

Today that handler is a CALLBACK in all nine bindings. In C# and Swift it is an
`onResult:` argument; in Java it is `.onResult(…)` chained on the request; in Rust
it is a message constructor bound through `Messages::on_alert`; in JS it is either
an `onResult` option or — since 2026-09-01 — nothing at all, in which case the
dialog answers a promise.

### 1.2 The rule

**When no handler is given, a dialog answers a future, and awaiting it is a
transaction boundary.** Precisely, and identically in Swift, C#, Java and Rust:

1. **It is the same occurrence.** No second request, no polling, no new wire
   record, no new core code. The binding registers its own internal one-shot
   handler, and that handler resolves the future instead of calling guest code.
   A guest that passes a handler gets today's behaviour unchanged.
2. **The continuation runs on the app thread.** Not on a thread pool, not on the
   platform's UI thread, not on `MainActor`. Every binding already owns an
   app-thread work queue for exactly this — `post(body)` appends under a lock and
   rings `kaya_wake()`, and the loop drains it at the top of every turn — so the
   suspension machinery is routed into that queue and nothing new is invented.
3. **The transaction is atomic; the continuation is not a transaction.** Async
   jobs resume with no transaction open. Writes use explicit Build/build/apply
   scopes: each commits on return or rolls back if its synchronous body throws.
   The raw job queue must not route through the transactional public post API.
4. **THE AWAIT IS A TRANSACTION BOUNDARY.** The handler's transaction commits at
   the suspension point. It has to: the dialog's answer arrives through the app
   loop, so the loop must be free to turn, and a transaction that stayed open
   across the suspension would hold the batch for however long the user stares at
   the dialog. This is the same sentence docs/js-plan.md §4 rule 1 states for JS,
   arrived at from the other direction.
5. **Synchronous callback semantics do not change.** A throw crossing its
   transaction boundary rolls that transaction back. An async failure reaches
   the async reporter, which cannot undo a transaction that already returned.

### 1.3 What is spelling, per language

The rule above is the semantics, uniform by invariant 1. What each language
chooses is only:

- the NAME of the awaitable form (whether one name serves both or the async form
  gets its own — §5 R1.1);
- the TYPE the future is (`async` function, `Task<T>`, `CompletableFuture<T>`,
  `impl Future<Output = T>`);
- WHERE the await may appear, which follows from each language's own concurrency
  model and is stated per language in §2.

What is NOT spelling, and must be one thing everywhere: the value a cancelled
dialog answers (§5 R1.3), whether a second dialog while one is live is refused
(§5 R1.2), and what a throw between the show and the continuation leaves behind
(§1.4).

### 1.4 The residue, stated

**The transaction is the unit of atomicity in all nine bindings.** Writes
committed before suspension stand. In Swift, C#, Java and Rust, a continuation
resumes with no transaction open. A throw inside explicit Build/build/apply
rolls back that scope; scopes that returned remain committed. A throw outside
a scope rolls back nothing. The dialog id retires independently of the outcome.

The four new tiers report the exception separately, followed by this one sentence:

```text
kaya: async handler failed; no transaction was rolled back by this reporter; completed transactions remain committed
```

It does not assert that suspension occurred or that a scope rolled back. A scope
that threw already performed its own rollback before the reporter saw the error.
Synchronous callbacks keep their existing rollback sentence.

Task ownership clarified and approved 2026-09-20: Kaya reports errors escaping
async work handed to Kaya. Independently created tasks and future chains remain
their creator's responsibility. Swift's entry is app.task; a plain or nested raw
Swift Task must have its error handled by the guest. The launcher does not open
a transaction or acquire SwiftUI's view-lifetime cancellation semantics.

JS keeps its ruled implicit continuation transaction and its existing failure
sentence. Its language limit is stated in docs/js-plan.md §4: "nothing sees a
continuation throw, so the writes before the throw stand". An explicit JS build
or post still provides rollback for its synchronous body. The earlier version
of this plan incorrectly described JS as rolling back a failed continuation.

If the guest never awaits the future — drops it, or returns without resuming — the
result still arrives, the internal handler still resolves the future, the id still
retires, and nothing runs. That is a dropped answer, not a leak, and it is what a
guest that passed no handler and ignored the id gets today.

## §2 PER LANGUAGE, THE MECHANISM FROM ZERO

The shared picture first, because all four bindings already have it:

```
  process main thread                      kaya's APP THREAD
  ───────────────────                      ─────────────────
  kaya_run()  ──► the platform loop        dispatchLoop():
                  draws, shows dialogs       drainPosted()          ◄── post(body)
                  answers arrive here        kaya_next_occurrence()  (any thread)
                                             → dispatch(build(handler))
```

kaya's app thread is NOT the process main thread on any platform (DESIGN.md,
Threading model: "exactly one UI thread runs all native-widget code and the core's
dispatcher; app logic runs on a separate thread"). Every mechanism below therefore
has to answer one question: **when the dialog's answer arrives, what makes the
continuation run on the app thread rather than wherever the language's runtime
would like to put it?**

### 2.1 Swift — a custom executor bound to the app thread

**From zero.** Swift's `async`/`await` does not name threads. A suspended
function resumes on an EXECUTOR — an object whose only job is to run scheduled
pieces of work. By default that is the "cooperative pool", a set of threads the
Swift runtime owns. `@MainActor` names a different executor, the one that runs work
on the process main thread. Since Swift 5.9 (SE-0392) a program may supply its
OWN executor by writing a type that conforms to `SerialExecutor` and attaching it
to an actor; `SerialExecutor` has one required method, `enqueue`, which is handed a
job and must eventually run it.

**What `@MainActor` would wrongly imply.** It is the obvious annotation and it is
wrong here: it would claim kaya's app logic runs on the process main thread, which
by architecture it does not. That is not a harmless inaccuracy. Measured: a call to
`MainActor.assumeIsolated` — the escape hatch such a pass reaches for when the
compiler wants proof — **traps with SIGTRAP on a non-main thread**, with nothing on
stdout or stderr:

```
off-main thread: isMainThread=false
about to call MainActor.assumeIsolated
→ exit -5 (SIGTRAP)
```

So `@MainActor` on kaya's Swift tier is not a white lie; it is an armed one.

**The mechanism.** A global actor whose executor enqueues onto the app loop's own
queue. Measured working, in Swift 6 language mode, with no warnings:

Follow-up, 2026-09-18: the guest executor slice is recorded in
docs/measurements/swift-executor-2026-09-18.md. The sample below was the
original isolated probe, not the production implementation. The deployment
floors require the older UnownedJob enqueue spelling, and Swift jobs must
enter the loop without an implicit transaction around the job.

```swift
final class KayaAppExecutor: SerialExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let me = self
        appQueue.push { unowned.runSynchronously(on: me.asUnownedSerialExecutor()) }
    }
    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

@globalActor actor KayaAppActor {
    static let shared = KayaAppActor()
    private static let executor = KayaAppExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        KayaAppActor.executor.asUnownedSerialExecutor()
    }
}
```

`appQueue.push` is the existing `KayaApp.post` door: append under the lock, call
`kaya_wake()`, and let `drainPosted()` run it at the top of the next turn. The probe
ran a handler on that queue, awaited a "dialog" answered from a different thread
50 ms later, and printed the thread ids:

```
[app thread] drain loop starts on tid=218057072
  [handler] before await, tid=218057072
  [ui thread] answering from tid=218057074
  [handler] after await choice=1, tid=218057072
  [handler] same thread as the app queue's drain loop? true
```

**The spelling** (the confirm scene's alert, guests/swift/confirm.swift, is the
running example). Today:

```swift
tx.button("delete", onClick: { inner in
    inner.showAlert(
        title: "delete item?", message: "this cannot be undone",
        actions: ["Delete", "Archive"], cancel: "Keep"
    ) { tx, choice in
        tx.write(status, .str(choice == .cancel ? "kept" : "deleted"))
    }
})
```

With the future form, the handler becomes an `async` function on the app actor and
the dialog is asked of the APP, not of a live transaction — because the
transaction the click opened has already committed by the time the answer arrives:

```swift
@KayaAppActor
func askDelete() async {
    let choice = await app.showAlert(
        title: "delete item?", message: "this cannot be undone",
        actions: ["Delete", "Archive"], cancel: "Keep")
    app.build { tx in tx.write(status, choice == .cancel ? "kept" : "deleted") }
}
…
tx.button("delete", onClick: { _ in app.task { await askDelete() } })
```

`app.showAlert(…) async` opens its own transaction to send the request, suspends,
and resolves with the choice. The existing executor runs the resumed job without
an ambient transaction; the explicit build above is the write's atomic scope.

**Where `.await` may appear:** inside a function isolated to `@KayaAppActor`, and
nowhere inside a `build` closure or a For template body — a declaration trace runs
once and synchronously, and a suspension inside it would leave a half-authored
blueprint, which the core already refuses by name.

**How Swift 6 strict concurrency constrains it (Part 1's measurement).** The
binding package already compiles in Swift 6 with four audited
`nonisolated(unsafe)` sites; the SwiftUI interpreter remains 418 measured
build-breaking diagnostics away. The guest follow-up corrected the original
proposal: Swift rejects a custom global actor on a top-level-code variable.
State belongs inside the `KayaApp.run { app in ... }` actor-isolated entry,
whose construction and handlers run on the executor's app thread. R1 can reuse
that executor; it does not need to migrate the interpreter with the guests.

**The guard.** The rule "the continuation runs on the app thread" is exactly
`check-tx-liveness`'s existing rule, one suspension later: Swift's `Tx` refuses a
write through a closed transaction at its single chokepoint (the `tx` property), so
a guest that keeps its `tx` across the await and writes through it is refused by
the guard that already exists. §6 says what must be ADDED.

**Task ownership approved 2026-09-20.** A plain Swift Task does not fulfill
§1.4's failure-reporting promise when its
body throws. Swift retains the error in the Task's result rather than throwing
it from the executor's runSynchronously. A real-binding probe delivered an alert
through the core, resumed on the right thread with no transaction, committed
one explicit scope and threw: zero failure reports. Reading the task result or
catching inside a task wrapper reported it once. Akhil approved app.task
with an actor-isolated async throwing body, owned by the binding for reporting;
raw Swift Tasks remain the guest's responsibility. This is an error-observation
boundary, not an error store or a requirement for awaiting a dialog. Four
observations and three counted negatives:
docs/measurements/async-dialogs-swift-2026-09-20.md.

### 2.2 C# — a SynchronizationContext for the app thread

**From zero.** In .NET, `await` on a `Task` captures the "current synchronization
context" at the suspension point and posts the continuation back to it when the task
completes. A `SynchronizationContext` is an object with a `Post` method; whatever
`Post` does is where the continuation runs. This is the mechanism WinForms and WPF
use so that `await` inside a button handler resumes on the UI thread. If no context
is installed, the continuation goes to the thread pool.

kaya has no UI-thread requirement for guest code — it has an APP-thread
requirement — so the same machinery points at the app thread instead.

**The mechanism**, measured working:

```csharp
sealed class AppThreadContext : SynchronizationContext
{
    readonly BlockingCollection<(SendOrPostCallback, object?)> q = new();
    public override void Post(SendOrPostCallback d, object? state) => q.Add((d, state));
    // drained from DispatchLoop, beside DrainPosted()
}
```

installed once, on the app thread, at the top of `DispatchLoop` (which already calls
`ClaimAppThread()` there):

```
[app thread] loop on tid=4
  [handler] before await tid=4
  [ui thread] answering from tid=5
  [handler] after await choice=1 tid=4
  [handler] resumed on the app thread? True
```

The context queues raw jobs beside the existing transactional posted-work queue
and wakes the same app loop. It never implements Post through App.Post: the
real-binding probe measured that wrapper committing before the async-void
exception arrived. The drain refuses an open transaction and reports failures
with §1.4's sentence. It runs outside Build and Dispatch.

**The spelling** (guests/csharp/ConfirmScene.cs today passes `onResult:`):

```csharp
tx.Button("delete", onClick: async _ =>
{
    var choice = await app.ShowAlertAsync(
        title: "delete item?", message: "this cannot be undone",
        action0: "Delete", action1: "Archive", cancel: "Keep");
    app.Build(tx => tx.Write(status, choice switch {
        AlertChoice.Action0 => "deleted",
        AlertChoice.Action1 => "archived",
        _ => "kept",
    }));
});
```

**Where `await` may appear:** in any `async` method reached from a handler, and
NOT inside a `Build` body. C# has one sharp edge worth naming at ruling time: an
`async void` lambda (which is what `onClick: async _ => …` is) swallows its
exception into the captured context rather than to the caller. The binding's own
`Dispatch` catches synchronous callback failures. The raw context drain catches
the separately posted async-void exception and uses §1.4's async sentence, without
opening a transaction merely to report it.

**The guard.** `check-tx-liveness` again — the C# chokepoint is the `Records`
property, and the gate already pins the raw field to exactly two uses. A write
through a `Tx` captured across the await is refused there.

### 2.3 Java — the future's own chain, because there is no `await`

**Landed 2026-09-20 after the full five-lane matrix.** Completing a
dialog's future does not expose an exception thrown by thenAccept: the final
stage stores it, while the original dialog future succeeds. Observing only the
original future misses it. Eight cases and six counted negatives against the
real binding are in docs/measurements/async-dialogs-java-2026-09-20.md. The
approved spelling is app.observe(finalStage), which hands Kaya that stage for
error reporting without changing its scheduling or transaction boundaries.
It observes only the handed stage, not branches appended afterwards. Guest
recovery belongs before observe. Fatal Errors remain fatal. Unlike app.post,
observe neither schedules guest work nor supplies a transaction.

**From zero.** Java has no `await`. Its standard future type is
`CompletableFuture<T>`: a value that is completed later, with a chain of
continuations attached to it — `thenAccept(fn)` runs `fn` with the result,
`thenApply(fn)` transforms it. Where a continuation RUNS is the part that matters
here: `thenAccept` may run on whatever thread completed the future (i.e. the
platform's), while `thenAcceptAsync(fn, executor)` runs it on the executor you name.
An `Executor` in Java is an interface with one method, `execute(Runnable)`.

kaya's app thread is already an executor in all but name: `app.post(Consumer<Tx>)`
appends and wakes.

**The mechanism**, measured working:

```java
static final BlockingQueue<Runnable> queue = new LinkedBlockingQueue<>();
static final Executor appThreadExecutor = queue::add;   // drained by dispatchLoop
…
showAlert().thenAcceptAsync(choice -> { … }, appThreadExecutor);
```

```
[app thread] loop on tid=28
  [ui thread] answering from tid=29
  [handler] continuation choice=1 tid=28
  [handler] ran on the app thread? true
```

The production completion is queued as a raw app-thread job, not through the
transactional app.post. Completing a CompletableFuture inside Dispatch can run
thenAccept immediately inside the result handler's transaction. The completion
job must instead run with no transaction open, with a runtime refusal and a watched
negative if that boundary is lost.

**The spelling** (the callback chain remains available):

```java
tx.button("delete", inner -> app.observe(inner.showAlert()
        .title("delete item?")
        .message("this cannot be undone")
        .action("Delete").action("Archive").cancel("Keep")
        .showFuture()                       // no .onResult: answers a future
        .thenAccept(choice -> app.build(t -> {
            t.write(status, switch (choice) {
                case ACTION0 -> "deleted";
                case ACTION1 -> "archived";
                case CANCEL  -> "kept";
            });
        }))));
```

Note `thenAccept`, not `thenAcceptAsync(…, executor)`: the binding completes the
future ON the app thread, in a raw job after the answer occurrence's dispatch,
so a chain attached before completion runs there without an ambient transaction.
No executor is exposed (R1.6). A chain attached from another thread after completion
can run on that attaching thread; its writes are refused by the existing thread
check, just as a continuation using a foreign executor is.

**Where the continuation may appear:** anywhere — Java's future chain has no
syntactic scope. What must be refused is the same thing as everywhere else: a
`Tx` captured from the click and written through inside the continuation, which
`check-tx-liveness`'s Java chokepoint (`Tx.emit`, with `records.add(` pinned to
exactly one call site) already refuses.

**What virtual threads would NOT buy here.** The tempting alternative is to make
the handler a virtual thread and let it BLOCK on `future.get()`, which reads like
`await`. It is not available: measured 2026-09-17 on the JDK 21 slice, **ART has no
`Thread.ofVirtual()` at any compileSdk** — the API is absent from Android's runtime,
not merely gated — and the guest that had adopted one was reverted to
`new Thread(...)` in guests/java/dev/kaya/guests/Background.java for that reason.
Even on the desktop it would be the wrong shape: a blocked virtual thread is still
a thread with kaya's transaction invariants around it, and the app thread's single
loop is what makes "one handler, one batch" true.

### 2.4 Rust — the app loop IS the executor, with no runtime

**Scope-only transaction API approved 2026-09-20.** The first measurement found
that public begin lets a local future retain an owned Tx across an await, and
Send also rejects valid explicit-scope code. The follow-up demonstrated a
compile-time boundary through API design: begin becomes private, apply owns the
transaction and only lends it to a synchronous callback. Returning the borrow,
storing it outside, or returning a future or closure capturing it is refused.
Owned results and non-Send local state remain usable across awaits. Akhil approved
this design with a runtime reentry check as backup. The measurements and the
precise limit are in docs/measurements/async-dialogs-rust-2026-09-20.md.

**Scoped task owner approved 2026-09-20.** `let tasks = ctx.tasks()` borrows the
existing context; `tasks.spawn(async |app| { ... })` owns local async work, and
`tasks.next(&msgs)` drives it beside occurrences. Dropping the owner drops its
suspended futures before the borrowed context may move. AppCtx retains its
existing Send behavior; the task scope is local. Raw async loops use
tasks.next_occurrence. A live owner refuses the old ctx.next entry rather than
leaving tasks unpolled. Existing synchronous guests keep their current loop.

**From zero.** Rust's `async` has no runtime in the standard library. An `async
fn` compiles to a value implementing `Future`, which does nothing until something
POLLS it. Polling hands the future a `Waker`; if the future is not ready it stores
the waker and returns `Poll::Pending`, and whoever completes the work later calls
`waker.wake()` to say "poll me again". An executor is just a loop that polls futures
and parks between wakes. Tokio and async-std are large executors; kaya needs a
small local executor, because **kaya's app loop already waits on the channel
used for occurrences and posted-work wakes**. Scheduling still needs explicit
ownership, wake deduplication, reentry guards and shutdown cleanup.

**Rust's guest shape is different from the other three**, and this is the reason it
is last in §6. Rust guests do not register callbacks; they run a message loop:

```rust
while let Some(msg) = msgs.next(&ctx) {
    match msg {
        Msg::AskDelete => { let alert = ctx.apply(|tx| tx.show_alert()…show());
                            msgs.on_alert(alert, Msg::Deleted); }
        Msg::Deleted(choice) => ctx.apply(|tx| tx.write(status, …)),
    }
}
```

(guests/rust/confirm.rs, shortened.) The correlation is already explicit and
already readable; async buys Rust less than it buys the other three, and costs more.

**The mechanism**, measured working with no runtime and no dependency: a future
whose waker posts into the app loop's own channel, polled by the loop.

```rust
struct AppWaker(Sender<()>);
impl Wake for AppWaker {
    fn wake(self: Arc<Self>) { let _ = self.0.send(()); }   // the post door
}
let waker = Waker::from(Arc::new(AppWaker(wake_tx)));
let mut cx = Context::from_waker(&waker);
loop {
    match fut.as_mut().poll(&mut cx) {
        Poll::Ready(choice) => { /* the continuation, on the app thread */ break }
        Poll::Pending => { wake_rx.recv_timeout(…)?; }      // the loop parks
    }
}
```

```
[app thread] loop on ThreadId(1)
  [ui thread] answering from ThreadId(2)
  [handler] after await choice=1 on ThreadId(1)
  [handler] resumed on the app thread? true
```

**The spelling.** `async fn` handlers are OUT by ruling — the handler signature is
synchronous — so the await cannot go in a handler, and Rust does not have handlers
anyway. The shape that fits the message loop is a spawned task whose executor is
the loop:

```rust
Msg::AskDelete => tasks.spawn(async move |app| {
    let choice = app.show_alert()
        .title("delete item?").message("this cannot be undone")
        .action("Delete").action("Archive").cancel("Keep")
        .await;                                   // suspends; the loop turns
    app.apply(|tx| tx.write(status, match choice { … }));
}),
```

`TaskScope::spawn` boxes the future in the external owner. Its occurrence entry
polls ready tasks between occurrences; the alert builder's `IntoFuture` sends
the request in its own transaction and registers the one-shot resolver. Spawn
accepts unit-returning bodies and `Result<(), E>` bodies whose error implements
Display; returned errors and escaping panics reach the shared async reporter.
Guest recovery inside the body remains guest-owned. No join handle or foreign
executor is introduced.

**Where `.await` may appear:** Kaya drives futures handed to its task launcher;
other executors remain guest-owned. An await directly in apply's synchronous
callback is a compiler error. A future borrowing that callback's Tx cannot
escape it. Awaiting the synchronous msgs.next call is not an async loop API.

**The guard.** Private begin closes the owned-Tx escape hatch. apply's lifetime
boundary is held by compile_fail doctests and compiler probes in check-abort.
There is no claim that arbitrary safe Rust cannot manually poll a nested future
inside a synchronous callback: that shape compiles. Entering Kaya's occurrence
loop while any transaction is open must refuse before posted work or occurrences
run, including through Messages::next. Transaction-depth tracking survives both
commit and unwinding; the unit tests exercise the nested manual-poll route too.
The scheduler also refuses loop reentry while polling a task and drops stored
futures at shutdown. Thirteen real-binding headless tests exercise wakeups,
reply delivery, explicit-scope rollback, task error reporting and cleanup.
The four Mac dialog guests and the 49-leg recorded iOS Rust suite passed, as
did native alert recordings on Linux X11/Wayland, Windows and Android. The full
Mac lane passed 477 legs and all 61 gates passed. After correcting an Android
drag-source lifetime bug found by the first matrix, the final matrix passed
Mac 477, Linux 777, Windows 283, iOS 139 and Android 148 legs, plus 61 gates,
in 1072 seconds with every timing ceiling held. Runtime behavior is exercised,
not inferred from the original compiler measurement.

## §3 THE CARVE-OUT: Python, Haskell and OCaml keep the callback

Stated in the shape DESIGN.md uses for JS's implicit transaction, and for the same
reason the row-handle rule states its own carve-out:

> **Python, Haskell and OCaml keep the callback form.** A dialog in those three is
> answered by the handler that rode the request, exactly as it is today, and no
> awaitable spelling is added. The reason is not taste: the rule requires the
> continuation to run ON KAYA'S APP THREAD, and none of the
> three has a native way to resume a suspended computation there. Python's
> `await` resumes on whatever event loop is running the coroutine, and kaya's app
> thread runs no event loop — it runs the occurrence loop; making one run both
> would mean kaya scheduling `asyncio`, which is kaya owning the guest's runtime,
> the thing the binding does not do. OCaml's concurrency is a library choice (Lwt,
> Eio, or the 5.x effect handlers) and the binding takes none. Haskell's `IO`
> already sequences without a future type, and kaya's Haskell tier registers
> handlers on the App. The callback IS the continuation in all three, it already
> runs on the app thread as its own transaction, and it observes everything the
> future form observes.

**Python's `await` form is refused explicitly**, and this is the one place the
idiom survey found a SEMANTICS difference rather than a spelling one: an
`async def` handler would make Python's transaction boundary depend on an event
loop kaya does not own, which is a different observable semantics, not a different
spelling. Invariant 1 forbids that. Recorded in docs/deferred.md's idiom entry as
"not taken".

The three carve-out bindings must be held to NOT growing an async form later by
accident — see §6's gate clause, which reads them by name.

## §4 THE SCENES: the future form changes none of them

Four shared scenes exercise a dialog's answer, and they are the proof that the
future form is the same occurrence:

| scene | what it drives | languages on the mac lane |
|---|---|---|
| tools/scenes/confirm.steps | two alerts, three choices each, `expect_alerts 0` at the end | all nine |
| tools/scenes/filedialog.steps | a picker, a chosen file, a cancel, then a second picker proving the id retired | rust, python, go, csharp, ocaml, haskell, swift, java, js |
| tools/scenes/save.steps | a save panel, a save-back with no dialog, a rename | all nine, each alone between drains |
| tools/scenes/clipboard.steps | a privileged clipboard read | all nine, each alone between drains |

**THE RULE: a guest re-spelled with the future form passes these scripts BYTE FOR
BYTE, with no change to any .steps file.** That is what "the same occurrence,
answered instead of called back" means operationally, and it is already
demonstrated once: guests/js/confirm.ts is written with `await kaya.showAlert(…)`
and passes the same tools/scenes/confirm.steps every callback guest passes
(invariant 6 — scene scripts are shared verbatim).

Two consequences worth stating before the work starts:

- `expect_alerts 0` at the end of confirm.steps is the assertion that every id
  retired. A future form that leaked a registration fails there, in every language,
  without a new verb.
- filedialog.steps shows the SECOND picker after the first completed, which is the
  one-live-dialog rule being exercised. If §5 R1.2 is ruled "refuse", that scene
  already covers the legal case and a negative in each checks file covers the
  illegal one.

## §5 RULINGS APPROVED 2026-09-19

Each recommendation below was approved. Measured implementation conflicts must
be brought back for a ruling, not silently resolved by changing the contract.

**R1.1 — Is one name enough, or does the async form get its own?**
JS uses one name: `showAlert` answers a promise when no `onResult` is given. Swift
and C# could do the same with an optional handler argument; Java's chain could make
`.show()` answer a future when no `.onResult` was chained; Rust's ref could
implement `IntoFuture` so `.await` on it works and `.show()` keeps returning an id.
RECOMMENDED: **a separate name in the three static languages, one name in JS and
Rust.** `ShowAlertAsync` / `showFuture()` in C# and Java makes "you passed a handler
AND awaited" UNSPELLABLE rather than a runtime refusal, which invariant 3 prefers
(types over generation over runtime checks); Swift can overload on the return type
(`func showAlert(…) async -> KayaAlertChoice` beside the handler form) and get the
same wall from the compiler; Rust's `IntoFuture` is a compile-time distinction too.
This is spelling, so it does not break invariant 1 — but it should be ruled once,
here, rather than four times.

**R1.2 — Is a second dialog awaited while one is open refused?**
The core already answers this: "One alert may be live per process — ContentDialog
throws on a second per root — and a second show while one lives is a loud guest
error; the id retires when the result fires" (DESIGN.md, Alerts). RECOMMENDED:
**unchanged, and the refusal happens at the SHOW, before the suspension** — so the
awaiting guest sees a throw/panic at the call, not a future that never resolves.
A future that never resolves is the one failure mode that would be invisible to
every lane, which is why the refusal must not be moved into the future's value.

**R1.3 — What does a cancelled dialog resolve to, and must it be one shape in all
four?**
It must be one shape ACROSS LANGUAGES, and it already is — per dialog, the four
differ from each other and always have: an alert answers `AlertChoice.Cancel` (a
case of the enum, not a null); a picker answers THE EMPTY LIST; a save panel
answers nothing (`nil` / `null` / `None`); a clipboard read answers nothing.
RECOMMENDED: **the future resolves to exactly what today's handler receives,
unchanged, per dialog.** No `Optional<AlertChoice>`, no new sentinel, no
"cancellation exception" — a cancel is an answer, not a failure, in every one of
these, and turning it into a thrown `TaskCanceledException` in C# alone would be an
invariant-1 divergence.

**R1.4 — What does a throw between the show and the continuation do?**
RULED, amended 2026-09-19: **explicit transaction scopes are the atomic boundary**
(§1.4). A throw inside a scope rolls that scope back; scopes that returned stand.
Async jobs in the four new tiers run with no transaction open. An exception outside
a scope rolls back nothing and reaches the shared async reporter, including C#'s
separately posted async-void exceptions. JS keeps its existing implicit transaction
and documented residue, not the rollback promise this plan originally attributed
to it. Java completes its future outside Dispatch's transaction, held by a watched
negative. The four new reporters use §1.4's one sentence, without inferring whether
the handler suspended or which scope rolled itself back.

**R1.5 — After the await, how does the guest write?**
Today every write needs a `Tx`, handed to a handler. After the await there is no
handler, so either the binding exposes ambient writes on the app (`app.write(sig,
…)`, opening and committing a transaction per call), or the guest opens one
explicitly (`app.build { tx in … }`). RECOMMENDED: **explicit
`build`/`Build`/`apply`, not ambient writes** — the ambient form is JS's and
Python's by ruling and would be a second semantics in the handle bindings, where
`check-tx-liveness` exists precisely because a handle is what makes the boundary
visible. A continuation that wants one atomic batch says so.

**R1.6 — Does the app-thread executor become part of the Java surface?**
Java's continuation runs on the app thread because the binding completes the future
there, so `thenAccept` suffices and the guest never names an executor. But a guest
that chains `thenAcceptAsync` with ITS OWN executor would move the continuation off
the app thread and its writes would be refused at the chokepoint. RECOMMENDED:
**do not expose an executor; document the refusal.** The existing thread check
turns the mistake into a named error rather than a race, which is the outcome
invariant 3 asks for, and adding an executor to the surface invites the mistake.

**R1.7 — Does the future form reach the notification surface too?**
`showNotification` has the same request/result grammar (a one-shot `onResult`
carrying an outcome), but many may be live at once and the answer can arrive in a
DIFFERENT PROCESS after a relaunch (docs/deferred.md's S9 entry, the second act).
RECOMMENDED: **no — dialogs only, this slice**, with the reason on the record: a
future cannot span a process restart, and half a surface that sometimes can and
sometimes cannot answer is worse than a uniform callback.

## §6 THE ORDER OF WORK

**Depth on C# first.** Its mechanism is the smallest of the four and needs no new
type: `SynchronizationContext` and `Task<T>` are standard library, `await` is the
language's native idiom, the install is one line at the top of `DispatchLoop`
beside the existing `ClaimAppThread()`, and the continuation queue it posts to
already exists. It is also the tier where the shape is least entangled with other
open work — Swift's is entangled with the Swift 6 ruling, Java's has no `await` to
validate the ergonomics with, and Rust's asks for a new concept in the guest loop.
Land C# with the four dialog scenes green on the mac lane, then fan out.

Then, in order: **Swift** (which should land with, or after, the Swift 6 / package
target decision, since `@KayaAppActor` is the same object both slices want);
**Java** (the future chain, no new concurrency); **Rust last** (the app loop grows a
task list, and the guest shape changes most).

**The gate that holds the four level**, in the shape of check-sugar-surface's rich
text clause (tools/check-sugar-surface.py, "THE RICH TEXT SURFACE, in all nine"):
a new clause reading, per binding, out of that binding's own file:

- the awaitable form of each of the five dialogs — `showAlert`, `pickFile`,
  `pickFiles`, `saveFile`, `readClipboard` — in each of the five tiers that have it
  (Swift, C#, Java, Rust, JS): 25 parts, written out rather than derived, because
  five languages spell an awaitable five ways;
- the app-thread executor/context/actor by name in each of the four: the
  `SerialExecutor` conformance, the `SynchronizationContext` subclass, the
  raw app-thread queue Java completes on, the `Wake` impl — a census over the
  binding's own body, not a grep for the name, since the name appears in the prose
  beside the call (the trap check-appearance was bitten by twice);
- **the carve-out refused BY NAME**: Python, Haskell and OCaml must have NO
  awaitable dialog form, so that a later "helpful" addition goes red here instead
  of shipping a fourth semantics;
- a floor and a verdict refusal, since a census that reads nothing agrees with
  everything.

**The negatives, per checks file** (each watched failing, with the substitution
count printed — CLAUDE.md invariant 3):

| tier | file | the negatives |
|---|---|---|
| C# | guests/csharp/AbortCheck.cs | a write through a `Tx` captured across the await is refused; a second dialog while one is live throws at the show; a throw after the await rolls back only the scope it threw inside, scopes that returned stand; the four feasibility cases enter check-abort with watched mutations |
| Java | tools/checks/java-async/dev/kaya/AsyncCheck.java | the same scope and lifetime cases, final-stage observation, foreign-thread writes refused, completion inside an open transaction refused, raw-loop wake, callback cleanup and callback/future compile refusals |
| Swift | tools/checks/swift-async/main.swift | the same scope and lifetime cases, continuation thread identity, app.task's observer, callback rollback cleanup, result retirement, and compile refusals for async build bodies and off-actor entry |
| Rust | crates/kaya/src/app.rs `compile_fail` doctests + unit tests; crates/kaya/src/app/tasks.rs; tools/checks/rust-scoped.py through check-abort | private begin and scoped borrows reject retained Tx; occurrence-loop reentry refuses before posts or events; thirteen scheduler-path tests, fourteen watched production cuts and twenty compiler cases hold task ownership, shutdown cleanup, dialog completion and explicit-scope atomicity |
| JS | bindings/js/kaya_app_checks.ts | promise resolution, second-dialog refusal, callback/promise overlap, abort cleanup and invalid-input registration ordering; three production cuts watched failing |

And the four scenes (§4) re-run unchanged on every lane, which is the whole point:
if any of them needs a byte changed, the design is wrong rather than the scene.
