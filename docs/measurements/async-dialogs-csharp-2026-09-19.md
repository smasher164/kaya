# C# async-dialog feasibility, 2026-09-19

The app-thread part works. The original rollback claim in async-dialogs-plan.md
sections 1.4 and 2.2 did not: posting a continuation through `App.Post`
does not let `Dispatch` catch an `async void` exception before committing.
This is a measurement of the proposed integration, not a shipped defect
in a C# async-dialog API. No such API existed at the measured baseline.
The amended implementation and its validation status are recorded in
docs/deferred.md's R1 entry.

## Method

On this Mac, .NET SDK 10.0.302, against the actual C# binding and the
existing core dylib at baseline 71f1363d. No window or dialog is opened.
The probe supplies a SynchronizationContext, then uses the binding's real
Post, DrainPosted, Build, Tx.Write, signal journal and failure reporter.
A worker resolves a TaskCompletionSource; the owner thread drains the
continuation and then the separately posted exception. Every case checks
thread identity, stale-Tx refusal, the committed pre-await value, delayed
exception reporting, final mirror value and exactly two context posts.

Reproduce from the repo root, inside the dev shell:

```text
tools/build-id.py --verify target/debug/libkaya.dylib
python3 docs/probes/async-dialogs-2026-09-19/run.py
```

The runner builds a scratch copy with the real binding sources. Both
compiles reported zero warnings and zero errors. Four observations passed:

| Queue and guest writes | After continuation | After exception delivery |
|---|---|---|
| App.Post; write through its ambient Tx; throw | `after` | `after` |
| App.Post; explicit Build returns; throw outside it | `after` | `after` |
| App.Post; throw inside explicit Build | `before` | `before` |
| Raw owner-thread queue; explicit Build returns; throw outside it | `after` | `after` |

All four resumed on the owner thread and refused the retained transaction.
In all four, the error was still unreported immediately after the
continuation. It appeared on the second drain. The first two printed
`handler threw (transaction rolled back)` even though the value was
`after`. The reporter had rolled back only the empty transaction that
delivered the exception, not the transaction that made the write.

The runner then changed the expected final value to `before`, printed
**1 substitution**, rebuilt, and demanded that the ambient case fail.
It exited 1 naming `observation mismatch, want final=before`. Thus the
probe does not silently accept the plan's rollback claim.

.NET's [AsyncVoidMethodBuilder source](https://source.dot.net/System.Private.CoreLib/src/runtime/src/libraries/System.Private.CoreLib/src/System/Runtime/CompilerServices/AsyncVoidMethodBuilder.cs.html)
matches the observation: SetException posts the exception to the captured
context. It does not throw back through the call that ran the continuation.

## Decision adopted 2026-09-19

R1.5 was approved with explicit Build/build/apply after suspension. Treat
those scopes as the actual transaction boundaries: a throw inside one
rolls it back; a scope that returned has committed and a later throw does
not undo it. Resume async jobs without opening an implicit transaction.
Report an async-handler failure without claiming a rollback the reporter
cannot establish. Synchronous callback rollback remains unchanged.

This amendment was adopted by Akhil, with Java completion outside transactions,
a rewrite of the plan and one honest async-failure sentence across the four new
tiers. Work resumed 2026-09-20. It also
corrects R1.4's citation of JS: docs/js-plan.md section 4 explicitly says
continuation writes before a throw stand, and the JS `_dispatch` rejection
reporter says that too. The async-dialog plan claimed the opposite.

An alternative that makes an entire continuation atomic would need a
different handler/transaction contract, including when explicit Build
commits, and cannot be obtained by the proposed context wrapper alone.

## Nine-binding assessment

| Language | Verdict for this slice |
|---|---|
| C# | Do: Task forms and app-thread context under the approved explicit-scope amendment. |
| Swift | Do: async forms on the shipped KayaAppActor executor; explicit build scopes. |
| Java | Do: future forms; explicit build scopes and existing foreign-thread refusal. |
| Rust | Do: scoped app-loop polling and explicit apply; subsequently measured and validated in docs/measurements/async-dialogs-rust-2026-09-20.md. |
| JS | Do: preserve existing promises and documented continuation residue; add overlap coverage. |
| Python | Can't under the approved runtime constraint: callbacks remain, no asyncio integration. |
| Haskell | Can't under the approved runtime constraint: callbacks remain, no new async runtime. |
| OCaml | Can't under the approved runtime constraint: callbacks remain, no Lwt/Eio integration. |
| Go | Defer any new channel/future surface: not included in R1's four additions; callbacks remain. |

The Go row fixes an omission in the plan's assessment, not a claim that
Go cannot express concurrency. No additional language surface is approved
by this measurement.

## Guard and validation scope

The reproducible probe guards the measurement with four checked outcomes
and one counted false-expectation negative. It is not a new lane gate:
there was no production implementation at measurement time. The real context
and its rollback/reporting tests must enter
check-abort, including a watched mutation, before the API can ship.
No GUI legs or full matrix were run for this feasibility finding.

## Implemented depth slice, 2026-09-20

The real binding now owns the raw SynchronizationContext queue and five Task
forms. Confirm, FileDialog, Save and Clipboard guests await the result and
write through explicit Build. Runtime thread, transaction-liveness and
synchronous-Build checks enforce the boundary; check-abort watches eleven
counted runtime mutations fail, and check-sugar-surface watches nine signature
and queue-wiring cuts fail plus an empty-reader refusal. Request encoding
precedes callback registration; rollback removes request registrations and
faults their Tasks. Callback forms remain available.

Final validation: 628 core unit tests, 18 doctests (one ignored), all 61
gates in 159 seconds, and the standalone Mac lane's 477 legs in 387 seconds.
The five-lane matrix passed in 1258 seconds: Mac 477, Linux 775, Windows 282,
iOS 139, Android 148 and all 61 gates, with every runtime ceiling held.
The final run followed the maintainer's host reboot. Earlier failures and
their recorder/readiness corrections are recorded in the iOS typing-readiness
and Android ANR measurements dated 2026-09-20. Native desktop captures are in
docs/reviews/async-dialogs-csharp-2026-09-20/README.md.
