# Rust async transaction-boundary feasibility, 2026-09-20

The plan's two proposed compiler refusals are different. An await inside
apply's synchronous closure is refused. Holding a transaction returned by
begin across an await in a local future compiles. Tx being non-Send does not
forbid suspension on one thread.

## Measurement

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

Four mutations each printed one substitution. The retained-Tx mutation was
watched compiling, disproving the proposed refusal. Both Send mutations were
watched refusing, including the valid explicit-scope control. The await-inside-
apply mutation was watched refusing with E0728. The runner checks every build
exit and expected diagnostic. These are five compiler cases, not five runtime
cases and not a production guard.

## Decision needed before the Rust implementation

Recommended amendment: preserve the explicit-scope semantics and local futures,
but replace the claimed retained-Tx compile-time refusal with an executor
runtime refusal. Before polling, there must be no transaction open. After a
poll returns, including Pending, there must still be none. A task that suspends
with an open transaction is discarded before another task or occurrence runs;
dropping its owned Tx must roll that scope back, while completed scopes stand.
The runtime must verify cleanup before proceeding, not assume dropping a future
necessarily removed every open transaction. The diagnostic reports only the
observed open scope and does not claim whole-continuation rollback.
This checks actual suspension, not every written await: an already-ready await
that finishes within one poll would not be rejected merely for its syntax.

Await inside apply stays a compiler error. A Send requirement is not a drop-in
replacement: it also rejects the intended access to today's AppCtx. A narrower
async capability could support another design, but would change the guest
surface and needs its own feasibility measurement. This measurement does not
prove that every possible alternative compile-time design is impossible.

The runtime amendment is a proposal, not approved or implemented. If approved,
the real executor must demonstrate the open-Tx refusal, rollback on disposal,
completed-scope survival, cleanup refusal, and a counted cut that admits the
bad suspension. Lifetime/ownership of stored futures and the dialog resolver
path remain separate implementation feasibility work. No Rust API or guest
has changed.
