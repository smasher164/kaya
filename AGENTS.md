# Working on kaya — agent operating rules

<!-- Mirror of CLAUDE.md; edit both together. -->

This file is the distilled working doctrine for any agent or contributor.
The architecture and its reasoning live in DESIGN.md — read the relevant
section before changing a subsystem. Workflows and recipes live in
docs/HACKING.md. Known traps live in docs/traps.md. The work ledger lives
in docs/deferred.md. What each fast gate holds, and why, lives in
docs/gates.md.

## The environment

- Every command runs inside the nix dev shell. The tools/ scripts refuse
  to run outside it (they check a fingerprint of flake.nix+flake.lock in
  `KAYA_DEV_SHELL`). Enter with `nix develop`, or wrap one-off commands:
  `nix develop -c <cmd>`. If you edit the flake, re-enter the shell.
- For ad-hoc text processing use python3, never sed/awk (BSD/GNU
  divergence causes recurring breakage; this is repo policy with no
  "trivial enough" exception).
- New tools/ scripts are written in PYTHON FIRST, on the kaya_gate
  prelude (ruled 2026-08-31, after the gate tier's conversion measured
  its wins) — shell remains only for the launcher shapes: in-container
  and in-toolchain payloads, the guest-side .cmd schtasks stubs, and
  thin wrappers whose consumers are still shell, each such choice
  stated where it stands. Nothing new joins a porting backlog.
- Never pipe a build through `tail`/`head` in a verify loop — the
  pipeline's exit status becomes tail's, and a failed build silently
  runs the test against a stale artifact. Check the build's exit first.
- `$?` is read exactly once, on the line right after the command, into
  a named variable; everything downstream tests the VARIABLE. It is not
  a value you can come back for: an `if` that took no branch exits 0
  ITSELF, a bare `local rc` on the line between is a command and resets
  it, and a `[` overwrites it. shellcheck reports none of those three
  at warning level; check-shell enforces the shape. (`local rc=$?` on
  one line is fine — the expansion beats the command.)
