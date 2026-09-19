# Async dialogs beyond JS — the design, for ruling

The ruling this document serves is R1 in docs/deferred.md's idiom entry:

> ASYNC DIALOGS beyond JS for Swift, C#, Java and Rust under one rule — no
> handler given, a dialog answers a future; the continuation runs on the app
> thread as its own transaction — with Python, Haskell and OCaml stated as the
> carve-out (no native async runtime on the app thread), the way
> docs/js-plan.md §4 names the languages that cannot spell the implicit
> transaction. Python's `await` form is the survey's one SEMANTICS finding and
> is not taken.

JS has the feature already (docs/js-plan.md §4, rule 2). This document says what
the same rule means in the other four, states each mechanism from zero before it
uses it, and ends with the rulings owed and the order of work. Nothing here is
built; §5 is the list of questions for the maintainer.

Every claim about a platform below was MEASURED with a small probe, not recalled;
the probes are reproduced in §2 so a later session can re-run them.

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
3. **The continuation is its own transaction, atomic.** Also already true of the
   post queue: "Run everything posted, each as its own transaction, in order"
   (bindings/swift/KayaApp.swift, `drainPosted`). Writes after the await land in
   one batch, the way writes inside a handler do.
4. **THE AWAIT IS A TRANSACTION BOUNDARY.** The handler's transaction commits at
   the suspension point. It has to: the dialog's answer arrives through the app
   loop, so the loop must be free to turn, and a transaction that stayed open
   across the suspension would hold the batch for however long the user stares at
   the dialog. This is the same sentence docs/js-plan.md §4 rule 1 states for JS,
   arrived at from the other direction.
5. **A handler's transaction semantics do not change.** A handler that throws
   still rolls its transaction back. Only the boundary moved.

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

docs/js-plan.md §4 rule 1 states JS's residue and this is its twin: **writes
committed before the suspension stand.** The handler's transaction committed at
the await; nothing can take it back. If the continuation throws, the
continuation's OWN transaction rolls back and the binding prints the same
"handler threw (transaction rolled back)" sentence it prints today, and the dialog's
id is already retired either way.

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
    app.write(status, .str(choice == .cancel ? "kept" : "deleted"))
}
…
tx.button("delete", onClick: { _ in Task { await askDelete() } })
```

`app.showAlert(…) async` opens its own transaction to send the request, suspends,
and resolves with the choice. The write after the await is its own transaction by
rule 3. (Whether the writes after the await are spelled `app.write` or through an
explicit `app.build { tx in … }` is §5 R1.5.)

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

In the shipped binding the queue IS the existing posted-work queue: `Post` becomes
`App.Post(tx => …)`, so the continuation arrives as its own transaction for free —
the ambient transaction rule 3 asks for is the post queue's own behaviour.

**The spelling** (guests/csharp/ConfirmScene.cs today passes `onResult:`):

```csharp
tx.Button("delete", onClick: async _ =>
{
    var choice = await app.ShowAlertAsync(
        title: "delete item?", message: "this cannot be undone",
        action0: "Delete", action1: "Archive", cancel: "Keep");
    app.Write(status, choice switch {
        AlertChoice.Action0 => "deleted",
        AlertChoice.Action1 => "archived",
        _ => "kept",
    });
});
```

**Where `await` may appear:** in any `async` method reached from a handler, and
NOT inside a `Build` body. C# has one sharp edge worth naming at ruling time: an
`async void` lambda (which is what `onClick: async _ => …` is) swallows its
exception into the captured context rather than to the caller. The binding's own
`Dispatch` already catches and prints; the context's `Post` must do the same, so
a throw after the await is reported with the same sentence and not lost.

**The guard.** `check-tx-liveness` again — the C# chokepoint is the `Records`
property, and the gate already pins the raw field to exactly two uses. A write
through a `Tx` captured across the await is refused there.

### 2.3 Java — the future's own chain, because there is no `await`

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

In the shipped binding the executor is `app::post`-shaped, so again the continuation
arrives as its own transaction.

**The spelling** (guests/java/dev/kaya/guests/Confirm.java today chains
`.onResult(…)` before `.show()`):

```java
tx.button("delete", inner -> inner.showAlert()
        .title("delete item?")
        .message("this cannot be undone")
        .action("Delete").action("Archive").cancel("Keep")
        .showFuture()                       // no .onResult: answers a future
        .thenAccept(choice -> app.write(status, switch (choice) {
            case ACTION0 -> "deleted";
            case ACTION1 -> "archived";
            case CANCEL  -> "kept";
        })));
