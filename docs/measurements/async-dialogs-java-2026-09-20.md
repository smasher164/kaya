# Java async-dialog feasibility, 2026-09-20

The dialog future does not own failures in the guest's continuation. Completing
it successfully can run a thenAccept body that throws; the original future
still succeeds, and the new stage stores the failure without throwing it back
through Kaya's dispatch. Observing the original future does not report that
failure. Observing the final stage does.

This is the ownership distinction already approved for Swift, not a new
transaction-atomicity conflict. Java needs a spelling for handing its final
stage to Kaya. Akhil approved app.observe(finalStage) on 2026-09-20 after the
measurement. No production binding or guest was changed for the measurement;
implementation and its separate validation follow that approval.

## Method and limits

Baseline 6b17c397, Zulu OpenJDK 21.0.11+10-LTS, release 21 compilation on the
arm64 Mac. The probe compiles the real Java binding and desktop KayaRing,
verifies the core dylib's build id, loads it and attaches its JNI transport.
It claims a worker thread as the app thread. Builds encode and submit through
the production native transport; collection reads inspect the real mirror.

The request uses the production alert builder and callback registry. Reflection
removes that registration and invokes the production dispatch with its callback,
matching the alert-result arm's remove-then-dispatch sequence. A probe-only
ArrayDeque delays future completion until dispatch returns. The callback's
actual Tx.closed field tells whether the continuation ran inside that scope.
No binding source is rewritten. This is not a core occurrence-loop, dialog
presentation, phone-runtime or production raw-job-queue test; those remain
implementation validation. No window opens, and queued core transactions are
not applied by a native presentation pump.

Reproduce:

```text
nix develop -c python3 docs/probes/async-dialogs-java-2026-09-20/run.py
```

The runner checks each compile exit before running its result. Initial probe
compile errors were setup mistakes: Java's Consumer/Function overload pair
requires an explicit-return block for these value-returning calls, and Entry
exposes key as a field rather than a record accessor. No stale probe ran.

## Observations

Every early-attached continuation ran on the claimed app thread. Queuing
completion until after dispatch returned made the result transaction closed.
The original dialog future completed normally in every case.

| Case | Result Tx still open | Completed first entry | Second entry after throw | Reports | Final stage |
|---|---|---:|---:|---:|---|
| Complete inside result dispatch | yes | not written | not written | 0 | normal |
| Queue completion, discard failed continuation | no | 1 | not written | 0 | failed |
| Observe only the original dialog future | no | 1 | not written | 0 | failed |
| Observe the final stage; throw after first build | no | 1 | not written | 1 | failed |
| Observe the final stage; throw before any build | no | not written | not written | 1 | failed |
| Observe the final stage; throw in second build | no | 1 | rolled back | 1 | failed |
| Catch the second build's throw inside continuation | no | 1 | rolled back | 0 | normal |
| Attach another continuation from a foreign thread after completion | no | not written | not written | 0 | foreign stage failed |

The last case ran on the attaching foreign thread. A write through app.build
was refused by the existing app-thread check, and that refusal was itself
stored in the new stage. Reading that stage exposed the named refusal. The
earlier on-owner stage remained successful. Thread affinity is not an error
observer, and completing on the app thread cannot move a later foreign-thread
attachment back there.

The three owned-failure cases printed the exception separately and exactly the
approved reporter sentence. No case reached the synchronous handler reporter.
The probe's observer is not a production API; its callback ran on the app
thread in these cases because that thread completed the stage.

Six scratch mutations applied one substitution each and were watched exiting
1 with the intended assertion: observe the parent instead of the final stage;
complete inline instead of queuing; demand another completed first entry;
demand the rolled-back second entry; omit the app-thread claim; rethrow the
failure the caught case handles. Eight observations and all six negatives
passed. The runner also counts reporter sentences and refuses a synchronous
rollback report for an async stage failure.

This agrees with the JDK's documented separation of stages and its non-async
completion policy. See [CompletionStage](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/CompletionStage.html)
and [CompletableFuture](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/CompletableFuture.html).

## Approved ruling: app.observe(finalStage)

Keep the approved showFuture spelling and add void
app.observe(CompletionStage<?> finalStage). The guest hands Kaya the end of its
chain; Kaya observes a remaining failure and queues the shared reporter on the
app thread without a transaction. It does not block, change the stage's result,
reschedule guest continuations or monitor branches appended afterwards.
Pass a stage once. Guest recovery belongs before observe, so a recovered chain
reports no failure. Existing fatal-error policy still applies.

```java
tx.button("delete", inner -> app.observe(
    inner.showAlert().title("delete item?").action("Delete").cancel("Keep")
        .showFuture()
        .thenAccept(choice -> app.build(t -> {
            t.write(status, choice == KayaApp.AlertChoice.CANCEL ? "kept" : "deleted");
        }))));
```

