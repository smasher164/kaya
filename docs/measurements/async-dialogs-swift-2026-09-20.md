# Swift async-dialog feasibility, 2026-09-20

The shipped executor delivers a dialog continuation on the app thread with
no transaction open. Explicit build scopes have the approved atomicity.
The plan's plain throwing Task does not deliver its error to Kaya's reporter:
the failure remains in the Task's result. Akhil approved the app.task ownership
boundary on 2026-09-20 after the framework comparison below. The implementation
passed the full matrix; the initial measurements below describe the baseline.

## Method

Baseline 3af577be, Apple Swift 6.3.3, Swift 6 language mode with warnings as
errors, on this arm64 Mac. The probe compiles the actual Swift binding sources
as one module to inspect currentTx and signal mirrors. It starts the production
executor and occurrence loop through KayaApp.start, then injects a click into
the core's occurrence ring. The synchronous click handler starts the task.

A probe-only async helper opens an alert through the existing callback API
and bridges its answer with withCheckedContinuation. A headless presentation
pump calls kaya_next_commands, applying the request and claiming the core's
live-alert slot. It answers PRESENT_ALERT through kaya_emit_alert_result.
The real binding retires the callback and resumes the continuation. No native
window or dialog is opened.

The helper transfers the UInt32 choice through the continuation and decodes it
on the actor. KayaAlertChoice lacked Sendable conformance at baseline; passing it
directly was refused by strict concurrency. A checked conformance in a different
source file was also refused. The probe uses the primitive payload without an
unchecked waiver or production edit. Implementation must assess each async
result type's checked Sendable conformance, not blindly copy this transport.

Two initial probe setup errors were refused by the core: answering an alert
without first applying its request, and declaring the click button without
mounting it. The reproducer includes the real apply path and a mounted button.
Those refusals are not findings about async scheduling.

Reproduce from the repository root:

```text
nix develop -c python3 docs/probes/async-dialogs-swift-2026-09-20/run.py
```

The runner verifies the core dylib's build id before compiling and running.

## Observations

Every case resumes on the construction thread with currentTx absent. The
click and result callbacks themselves still have their normal transactions.
A defer marker proves the throwing task body unwound before the assertions.
The reporter, when present, also runs on the app thread without a transaction.

| Task ownership and failure | Completed scope | Second scope | Async reports |
|---|---|---|---|
| Plain Task; throw after first build returns | first = 1 | second = 0, untouched | 0 |
| Plain Task; a second task reads its result | first = 1 | second = 0, untouched | 1 |
| Probe wrapper catches the task body's error | first = 1 | second = 0, untouched | 1 |
| Probe wrapper; throw inside a second build | first = 1 | second = 0, rolled back from 2 | 1 |

The bare case prints no exception and no Kaya handler-failure sentence.
The explicit result observer receives afterScope, proving the error is
available through the task handle rather than lost. The wrapper catches
afterScope or insideScope, prints the exception separately and then exactly
the approved sentence:

```text
kaya: async handler failed; no transaction was rolled back by this reporter; completed transactions remain committed
```

The production executor accepts UnownedJob values and runs them through
runSynchronously, which has no throwing result for the executor to catch.
Wrapping a job in a transaction does not reveal the Task's error. The task
owner must observe that result or catch the body.

Four observations passed. Three scratch mutations printed one substitution
each and were watched failing by name with exit -5:

- Replace the observed wrapper with a plain Task: report count mismatch.
- Demand rollback of a build that returned: completed scope was rolled back.
- Demand the second build's thrown write survive: throwing scope was committed.

The four compiles passed with warnings treated as errors. The standalone probe
holds the baseline measurement. The implementation now puts the missing-observer
mutation in check-abort and holds the approved task entry and five dialogs in
the sugar census.

## Ruling adopted 2026-09-20

Add a binding-owned Swift task launcher, app.task, taking
an actor-isolated async throwing closure. It schedules through the existing
executor, opens no transaction, catches an escaping error and uses the shared
reporter. The approved guest spelling is:

