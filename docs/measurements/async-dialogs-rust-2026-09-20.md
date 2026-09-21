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