This approved spelling does not compile against the measurement's baseline.
Unlike Swift, Java has already created the continuation stage at the point it
hands it over, so an observer need not launch an async body. The alternative
is guest-written whenComplete reporting at every use. Automatically observing
the original dialog future is not an alternative: the measured parent case
misses the failure. Automatically reporting every intermediate stage would
also report failures the guest recovers later.

Implementation guards should move these cases onto the real raw queue and
reporter in mandatory check-abort, add callback cleanup and overlap tests,
and pin the new observer in check-sugar-surface. A watched mutation must
observe the wrong parent, alongside the completion-inside-transaction cut.
Native validation results follow below; the shared scenes are unchanged.

## Implementation and guards

The approved implementation adds showFuture to alert, pick-one, pick-many and
save requests, sendFuture to clipboard requests, and app.observe for the final
CompletionStage. The ordinary configuration chain keeps its existing callback
methods. onResult answers the callback-only base type, so the same expression
cannot select both owners; a retained future-capable alias is refused at runtime.
No wire records, core behavior or native dialog presentation changed.

Future completion and error reporting use a locked raw-job queue, drained by
the existing occurrence loop with no transaction or template body open. A wake
releases its native wait. Result dispatch retires the one-shot before invoking
its callback, and future completion is queued until that result transaction has
closed. A request transaction that aborts clears registrations and live slots
and queues exceptional completion. Pickers and save share one live slot; alerts
have their own; clipboard reads remain independent.

The four Java dialog guests use the future form and explicit builds; background
file workers retain app.post. tools/checks/java-async/dev/kaya/AsyncCheck.java
drives the real binding and JNI transport headlessly. Its injected result helper
calls are not native dialog or core occurrence decoding tests. Separately, a
real parked occurrence loop is woken by a foreign-thread failure, and the
reporter is checked for app-thread identity and absence of an open transaction.
The baseline includes all five results and cancellations, duplicate retirement,
seven scope/ownership cases, overlap, request and callback abort cleanup,
retained aliases and transactions, foreign-thread refusals, templates, and fatal
Errors. An already-failed stage observed inside a build is reported only later.

check-abort runs this baseline and fourteen counted runtime mutations: wrong
parent observed, inline completion, missing raw boundary, missing scope rollback,
false rollback report, alert/file overlap, result retirement, rollback cleanup,
abort completion, mixed owner, fatal Error swallowed, missing loop drain and
missing wake. Each was compiled and watched exiting 1 with its named assertion.
The mixed-owner cut changes four sites; every other cut changes one. Four
callback/future chains each compile without a callback, then one counted
insertion of onResult makes the compiler refuse the future method by name.
check-sugar-surface holds fifteen signatures and occurrence/queue connections,
each cut separately, plus its empty-reader floor. These are existing mandatory
gates, not a new optional runner.

Validation: 628 core tests and 18 doctests pass (one ignored), the Java
binding and all guests compile, and check-abort passes including those negatives.
An initial 61-gate sweep passed. The four Mac dialog scenes and native Windows
dialog checks passed, as did Linux confirm and save under X11 and Wayland and
Android confirm. Reviewed native alert captures cover all four Java lanes in
docs/reviews/async-dialogs-java-2026-09-20/README.md. Linux and Windows now run
the existing Java save scene in their regular rosters. check-steps requires all
four dialog scenes on each Java lane; sixteen single-entry deletions were each
watched producing exactly their missing-leg finding. The final standalone gate
sweep passed 61/61, and the full Mac lane passed 477 legs. The five-lane matrix
passed in 1105 seconds: Mac 477, Linux 777, Windows 283, iOS 139 and Android 148
legs, plus all 61 gates, with every net-time ceiling held. No failed leg occurred
in that matrix. Review recording defects and their nine counted negatives are
recorded in docs/traps.md and the review page.

## Nine-binding assessment

| Binding | Verdict |
|---|---|
| Java | Do, shipped: five future forms, raw completion queue and final-stage observer. |
| Swift | Do, shipped: app.task owns its body; raw Tasks remain guest-owned. |
| C# | Do, shipped: captured context reports async-void failures; ordinary Tasks remain caller-owned. |
| Rust | Do later: planned spawn owns its future; polling and failure reporting need measurement. |
| JS | Do, preserve: existing promise reporting and continuation-write residue. |
| Python | Can't under the approved runtime constraint; callbacks remain. |
| Haskell | Can't under the approved runtime constraint; callbacks remain. |
| OCaml | Can't under the approved runtime constraint; callbacks remain. |
| Go | Defer new concurrency surface; callbacks remain. |