```swift
tx.button("delete", onClick: { _ in
    app.task {
        let choice = await app.showAlert(
            title: "delete item?", actions: ["Delete"], cancel: "Keep")
        app.build { tx in
            tx.write(status, choice == .cancel ? "kept" : "deleted")
        }
        try finishDelete()
    }
})
```

Implementation validation passed. Existing synchronous handlers and callback
forms remain available. A raw Swift Task, including one nested inside app.task,
remains guest-owned: the guest must await its throwing result or catch its
error. Kaya cannot report errors from arbitrary tasks it does not own.

The alternative is to keep raw Task and require do/catch reporting in every
guest. That makes reporting a guest convention instead of a binding guarantee.
Async handler registration could own tasks too, but would be a broader surface
change than one launcher. The other six rulings and the explicit-transaction
amendment need no change.

No binding, executor, interpreter or guest implementation was edited during
the measurement. Implementation validation is recorded in the R1 ledger entry.

The framework comparison corrected the initial framing: Swift already stores
the error, and awaiting dialogs does not require app.task. SwiftUI's View.task
takes a nonthrowing async action, requiring the guest to handle direct errors.
The Composable Architecture's Effect.run accepts a throwing action and wraps it
in a catch-and-report boundary. C# async-void exceptions reach the captured
context, but ordinary C# Tasks and Java continuation stages store failures for
their caller to observe. Scheduling and error ownership are separate.
Sources: [SwiftUI](https://developer.apple.com/documentation/swiftui/view/task(name:priority:file:line:_:)),
[TCA](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Sources/ComposableArchitecture/Effect.swift),
[C#](https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/concepts/async/async-return-types),
[Java](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/CompletionStage.html).

## Nine-binding assessment

| Language | Verdict |
|---|---|
| Swift | Do: five async forms and approved app.task error-reporting boundary. |
| C# | Do, shipped: its context receives async-void exceptions; no change from this finding. |
| Java | Do later: raw completion outside transactions remains approved; measure future-chain error ownership first. |
| Rust | Do later: the planned spawn entry owns the future; measure polling and failure reporting first. |
| JS | Do: preserve its promises, reporter and stated continuation-write residue. |
| Python | Can't within the approved runtime constraint; keep callbacks. |
| Haskell | Can't within the approved runtime constraint; keep callbacks. |
| OCaml | Can't within the approved runtime constraint; keep callbacks. |
| Go | Defer a new concurrency surface; existing callbacks stay unchanged. |

## Implementation and guards

The five async requests use checked continuations, with checked Sendable
conformance on the alert choice and clipboard representation. Each request
opens its own synchronous build, then suspends. The existing executor resumes
it without a transaction; neither the executor nor its unsafe-waiver count
changed. app.task catches escaping errors and prints the approved sentence.

The callback path registers only after encoding. Alert and file live slots
retire before invoking their callback, and rollback removes registrations and
releases the slot. Pick and save share one slot; alerts use a separate one.
Duplicate results find no registration and cannot resume a continuation twice.

The mandatory check-abort gate runs the real binding with headless result
delivery. Ten mutations, each applied once and watched failing, remove the
observer, boundary, overlap guards, each result retirement, rollback cleanup,
scope rollback or template refusal. Three one-substitution compile negatives
refuse await inside build, combining callback and async forms, and task launch
outside the app actor. The surface gate has twelve watched one-substitution
cuts and an empty-reader refusal. Native scene runs cover real occurrence
decoding and core presentation, beyond the headless delivery seam.

The four Swift dialog guests use app.task and explicit builds with unchanged
scene scripts. Strict compilation passed all eight macOS/iOS passes. The core
passed 628 tests and 18 doctests (one ignored). All 61 gates, the four native
Mac dialog scenes, the full Mac lane's 477 legs and the recorded Swift iOS
suite's 46 legs passed. The iOS verdict had all four test drivers alive and no
between-leg restart. Recorder defects found along the way and their watched
negatives are recorded in docs/traps.md. The final five-lane matrix passed in
1084 seconds: Mac 477, Linux 775, Windows 282, iOS 139 and Android 148 legs,
plus all 61 gates. Every net-time ceiling held. The inspected native captures
are in docs/reviews/async-dialogs-swift-2026-09-20/README.md.
