# Rust async transaction-boundary feasibility, 2026-09-20

The original public begin API allowed an owned Tx across an await. A follow-up
found a compile-time boundary through scope-only API design, approved by Akhil
on 2026-09-20. The historical measurement and its replacement are separated below.

## Initial measurement, before begin became private

Production baseline bd6a830f, rustc 1.97.0 (2d8144b78 2026-07-07), arm64 Mac.
The probe builds the real kaya library with cargo --locked, then compiles
metadata against its rlib. Its local_task function accepts and drops a future;
it is a type-checking seam, not an executor. No future is polled, no native
window opens, and no runtime rollback or scheduling behavior is claimed.

```text
nix develop -c python3 docs/probes/async-dialogs-rust-2026-09-20/run.py
```

| Case | Compiler result |
|---|---|
| Explicit apply scopes before and after an await | accepted |
| begin, await, then commit the retained Tx | accepted |
| Require Send for the explicit-scope future | refused: captured AppCtx reference is not Send because AppCtx is not Sync |
| Require Send for the retained-Tx future | refused for the same AppCtx reason |
| Put await inside apply's synchronous closure | refused with E0728 |

The table records the original production baseline, not today's private-begin
API. The same runner now requires E0624 on the retained-Tx case, so it remains
an executable check after the change. Four mutations each printed one substitution. The retained-Tx mutation was
watched compiling, disproving the proposed refusal. Both Send mutations were
watched refusing, including the valid explicit-scope control. The await-inside-
apply mutation was watched refusing with E0728. The runner checks every build
exit and expected diagnostic. These are five compiler cases, not five runtime
cases and not a production guard.

## Follow-up: scoped API, approved 2026-09-20

The first proposal was a runtime poll-boundary check on retained owned
transactions. Akhil asked whether API design could instead refuse the mistake
at compile time. Against the real binding, eleven compiler cases were measured:

| Case | Public begin baseline | Scope-only API |
|---|---|---|
| Owned return value and Rc state across await | accepted | accepted |
| Await directly inside apply | E0728 | E0728 |
| Return the borrowed Tx | lifetime refusal | lifetime refusal |
| Return a future capturing the Tx borrow | lifetime refusal | lifetime refusal |
| Return a boxed future capturing the Tx borrow | lifetime refusal | lifetime refusal |
| Store the Tx borrow outside the callback | E0521 | E0521 |
| Return a closure capturing the Tx borrow | lifetime refusal | lifetime refusal |
| Move the owned Tx through its mutable borrow | E0507 | E0507 |
| Return an independent future | accepted | accepted |
| Return ctx.begin from apply, await, then commit | accepted | E0624 |
| Manually poll a nested future within apply | accepted | accepted |

Every case prints one source substitution and checks the compiler exit and the
expected diagnostic. tools/checks/rust-scoped.py runs through check-abort, and
compile_fail doctests on apply cover the main escapes on the unit-test path.
The guest census found zero .begin calls in guests/rust. Internal unit tests
retain access to private begin. This removes a public API, so an external
manual begin/commit caller must migrate to apply; no in-tree guest changes.

The precise guarantee is that a Tx borrow cannot escape its synchronous scope
into the suspended outer task. It is not a ban on every written await while a
Tx exists: a nested future may be manually polled inside apply. AppCtx::next
therefore refuses while the transaction depth is nonzero, before draining
posted work or consuming an occurrence. Messages::next passes the same wall.
Three headless tests cover both entry paths, the nested manual-poll route,
preservation of queued work, failed-scope rollback, completed-scope survival,
and depth restoration on commit, abandonment and unwinding.

