# Swift 6 guests and the app-thread executor

Ruling: 2026-09-18, take the executor route for the guests. Async-dialog API
rulings and the SwiftUI interpreter migration are separate. The executor and
guest migration passed the complete validation ladder, recorded below.

## Feasibility first

Apple Swift 6.3.3, the toolchain reached through tools/lib/swift-toolchain.sh.
The old plan's claim that a top-level guest variable could be annotated with
the custom global actor was false: the compiler rejects it with
`top-level code variables cannot have a global actor`. A guest needs an
actor-isolated entry body, not just an executor added behind its old entry.

The measured spelling is `KayaApp.run { app in ... }`. Guest state and
construction live inside the synchronous KayaAppActor body; record types and
their generated companions remain at file scope. No guest becomes a `@main`
type and no generated companion changes. The old instance `app.run()` remains
available to Swift 5 clients but is unavailable in Swift 6, with a diagnostic
naming the new entry. Capturing mutable main-actor state in that body is a
compiler error, rather than the first handler's silent SIGTRAP.

A scratch copy of the real milestone2 guest, compiled in Swift 6, passed its
unchanged shared scene through tools/run-leg.py with the scratch compiler and
executable substituted at the lane's build and launch hooks. Construction,
both step clicks and a task resumed after a 50 ms suspension all printed the
same non-main pthread identity. The compile census then passed 52/52 scratch
guests. No toolchain or guest file was changed before that measurement.

The proposal's consuming ExecutorJob and default asUnownedSerialExecutor
implementation require macOS 14 / iOS 17. Implementing enqueue(UnownedJob)
and asUnownedSerialExecutor explicitly compiled with warnings as errors at
macOS 13 and iOS 16, preserving the package and guest deployment floors.
This is a deployment-target compile proof, not a run on those old OS versions.

## Mechanism and guards

One process-wide serial executor owns a lock-protected job queue. Its worker
enters the initial actor task, which constructs the app and then runs kaya's
existing blocking occurrence loop. Each turn drains queued Swift jobs and
posted transactions. Enqueue wakes the core's occurrence wait as well as the
executor's initial condition wait. No polling and no UI-thread execution.

`@unchecked Sendable` is limited to KayaAppQueue: its items and started
flag are private and protected by NSCondition. The executor and the posting
door use separate instances of this one queue implementation. The executor's
own Sendable conformance is compiler-checked. No app or widget handle becomes
Sendable. The existing four nonisolated(unsafe) waivers are unchanged; the
old app-object handoff is now the Swift 5 compatibility entry only.

The post callback is explicitly KayaAppActor-isolated and Sendable so a
background caller creates a callback for the destination actor. The callback
still receives a fresh transaction, commits synchronously or rolls back on
throw, and cannot suspend. Executor jobs themselves do not create an ambient
transaction. A resumed task uses an explicit build, and a retained transaction
is still refused at the existing liveness check.

`app.post { ... }` keeps its call spelling but is a Sendable callable property,
capturing only the app's immutable queue reference. A worker takes
`let post = app.post` before starting, then uses `post { ... }`; it need not
capture the app object. The receive closure is constructed on the actor before
that handoff, so guest state and signal handles do not pass through a
nonisolated worker. KayaPickedFile has a checked Sendable conformance: it is an
immutable capability intentionally redeemed by background file-I/O workers,
not a widget or live transaction handle.

Guards: check-pins holds the single Swift 6 compiler wrapper and
its mac, iOS and typecheck callers; check-abort runs the real dispatch loop
headlessly, including construction, click, post, rollback and suspension;
compile negatives refuse the legacy entry and mutable main-thread state.
Doctored copies cut the loop's job drain, its wake and its executor identity.
The rollback read now occurs before the click can overwrite it; a fourth
runtime copy corrupts the restored value and must fail that immediate read.
All six compile/runtime perturbations printed one substitution and failed as
required. Three additional runtime modes refused a thrown setup, a second
executor start and a closed transaction. Check-pins watched 20 mode/waiver
perturbations and four queue-lock cuts fail, with substitution counts printed.
The strengthened rollback probe passed in the standalone check-abort rerun
and the matrix's complete sweep.

## Binding assessment