- Every cargo invocation carries `--locked` (check-shell enforces it
  in shell, check-python's rule 11 in the converted gate bodies):
  a bare build may rewrite Cargo.lock mid-run, and the lane then goes
  green against a dependency graph nobody chose.
- A built artifact carries the id of the sources it came from
  (tools/build-id.py). Anything a lane runs or ships gets
  `--verify`'d first — that is the mechanical version of "check the
  build's exit first", and it holds when nobody remembers to.
- `KAYA_FAST=1` skips any gate whose declared inputs have not moved
  since it last passed (tools/keyed.py; input sets and the reasoning
  live in tools/build-id.py's GATES). For the INNER LOOP only — the
  matrix never sets it, so the run that goes on the record consults no
  cache and cannot be wrong because of one.
- A COMMENT SURVIVES ONLY IF A FUTURE SESSION NEEDS IT to avoid a
  mistake (the maintainer's rule, ratified 2026-08-18: "the only things
  you shouldn't cut are things you'll need for future claude sessions
  that might need that context. everything else should be nixed,
  because it just makes things harder to read"). API narration,
  teaching prose about how kaya works, restated invariants, arguments
  that the code is correct, and the history of how we arrived are all
  nixed — the reader has the call in front of them, and DESIGN.md,
  this file and the plans hold the rest.
  AND WHERE THE CONTENT LIVES SOMEWHERE ELSE, THE COMMENT IS A POINTER.
  A line naming the gate that enforces it, or the trap, plan or ledger
  entry that records it, is the whole comment; a second copy of the
  reasoning only rots out of step with the first.
  THE ONE THING NEVER DELETED IS A MEASURED FINDING NOBODY ELSE WROTE
  DOWN. It moves to docs/traps.md FIRST and the pointer stays behind —
  deleting it is the only unrecoverable move in this rule, since a
  measurement costs a session to make again and prose costs nothing.
  The examples are held tightest of all: a guest should read as the
  kaya calls it makes.
- A "TOOL NOT FOUND" IS A QUESTION, NOT AN ANSWER. Every toolchain the
  lanes use is wrapped or routed (`kaya_swiftc`, simctl through Xcode's
  DEVELOPER_DIR, the recorder's window shots, the linux image), and the
  bare name fails inside the dev shell by design. Before reporting
  anything unavailable, read docs/HACKING.md's Hand tools table and use
  the route the lanes use; a bare `swiftc` in the shell is a shim that
  names the wrapper (ruled 2026-09-07 after the same miss for the nth
  time).
- EVERY CHANGE NAMES ITS GUARD (the maintainer, 2026-09-07): invariant 3
  applies to every edit, not only to a fix. Before the commit, say which
  wall, gate or compile-time refusal would catch the mistake this change
  could have been, and add it if it is missing — or record why not.
- A RED LEG IS READ FROM THE FLIGHT RECORDER FIRST. Every failed leg
  prints `flightrec: bundle <path>`; the bundle (leg log, verb trace, the
  lane's samplers) and the leg's step clock are read before any
  hypothesis, and a fault sentence that names no call is the first thing
  to fix (docs/traps.md, the row-window fault of 2026-09-07 — a guard was
  proposed from a mechanism the code contradicted, before the bundle was
  opened). AND A BUNDLE THAT COULD NOT NAME THE CAUSE IS THE DEFECT TO FIX
  (the maintainer, 2026-09-16): when the read needed something the bundle
  does not carry — a desktop picture, a toast's text, a screenshot on a
  phone, a diagnostic line between two others — the recorder grows that
  section for the next sighting, proven by forcing a red leg and reading
  it back, and no WATCH entry is filed in its place. A watch is for a
  cause the recorder already carries everything about and still needs a
  second sighting to settle.
- A FEATURE SLICE ENDS WITH A REVIEW PAGE: captures of the change on
  every lane, each one viewed before it is published, on an artifact the
  maintainer reviews (the search field's page is the shape). A feature
  the maintainer has not seen is not delivered.
- The maintainer granted standing approval for commits on 2026-09-18 and
  pushes on 2026-09-19. Commit and push validated slices without asking for
  each message. Unresolved design rulings still require his decision.

## The invariants (violating these is never a style choice)

1. **Uniform binding semantics.** kaya has 9 guest-language bindings
   (Rust, Python, Go, C#, Java, Swift, OCaml, Haskell, JS) plus a C floor.
   Any binding-level behavior — transaction rollback, abort handling,
   read guards, command surfaces — has ONE observable semantics in all
   of them. The language's idiom decides the *spelling* (exceptions vs
   panics vs Drop), never the *semantics*. Divergence is allowed only
   where a language literally cannot express the behavior, and the
   carve-out itself must be stated uniformly (see DESIGN.md's Binding
   conventions).
2. **Sweep all bindings.** A change to any binding surface is assessed
   against every guest language with an explicit do/can't/defer verdict
   per language. Never scope silently to the languages a request names.
3. **Failures become guards, ON A PATH NOBODY CAN AVOID.** Every
   failure class found gets a structural guard — types over generation
   over runtime checks — plus a negative test. If you fix a bug, ask
   what gate would have caught it and add that gate.
   AND THEN ASK WHERE IT SITS. A guard you have to remember to run is
   barely a guard: the session that needs it most is the one with no
   context, and it will not think to run your gate. Put the wall where
   someone walks into it by doing something BASIC — building, running
   the scene, deploying — and make the error say what to do next. A
   stale binding generator fails `cargo build` naming the fix
   (crates/kaya/build.rs); an unexpanded `$PID` fails the verb that
   reads it; a wrong scene name panics the guest. Prefer that to one
   more entry in a gate list, and when only a gate will do, put it in
   the set the lanes already run. Plan against your future self.
   AND WATCH THE NEGATIVE TEST FAIL. A negative test is only a test if
   the perturbation is PROVEN to have applied: print the substitution
   count and treat an unchanged file as a failed test, not a passed
   one. This has misfired twice — three of check-tx-liveness's five
   clauses passed with the guard deleted (grepping a bare function name
   matched the definition as well as the call), and the wayland seat
   guard's negative test passed VACUOUSLY TWICE because the pattern
   never matched the file at all. A guard you believe in but have never
   seen fail is worse than none: it stops you looking.
   AND THE SAME RULE COVERS DIAGNOSTICS. A why-not — any function whose
   job is to answer "why did that fail?" — is believed: the sentence it
   prints is what the next reader chases. So every branch of one must
   have been MADE TO PRINT before you trust it, exactly as a negative
   test must be watched failing. A branch nobody has seen print is a
   guess about a state nobody has reached. `kayaOpenPanelWhyNot()`
   blamed a fullscreen application for a missing NSOpenPanel; that
   branch was taken on EVERY mac leg (kaya's guests run `.accessory`,
   so `isActive` is always false), the branch under it was dead, and
   every claim in the sentence was false. Half an hour lost when it was
   written, and a whole session months later spent on macOS activation
   while the real cause was the panel's view mode. A DIAGNOSTIC MAY ONLY
   PRINT WHAT IT MEASURED; if it cannot tell two causes apart it says so
   and prints what it can see (docs/traps.md).
   `tools/check-diagnostics.py` holds the shape of that — one answer, or
   an answer on the failure path that interpolates nothing, is a
   sentence that cannot discriminate — but a branch that discriminates
   and is still wrong is caught only by the review question.
4. **Validation scripts build and verify what they ship.** No stale
   artifacts, no bypassed mechanisms, no false PASS. A gate that can be
   satisfied without exercising the real thing is a bug in the gate.
5. **Examples use the construction sugar.** All example scenes use each
   language's sugar tier; only the C guests keep the fully explicit
   floor (deliberately, as the floor's documentation).
6. **Scene scripts are shared verbatim.** tools/scenes/*.steps feed
   every platform; expected strings are compared byte-for-byte across
   all languages, so guest output strings must be identical everywhere.
7. **The spec is the root.** Protocol changes start in
   crates/kaya/src/spec.rs; the spec hash moves; everything regenerates
   in lockstep (see the regeneration workflow in docs/HACKING.md).
   Generated files are never hand-edited.
8. **A duration anomaly is a bug signal.** If something is unexpectedly
   slow, investigate immediately — sample the interim state right then;
   never queue more work behind it.
9. **The ledger is not append-only.** Closing a deferred entry means
   striking the headline WITH its resolution — the strike and the note
   are one edit, never two — and then grepping the entry's key nouns
   across docs/ and the code comments and updating every hit. A fix
   recorded in a neighbouring entry is not recorded, and a headline
   nobody struck is what the next reader believes: two entries headlined
   "GAP — … cannot / is not implemented" carried "COMPLETE … matrix ALL
   PASS" in their own bodies for three weeks, and a survey reported a
   solved problem as the largest open one. So new entries carry a
   `KEY:` line naming the greppable nouns they will have to be swept
   for — the entry describes its own closing sweep, rather than leaving
   the next person to guess what to search. `tools/check-ledger.py`
   holds the strike-and-note half; the sweep is yours.

## The validation ladder (in order; "done" means the top rung)

1. `cargo test -p kaya --features harness --locked` — unit tests, wire
   round-trips, pin tables,
   compile_fail doc-tests. THE FEATURE IS REQUIRED: `harness` is off by
   default so shipped apps do not carry the scene interpreter, and
   without it the 22 harness tests silently vanish (194 -> 172) rather
   than failing. GTK and WinUI builds need it too — mac/iOS do not,
   since the SwiftUI interpreter carries its own harness.
   IT RUNS WHERE YOU TYPE IT, which is why the windows lane now runs the
   core's unit tests ON THE GUEST as well (tools/deploy-win.py's
   unit-tests phase, filtered to `capi::picked_tests`): the Windows half
   of the core — the HANDLE arms of protocol.rs's
   raw_handle/file_from_raw — is code no unix run compiles, and the one
   test of the redemption path had `#[cfg(all(test, unix))]` on it for
   four milestones. The phase refuses unless the number that passed
   equals the number of `#[test]`s the module declares, because a filter
   that matches nothing exits 0 saying "0 passed". The rest of the suite
   is 309/312 on that guest; the 3 are POSIX assumptions in harness
   tests, and fixing them is what widens the filter.
2. Fast gates. `tools/gates.py` runs ALL of them and is the only thing
   that should. Each gate's description, the incident behind it and its
   watched negatives are its section in docs/gates.md; the list below is
   that file's index, and `tools/check-gates.py` holds this list, gates.py's
   list, validate-mac's delegation and docs/gates.md's sections to ONE
   census, and it fails naming both sides of any disagreement. How the sweep
   runs (the full account is docs/gates.md's first section):
   - IT RUNS RUNG 1 FIRST, in its build phase, through `tools/unit-suite.py`
     (the rung's own command; it refuses a FAILED binary, a suite that never
     built, a nonzero exit under green lines, and a COLLAPSE below a floor
     of 600, which is the `harness` feature's wall). The reason is
     mechanical: `cargo test` relinks the host libkaya and NO GATE MAY (the
     sweep refuses a verdict if that library moves under it), while BUILD is
     the library's one writer. Once a matrix: validate-all's own --build
     runs rung 1, keys its inputs (build-id's `unit-suite` set) and hands the
     key to the sweep, which skips its run only while the key still holds.
   - BUILD also builds libkaya and the SwiftUI interpreter FIRST, since a
     gate cannot verify an artifact the run has not built yet, and ends with
     tools/prune-objects.py.
   - It REFUSES A VERDICT unless the number of gates that ran equals the
     number it declared. There is deliberately no subset flag, because a
     flag that runs part of the list and still prints a verdict is the
     under-run defect with an interface; to run one gate, run that gate.
   - A GATE IS ITS `.py` FILE, run directly: executable, python shebang, the
     dev-shell check inside, imported against tools/lib/kaya_gate.py, so
     `tools/check-steps.py` is the whole invocation.
   - `KAYA_FAST=1` skips a keyed gate whose inputs have not moved (The
     environment above); check-build-id is never keyed.
   - Under a matrix the ONE sweep starts after Android exits, at niceness
     10, four gates wide, in a cargo target of its own
     (CARGO_TARGET_DIR=target/gate-sweep, host_lib.SWEEP_TARGET); gates.py
     refuses a matrix sweep anywhere else.
   - The walls (tools/lib/walls.py): gates.py kills a gate past max(1200s,
     10x its WEIGHT); validate-all kills a lane's process group past
     max(2400s, 2x its ceiling) or 300s after its own verdict line;
     deploy-win bounds every ssh call and joins its leg workers through a
     1200s wall.
   - A new gate joins gates.py's GATES (or its EXCLUDED table, with a
     reason), this index and a section of docs/gates.md, in one change.
   - `tools/check-gtk.py` sits OUTSIDE the sweep (gates.py's EXCLUDED: it
     needs docker). It is the only compile of the GTK backend, which
     check-targets structurally cannot do, so run it after any gtk.rs change
     — a green check-targets does NOT mean every backend compiles.

   The gates, in docs/gates.md's order (each one's section there):
   - `tools/gen-header.py --check`, `tools/gen-bindings.py --check`,
     `tools/gen-guests.py --check` — generated files equal the generators'
     output; the tree restored byte for byte.
   - `tools/check-steps.py` — scene scripts well formed; save scene's
     missing-handle cases; every primary window titled.
   - `tools/check-shell.py` — shellcheck plus the repo's shell rules: `$?`,
     --locked, no sed/awk.
   - `tools/check-python.py` — the eleven rules on python gate bodies, ruff's
     F family, the prelude's negatives.
   - `tools/check-mirror.py` — CLAUDE.md and AGENTS.md identical but for
     line 3.
   - `tools/check-gates.py` — this index, gates.py, validate-mac and
     docs/gates.md one census; the matrix launch order.
   - `tools/check-ledger.py` — no docs/deferred.md headline disagrees with
     its own resolution.
   - `tools/check-doc-refs.py` — every path a tracked .md names exists.
   - `tools/check-case.py` — every tracked path matches the filesystem's
     case exactly.
   - `tools/check-targets.py` — every cfg'd backend cross-compiles in both
     feature configurations; Stage trait coverage.
   - `tools/check-sugar-surface.py` — every kind, prop and feature surface
     has its sugar spelling in all nine bindings.
   - `tools/check-universal-props.py` — every backend applies the universal
     a11y props to every kind.
   - `tools/check-roles.py` — the role vocabulary reaches every backend (red
     by design across a fan-out).
   - `tools/check-native-undo.py` — the native-tier undo guards and the
     app-owned undo's off switch, per arm.
   - `tools/check-slider-commit.py` — a slider, colour picker or range
     commits once per gesture on every backend.
   - `tools/check-submit.py` — `submitted` publishes only through the
     gesture's door, on every backend.
   - `tools/check-scroll-to.py` — the app's scroll lands instantly, holds
     until layout, shares the tiers' park.
   - `tools/check-search.py` — the search field clears one way and reports
     its platform identity.
   - `tools/check-exclusive.py` — the matrix-wide exclusive token and the
     idle-host waits are wired at each funnel.
   - `tools/check-flightrec.py` — a red leg's bundle names its cause on
     every lane.
   - `tools/check-diagnostics.py` — a why-not may not print a sentence it
     cannot have measured.
   - `tools/check-harness-ceiling.py` — every step has a ceiling; a
     published verdict exits within the grace.
   - `tools/check-empty-child.py` — one node is one widget, even when its
     content will not decode.
   - `tools/check-pane-ladder.py` — the macOS pane ladder's arithmetic; no
     column minimum declared to SwiftUI.
   - `tools/check-table-tier.py` — the table's tier routing and its geometry
     generation, which no device can assert.
   - `tools/check-window-memory.py` — the macOS window memory, fullscreen
     saves, and the hit shape after a resize.
   - `tools/check-canvas-blit.py` — kaya rasterizes, backends blit: pixel
     format, scale, canonical raster settings.
   - `tools/check-appearance.py` — appearance, text-scale and locale knobs
     inert unless asked, read back from the toolkit.
   - `tools/check-abort.py` — uniform abort, scoped-transaction and
     async-dialog semantics in every binding.
   - `tools/check-tx-liveness.py` — a transaction is usable only inside its
     build or handler, on the app thread.
   - `tools/check-verbs.py` — every harness verb and wire constant in both
     interpreters; spec hash; verdict text.
   - `tools/check-file-modes.py` — the file-mode numbers agree with the spec
     wherever they are written.
   - `tools/check-app-identity.py` — one declared app identity; every copy
     and the frozen icon expectation agree.
   - `tools/check-assets.py` — one asset root, one resolver; every lane
     stages and hash-verifies the whole root.
   - `tools/check-staging.py` — every wired leg's artifact is in its
     runner's staging derivation.
   - `tools/check-c-ids.py` — the C guests' widget and template-node ids
     share one id space.
   - `tools/check-c-bounds.py` — the C floor refuses past its buffer cap
     instead of writing past it.
   - `tools/check-stubs.py` — no runner wires a scene's legs while its
     backend still calls `depth_stub`.
   - `tools/check-compose.py` — KayaCompose.kt compiles.
   - `tools/check-detekt.py` — no dead code in the Kotlin sources.
   - `tools/check-compose-state.py` — every model field a composable draws
     from is composition state.
   - `tools/check-jni.py` — every declared native is in a registration
     list, on both attach paths.
   - `tools/check-build-id.py` — each compiled artifact carries its sources'
     id, every lane verifies it, and cargo, make and MSBuild judge by content.
   - `tools/check-pins.py` — every dependency fetched over the network names
     an exact version (and bytes).
   - `tools/check-design-generation.py` — every mac leg's main executable is
     stamped modern (kaya's launchers; the old look is dropped).
   - `tools/check-symbols.py` — every SF symbol name exists at kaya's macOS
     floor.
   - `tools/check-symbol-parity.py` — one symbol vocabulary across its six
     files.
   - `tools/check-accent.py` — the WinUI accent writes exactly the six
     derived stops.
   - `tools/check-table-card.py` — a table bounds its own extent with a
     flat, tokened card per platform.
   - `tools/check-doctabs.py` — document tabs: the Mac strip through public
     API only, every document prop applied or depth-stubbed per backend.
   - `tools/check-keyed.py` — the gate cache re-runs on input change and
     never caches a failure.
   - `tools/swift-typecheck.sh` — the Swift guests, the Swift bindings and
     the SwiftUI interpreter typecheck.
   - `tools/java-typecheck.py` — the Java binding and guests compile; a
     large record encodes and reads back.
   - `tools/check-ambient-tx.py` — no guest opens a transaction inside a
     handler.
   - `tools/check-go-env.py` — a Go guest reads the host environment through
     kaya.Env, never os.Getenv.
   - `tools/check-wheel.py` — the built python wheel installs and imports
     through the installed package.
   - `python3 bindings/python/kaya_app_checks.py` — the python surface's
     negatives against the real binding.
   - `tools/js-typecheck.py` — strict tsc over the JS binding and every JS
     guest.
   - `node bindings/js/kaya_app_checks.ts` — the JS surface's negatives, the
     python checks' twin.
   - `tools/go-typecheck.py` — `go vet` over the one Go module.
   - `tools/py-typecheck.py` — pyright over the python binding and guests;
     exported-type completeness held at 100%.
   - `tools/check-l10n.py` — every message a guest names exists in every
     catalog, with matching arguments.
   - `tools/check-winui-bindings.py` — winui/bindings.rs equals what
     tools/winui-bindgen generates.
   - `tools/check-gtk.py` (outside the sweep, above) — compiles the GTK
     backend in docker.
3. `tools/validate-mac.py` — every scene × every language on the
   SwiftUI interpreter, the one macOS backend (opens windows briefly;
   needs a logged-in GUI session).
4. The cross-platform matrix, before any feature is called landed:
   `tools/validate-all.py` — ALL FIVE platform lanes run concurrently by
   default (ratified 2026-07-22). `--no-exclusive` leaves out the
   input-driving legs every lane names in its EXCLUSIVE set (the drags,
   the dialogs, the pastes) for the everyday matrix; `--exclusive` runs
   those alone, nothing else on the host; a commit wants both halves
   green on one tree, or the plain run (docs/HACKING.md, Exclusive legs).
   `--only <prefix,...>` runs the legs whose names start with a prefix on
   every lane and nothing else, no gate sweep, verdict marked FILTERED
   (tools/lib/only.py; the maintainer, 2026-09-24): the legs a change
   touched, in minutes, BEFORE the matrix — two locale races took two full
   matrices to find when six filtered legs would have said it. Never the
   record.
   Any other flag, `--help` among them, prints the usage and starts
   nothing (tools/lib/matrix_args.py; check-gates runs its cases).
   After Android exits, the one `nice -n 10` gate sweep runs in its own
   cargo target (since 2026-10-16, so it no longer waits for the mac lane;
   docs/traps.md, the sweep-relinked-libkaya entry) FOUR GATES
   WIDE (since 2026-09-07) and hides behind the longer lanes, so the wall
   is the slowest lane. One gate at a time it was Android plus the sweep
   in series, 654 + 422 = 1082s on the last such matrix; launched at t0
   beside the lanes it slowed every lane by 150-200s for a 116s gain
   (matrix #24), which is why it still waits.
   THE ANDROID MICROPHONE LEGS RUN LAST (the maintainer, 2026-10-05): the
   emulator's audio input breaks whenever the host starves it, so the
   parallel Android lane runs with KAYA_QUIET=skip and the `android-quiet`
   row runs its QUIET legs alone after every lane and the sweep
   (docs/traps.md, the emulator's audio input entry; check-gates holds the
   order, check-exclusive the set).
   AND THE LINUX REAL-TIME MEDIA LEGS RUN AFTER IT (the maintainer,
   2026-10-16): media_tracks' second cue is a 1 s window and a matrix stops
   the docker VM for longer, so the parallel linux lane runs with
   KAYA_QUIET=skip and a `linux-quiet` row runs tools/lib/lanes/linux.py's
   QUIET scenes once the android tail is joined (docs/traps.md, a linux VM
   off every CPU for longer than a cue; check-gates holds the order,
   check-exclusive the set). They are not exclusive: --no-exclusive keeps
   them and --exclusive leaves them out.
   `--serial` is for the special cases: single-lane benchmarking,
   debugging under contention, recording mode. The
   lanes remain individually runnable (`tools/validate-linux.py`,
   `tools/ios/run-sim.py`, `tools/android/run-emulator.py`,
   `tools/deploy-win.py akhil@192.168.64.2 all`;
   `tools/probe-env.sh` checks all environments). Fix-forward if a
   platform fails.

## Sequencing pattern for features

Depth then breadth: land the protocol + one backend (SwiftUI on mac)
+ one binding (Rust) + the scene, get it green on mac, then fan out
backends and bindings in parallel, then run the full matrix. Between-phase gates
keep half-landed states honest — some gates (check-verbs,
check-sugar-surface) are DESIGNED to stay red mid-milestone, holding the
remaining work open; that is not a regression.

## Interpreter backends are the historic miss layer

SwiftUI (swift/KayaSwiftUI.swift) and Compose
(android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt) re-implement the
harness verbs and carry private copies of wire constants, string-matched
rather than compile-checked. tools/check-verbs.py now enforces coverage,
but when adding anything new, verify all four layers in BOTH files:
constants, apply arm, render/model, step-verb arm.