This is the synchronous borrowing pattern described by the
[Rust Reference](https://doc.rust-lang.org/reference/trait-bounds.html#higher-ranked-trait-bounds).
[GPUI's AsyncApp::update](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/app/async_context.rs)
uses a synchronous callback borrowing application state beside local tasks;
this is a structural precedent, not a claim about its rollback semantics.

## Nine-binding assessment

| Binding | Verdict for this scope boundary slice |
|---|---|
| Rust | Do: private begin, borrowed apply, compiler refusals and occurrence-loop reentry wall |
| Swift | Do: retain shipped synchronous build and actor/liveness guards; no spelling change |
| C# | Do: retain shipped synchronous Build and thread/liveness guards; no spelling change |
| Java | Do: retain shipped synchronous build and thread/liveness guards; no spelling change |
| JS | Do: retain ruled implicit continuation transaction and synchronous build rollback |
| Python | Can't add the approved async form on its current loop; retain callback-only carve-out |
| OCaml | Can't add the approved async form without choosing a guest runtime; retain callback-only carve-out |
| Haskell | Can't add the plan's native future spelling on this tier; retain IO/callback carve-out |
| Go | Defer new concurrency surface; existing callbacks and transaction liveness unchanged |

## Validation and remaining work

Three production guard mutations were watched failing, each with one substitution:
replacing the occurrence-loop depth check with a tautology failed the reentry
test; removing the depth decrement failed the cleanup test; making begin public
made the raw-begin compiler case pass unexpectedly, which the probe refused.
Each change was restored. The core passed 631 unit tests and 25 doctests (one
existing doctest ignored). All 61 gates passed, including eight compiler
refusals and three accepted controls through check-abort. The standalone Mac
lane passed all 477 legs with unchanged scene scripts. The full matrix passed:
mac 477, linux 777, windows 283, iOS 139, android 148, and 61/61 gates. Wall time
was 1112 seconds; every lane met its net-time ceiling. The matrix's lane times
were mac 574 seconds, linux 1092, windows 1105, iOS 944 and android 716.
This boundary slice has no new visible scene surface; the Rust async-dialog
feature review will accompany its future-form guests, not this guard-only change.
No dialog future or task launcher is claimed yet. Ownership of
stored futures, scheduler reentry and shutdown cleanup must be measured on the
real executor before adding the dialog resolver and migrating guests.

## Scoped task owner and dialog implementation, 2026-09-20

The guard-only slice above shipped as 7f30e41e. Akhil then approved an external
TaskScope borrowing AppCtx rather than a cloneable context that becomes !Send.
The implementation lives in crates/kaya/src/app/tasks.rs. Twenty compiler
cases now run through tools/checks/rust-scoped.py: fourteen refusals and six
accepted controls. New cases prove that the context cannot escape the task
owner, the owner cannot cross threads, the context can move after its owner
drops, local Rc captures work, Result bodies work, callback and future methods
cannot be mixed, and a task still cannot retain the borrowed Tx.

The real AppCtx occurrence channel drives an Arc-backed ready queue. Wakers
carry only queue identity and the inbox sender, not application state. Each
turn polls a snapshot without holding queue or task-table borrows; repeated
wakes of the same task coalesce. A foreign-thread wake reaches both raw and
typed loops. AppCtx's loop entry guard refuses recursive entry before posted
work or occurrences run. Calling the old loop with an active task owner is
refused by name, rather than silently leaving futures unpolled.

Thirteen headless runtime tests use the actual binding, channels, request
records and resolver. They cover all five request forms, cancellation and
nonempty payloads, one-shot retirement, same-thread resumption with no ambient
transaction, completed scopes surviving a later panic, rollback only in a
throwing scope, Result error reporting, sibling tasks surviving failures,
scope drop and shutdown releasing suspended Rc captures, stale wakes, retained
external futures after scope close, overlap between callback and future forms,
callback abort cleanup, and a closed transport refusing before a future could
wait forever. check-abort demands the source's test census and exactly four
reporter sentences from initial panic, two resumed panics and returned error.

Fourteen Rust production cuts were applied individually and watched red: lost
pending task, leaked task at close, missing alert/file claims, missing abort
cleanup, missing loop-entry guard, missing wake deduplication, missing reply
closure, ambient request allowed, missing file-slot retirement, wrong clipboard
payload, ignored send failure, altered reporter sentence, and missing inbox wake.
Every cut printed one substitution and was
restored. The wake-dedup test initially held a mutex guard inside its assertion;
its deliberate failure poisoned the queue and caused a second panic during
cleanup. The test now reads the count before asserting so the negative names
the failed assertion without poisoning the production queue. The repeated cut
failed with queue length 100 versus 1, then one poll versus two, without aborting.

The R1 JS negative exposed a missing binding-side overlap check. Alert, picker
and save calls now refuse synchronously before constructing a promise, with
callbacks and promises sharing the handler-table slot. Aborted explicit scopes
remove their registrations through the existing journal. Three cuts were
watched red: alert guard (one substitution, four failing checks), both file
guards (two substitutions, ten failing checks), and registration rollback
(one substitution, twelve failing checks). Existing promise results, including
JS pickFile's already-ruled single-result null, are unchanged.
An invalid-filter probe then found another registration leak: encoding inside
the Promise executor rejected the promise after installing a handler for a
request never sent. Both direct assertions and ten later cleanup checks failed.
All three request encodings now precede registration and Promise construction;
the invalid-filter guard passes with synchronous refusal and no live slot.

The surface gate now reads Rust's five constructors, four IntoFuture impls,
task ownership and occurrence wiring, plus JS's five promise signatures. Its
21 new surface cuts and two empty-reader controls fail by name. Python, OCaml
and Haskell retain five callback signatures each; fifteen callback cuts and
fifteen planted awaitable names refuse, with an empty-reader check per language.
This gate checks the named API contract, not arbitrary user-defined runtimes.

| Binding | Verdict for this async surface |
|---|---|
| Rust | Do: scoped local task owner, five awaitables, explicit apply, task error ownership |
| Swift | Do: retain shipped actor, awaitables and app.task; explicit build |
| C# | Do: retain shipped context, awaitables and async-void reporting; explicit Build |
| Java | Do: retain shipped futures, outside-transaction completion and app.observe; explicit build |
| JS | Do: retain promise/implicit-continuation ruling; add early overlap and abort cleanup guards |
| Python | Can't add native await without owning its runtime; callback-only contract guarded |
| OCaml | Can't choose a guest effect runtime for it; callback-only contract guarded |
| Haskell | Can't supply the ruled native future spelling in its IO tier; callback-only contract guarded |
| Go | Defer a new concurrency surface, as ruled; callbacks unchanged |

Four Rust guests now use tasks.spawn and tasks.next: confirm, filedialog, save
and clipboard. Their shared scene scripts are unchanged. File IO stays on
worker threads, returning synchronous writes through Poster, not through the
task launcher. Rust compiled all examples; the full core passed 644 unit tests
and 25 doctests with one existing ignored. JS strict type checks and binding
checks passed. All 61 gates passed. Seven Mac hand legs passed: Rust confirm,
filedialog, save and clipboard, and JS confirm, filedialog and save. The full
Mac lane passed 477 legs. Recorded Rust confirm passed on Linux X11 and Wayland,
Windows and Android; the recorded iOS Rust suite passed all 49 legs, with four
healthy drivers at the verdict. Each of the five platform captures was viewed
before inclusion in docs/reviews/async-dialogs-rust-2026-09-20/README.md.
The first five-lane matrix finished in 1088 seconds: Mac 477, Linux 777,
Windows 283 and iOS 139 passed; Android passed 147 of 148. All 61 gates passed
and every timing ceiling held. The only red was dnd-compose, whose accepted
move never produced Kaya's drag-end callback. All async-dialog legs passed.
The recorder-first investigation is recorded in docs/traps.md under
"Android sent a drag end that Kaya did not record". This slice is not yet
validated by that run. The Android source-removal race was then reproduced with
a held native END, fixed by stable-root ownership and guarded by eight counted
cuts. Three recorder cuts hold the expanded native drag timeline, read back in
the forced-red bundle. The exact comparison is in
docs/measurements/android-drag-end-2026-09-21.md.

After removing the temporary probe, the production drag leg passed. The core
rerun passed 644 tests and 25 doctests with one existing ignored. The first
gate sweep caught a diagnostic substring mismatch introduced while wrapping
a long line in the recorder's self-test; restoring its expected word fixed it.
The repeated complete sweep passed 61/61, and the full Mac lane passed 477 legs.
The final matrix on 2026-09-21 passed in 1072 seconds: Mac 477/556s,
Linux 777/995s, Windows 283/1063s, iOS 139/1032s, Android 148/698s and all
61 gates/334s. Every unchanged net-time ceiling held. R1 is complete.