| Binding | Verdict |
| --- | --- |
| Swift | Do: actor-isolated entry and post callback, real app-thread executor, Swift 6 guest compilation. No async-dialog API. |
| Rust | Do, already held: app-thread transactions and explicit background handoff define the same behavior; no code change. |
| Python | Do, already held: same thread and transaction rule; no code change to its ambient spelling. |
| Go | Do, already held: same thread, post and transaction rule; no code change. |
| C# | Do, already held: same thread, post and transaction rule; no code change. Async dialogs await a ruling. |
| Java | Do, already held: same thread, post and transaction rule; no code change. Future dialogs await a ruling. |
| OCaml | Do, already held: same thread and transaction rule; no code change. Callback carve-out stays. |
| Haskell | Do, already held: same thread and transaction rule; no code change. Callback carve-out stays. |
| JS | Do, already held: worker-thread ownership and existing promise semantics; no code change. |

## Validation

Initial repository typecheck: 52 macOS guests, 43 iOS guests, both package
builds and both interpreter passes passed. The later full build revealed three
handoff refusals and two Swift compiler crashes in its SIL pass, which
`-typecheck` never ran. The captures were repaired and the helpers' forward
capture cycles removed. Both guest gate passes now compile object files through
SIL, and check-pins watches both cuts back to -typecheck fail.

The warning census after those repairs was 19 macOS guest diagnostics: four
unused bindings, eight redundant tries, four app-object captures, two picked-file
captures and one non-Sendable work closure. The queue-only posting door, checked
file-capability conformance and typed work closure address the thread warnings;
unused bindings and redundant tries are removed. The single guest compiler
wrapper now demands warnings as errors on both SDKs and both lanes.

Rust: 628 unit tests and 18 doc tests passed (one doc test ignored). Focused
Swift legs: background, confirm, filedialog, clipboard, save and undo passed
before the warning cleanup; background passed again with the queue-only door.

Final strict compile: 52/52 macOS guests and 43/43 iOS guests passed, zero
warnings, through SIL and code generation. The package and interpreter passes
also passed. The whole gate sweep passed 61/61, including the watched negatives.
The complete Mac lane passed 477/477 legs (319 seconds in legs, 192 seconds
in core build and gates; no idle waits). This was the tree before the first
matrix exposed the SDK regression below.

First matrix: Mac 477, Linux 775, Windows 282 and Android 148 legs passed;
61/61 gates passed. iOS passed 135/139. Three Swift toolbar-symbol reads
failed (menus, toolbar, identity); undo's driver attach took 60.29 seconds
and missed the typing request's 30-second deadline. Bundles and step clocks
were read before diagnosis.

The compiler wrapper had cleared SDKROOT: a tiny real compile with explicit
iOS SDK 26.5 and target 16 stamped sdk 16.0. Keeping SDKROOT equal to the
selected SDK stamps sdk 26.5 and minos 16.0; removing duplicate -sdk arguments
alone does not repair it. The wrapper now selects one SDK on both routes.
Every built iOS Swift guest is refused before staging unless its actual
SDK stamp matches SDKSettings.json. Check-pins watched the SDKROOT cut
(two substitutions) fail the same reader. The full Swift iOS suite rerun
passed 46/46 legs, including all four prior failures, in 199 seconds for
builds and legs. The first matrix remains recorded as a failure.

The recorder also gains binary-stamp: the main executable and interpreter's
LC_BUILD_VERSION are captured before each leg and adopted on a failure.
Four capture/adoption negatives pass. A forced-red toolbar leg changed one
expected label (one substitution printed), failed only that assertion, and
left seven recorder sections: six ok, panic honestly skipped. The new
binary-stamp section was read back: main executable minos 16.0 / sdk 26.5,
interpreter minos 17.0 / sdk 26.5. The real symbol assertions passed in that
same failing leg. Bundle: flightrec run 20260919T041509Z-094702,
ios-toolbar-swift. Core rerun: 628 unit tests and 18 doc tests passed.

On the corrected SDK and recorder tree, the complete gate sweep passed
61/61 and the full Mac lane passed 477/477 (185 seconds core build and
gates, 314 seconds legs, no idle waits). The fresh five-lane matrix passed
completely in 1,361 seconds (22 minutes 41 seconds):

| Lane | Passed | Wall seconds | Exclusive waits | Net seconds |
| --- | ---: | ---: | ---: | ---: |
| Mac | 477 | 1,066 | 473 | 593 |
| Linux | 775 | 1,267 | 639 | 628 |
| Windows | 282 | 1,315 | 152 | 1,163 |
| iOS | 139 | 1,235 | 494 | 741 |
| Android | 148 | 1,078 | 411 | 667 |
| Gates | 61/61 | 278 | 0 | 278 |

Every lane remained within its existing net-time ceiling. No timeout or
ceiling was relaxed. The SwiftUI interpreter remains in Swift 5 language mode;
async-dialog APIs remain subject to their separate rulings.