```

Note `thenAccept`, not `thenAcceptAsync(…, executor)`: the binding completes the
future ON the app thread (the answer occurrence is dispatched there), so the plain
chain already runs there, and the guest never names an executor. That is the
idiomatic reading and it keeps the guest free of kaya's threading. Whether the
binding should ALSO expose the executor is §5 R1.6.

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

**From zero.** Rust's `async` has no runtime in the standard library. An `async
fn` compiles to a value implementing `Future`, which does nothing until something
POLLS it. Polling hands the future a `Waker`; if the future is not ready it stores
the waker and returns `Poll::Pending`, and whoever completes the work later calls
`waker.wake()` to say "poll me again". An executor is just a loop that polls futures
and parks between wakes. Tokio and async-std are large executors; kaya needs a
five-line one, because **kaya's app loop is already that loop**: it polls the
occurrence ring and parks on `kaya_wake()`.

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
Msg::AskDelete => ctx.spawn(async move {
    let choice = ctx.show_alert()
        .title("delete item?").message("this cannot be undone")
        .action("Delete").action("Archive").cancel("Keep")
        .await;                                   // suspends; the loop turns
    ctx.apply(|tx| tx.write(status, match choice { … }));
}),
```

`AppCtx::spawn` boxes the future and puts it in a task list the occurrence loop
polls between occurrences; the alert ref's `IntoFuture` sends the request in its own
transaction and registers the binding's internal one-shot handler as the resolver.

**Where `.await` may appear, exactly:**
- inside a future handed to `ctx.spawn`, and nowhere else;
- NEVER inside `ctx.apply(|tx| …)` — the closure is the transaction, and the
  compiler refuses this for free: `apply` takes a SYNCHRONOUS closure, and
  `.await` inside one is a hard compile error ("`await` is only allowed inside
  `async` functions and blocks"), so the boundary is a type, not a convention;
- NEVER around `msgs.next(&ctx)`, which is the loop itself.

**The guard.** Rust's is the only tier where the wrong spelling is a COMPILE error
rather than a runtime refusal, and the binding should keep it that way: the
`compile_fail` doctests in crates/kaya/src/app.rs are the home for "a `Tx` held
across an `.await`" and "an `.await` inside `apply`".

## §3 THE CARVE-OUT: Python, Haskell and OCaml keep the callback

Stated in the shape DESIGN.md uses for JS's implicit transaction, and for the same
reason the row-handle rule states its own carve-out:

> **Python, Haskell and OCaml keep the callback form.** A dialog in those three is
> answered by the handler that rode the request, exactly as it is today, and no
> awaitable spelling is added. The reason is not taste: the rule requires the
> continuation to run ON KAYA'S APP THREAD as its own transaction, and none of the
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

## §5 RULINGS OWED

Each is a plain question with a recommended answer and the reason.

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
RECOMMENDED: **the JS residue, uniformly** (§1.4): writes committed before the
suspension stand; a throw in the continuation rolls back the continuation's own
transaction and is printed with the binding's existing "handler threw (transaction
rolled back)" sentence. The one thing to add is that C#'s `async void` path must
route its exception through the same reporter, because .NET's default is to raise
it on the captured context where it can be lost.

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

## §6 THE ORDER OF WORK, IF RULED

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
  `Executor` the binding completes on, the `Wake` impl — a census over the
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
| C# | guests/csharp/AbortCheck.cs | a write through a `Tx` captured across the await is refused; a second dialog while one is live throws at the show; a throw after the await is printed and rolls back only the continuation |
| Java | tools/checks/java-abort/AbortCheck.java | the same three, plus a continuation chained with a foreign executor being refused by the thread check |
| Swift | tools/checks/swift-abort/main.swift | the same three, plus the continuation's thread id equalling the app thread's |
| Rust | crates/kaya/src/app.rs `compile_fail` doctests + unit tests | a `Tx` held across `.await` fails to COMPILE; an `.await` inside `apply` fails to compile; the loop resolves a future and runs its continuation on the app thread |
| JS | bindings/js/kaya_app_checks.ts | already has the promise-resolution negative; add the second-dialog refusal so all five say one thing |

And the four scenes (§4) re-run unchanged on every lane, which is the whole point:
if any of them needs a byte changed, the design is wrong rather than the scene.
