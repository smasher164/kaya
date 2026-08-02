# Working on kaya — agent operating rules

<!-- Mirrored as AGENTS.md; edit both together. -->

This file is the distilled working doctrine for any agent or contributor.
The architecture and its reasoning live in DESIGN.md — read the relevant
section before changing a subsystem. Workflows and recipes live in
docs/HACKING.md. Known traps live in docs/traps.md. The work ledger lives
in docs/deferred.md.

## The environment

- Every command runs inside the nix dev shell. The tools/ scripts refuse
  to run outside it (they check a fingerprint of flake.nix+flake.lock in
  `KAYA_DEV_SHELL`). Enter with `nix develop`, or wrap one-off commands:
  `nix develop -c <cmd>`. If you edit the flake, re-enter the shell.
- For ad-hoc text processing use python3, never sed/awk (BSD/GNU
  divergence causes recurring breakage; this is repo policy with no
  "trivial enough" exception).
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
- Every cargo invocation carries `--locked` (check-shell enforces it):
  a bare build may rewrite Cargo.lock mid-run, and the lane then goes
  green against a dependency graph nobody chose.
- A built artifact carries the id of the sources it came from
  (tools/build-id.sh). Anything a lane runs or ships gets
  `--verify`'d first — that is the mechanical version of "check the
  build's exit first", and it holds when nobody remembers to.
- `KAYA_FAST=1` skips any gate whose declared inputs have not moved
  since it last passed (tools/keyed.sh; input sets and the reasoning
  live in tools/build-id.sh's GATES). For the INNER LOOP only — the
  matrix never sets it, so the run that goes on the record consults no
  cache and cannot be wrong because of one.
- The maintainer approves every commit and its exact message. Do not
  commit or push on your own initiative.

## The invariants (violating these is never a style choice)

1. **Uniform binding semantics.** kaya has 8 guest-language bindings
   (Rust, Python, Go, C#, Java, Swift, OCaml, Haskell) plus a C floor.
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

## The validation ladder (in order; "done" means the top rung)

1. `cargo test -p kaya --features harness --locked` — unit tests, wire
   round-trips, pin tables,
   compile_fail doc-tests. THE FEATURE IS REQUIRED: `harness` is off by
   default so shipped apps do not carry the scene interpreter, and
   without it the 22 harness tests silently vanish (194 -> 172) rather
   than failing. GTK and WinUI builds need it too — mac/iOS do not,
   since the SwiftUI interpreter carries its own harness.
2. Fast gates (all run by validate-mac, all runnable standalone):
   `tools/gen-header.sh --check`, `tools/gen-bindings.sh --check`,
   `tools/gen-guests.sh --check` (NOTE: diffs generated surfaces against
   git HEAD — cannot pass pre-commit if generated files changed; prove
   idempotence instead and commit generators together with outputs),
   `tools/check-steps.sh`, `tools/check-shell.sh`,
   `tools/check-mirror.sh` (CLAUDE.md and AGENTS.md are true mirrors
   modulo the line-3 comment — they drifted once, silently, for two
   milestones),
   `tools/check-targets.sh` (cross-compiles every cfg'd backend, in BOTH
   feature configurations — it once reported "windows OK" while the
   windows lane failed to build the WinUI accessibility read, which
   only the harness config compiles. LINUX IS ITS HOLE, since gtk-sys
   needs the distro's pkg-config world, so it also text-checks that every
   backend's Stage impl names every required trait method: a trait method
   missed in gtk.rs alone used to survive every fast gate and die in the
   matrix),
   `tools/check-sugar-surface.sh` (every widget kind has a live-zone
   constructor in all 8 bindings, AND every window prop has a sugar
   spelling in all 8 — the generic floor spells a prop without the
   sugar noticing, which is how Python shipped unable to declare
   `list_detail` at all),
   `tools/check-universal-props.sh` (the lowering-side sibling: every
   backend applies the universal a11y props to every kind — Compose
   per-arm, SwiftUI's one wrapper unbypassed, GTK/WinUI's apply arm
   still keyed on the prop alone), `tools/check-abort.sh` (uniform abort
   semantics, all languages),
   `tools/check-tx-liveness.sh` (a transaction is usable only inside
   the build or handler that made it, on the app thread — the HANDLE
   bindings refuse a closed one at a single write chokepoint, the
   AMBIENT ones check the thread instead, having no handle to
   invalidate. The failure it guards is SILENT: a write through an
   already-submitted transaction vanishes with no error, which Go
   shipped for months because its check lived on two chains and not on
   the hundred other callsites), `tools/check-verbs.sh` (every harness verb
   and wire constant present in BOTH interpreter backends — plus the
   spec hash pinned against bindings/c/kaya_wire.h, the
   byte-compared-verdict rule, the vtable rule, and the
   stamped-observation rule),
   `tools/check-stubs.sh` (no runner wires a scene's legs while its
   backend still stubs the feature — depth-slice stubs compile, so
   only this cross-check sees the combination. A DEPTH STUB IS A CALL,
   `depth_stub("<scene>")` / `depthStub` / `kayaDepthStub(_:on:)`, never
   a sentence: as a free-form string the convention went four milestones
   unwritten by any backend, so the gate could only ever pass, and a
   companion check now fails any backend that refuses in its own words.
   check-steps reads the same call from the other side and stops
   demanding those legs, so between them the two state one rule: a
   scene's legs are wired on a runner IF AND ONLY IF that runner's
   backend has the feature. The Swift declaration names its platform,
   because that one file serves mac AND iOS),
   `tools/check-compose.sh` (KayaCompose.kt actually compiles — the
   swift-typecheck sibling; the emulator must never be the first
   compiler to see the Kotlin layer),
   `tools/check-detekt.sh` (dead code in the Kotlin sources; the
   COMPILER cannot serve here — K2 moved the UNUSED_* diagnostics into
   IDE inspections (KT-69698), so a computed-and-never-applied local
   compiles clean, which is how a dead lowering once shipped a false
   green),
   `tools/check-build-id.sh` (the stale-artifact guard is live: each of
   the three compiled artifacts — libkaya, the SwiftUI interpreter, the
   Compose interpreter — carries the id of the sources it came from,
   the verifier rejects one carrying any other, and every lane verifies
   what it runs or ships before it runs or ships it),
   `tools/check-pins.sh` (every dependency resolved over the network
   names an exact version — gradle, nuget, SwiftPM, and the container's
   opam index, none of which has a lockfile the way cargo and nix do;
   the SwiftPM clause is the one whose false green cost a debugging
   round, see docs/traps.md),
   `tools/check-keyed.sh` (the gate cache is honest: a change inside a
   gate's input set re-runs it, a change outside does NOT, a FAILED gate
   is never cached, KAYA_FAST unset consults nothing, and the three
   gates that read a built artifact are never keyed),
   `tools/swift-typecheck.sh` (the guests, the Swift bindings AND the
   SwiftUI interpreter — a gate named after a layer it does not
   compile has burned someone here; docs/traps.md),
   `tools/java-typecheck.sh`,
   `tools/check-ambient-tx.sh` (no guest opens a transaction inside a
   handler — the binding already did, and a guest that opens its own is
   CAMOUFLAGE: five of them hid a real Python defect behind green
   scenes for months),
   `tools/check-wheel.sh`, `python3 bindings/python/kaya_app_checks.py`.
   One gate sits outside validate-mac because it needs docker:
   `tools/check-gtk.sh` compile-checks the GTK backend, which
   check-targets structurally cannot (gtk-sys needs the distro's
   pkg-config world). Run it after any gtk.rs change — a green
   check-targets does NOT mean every backend compiles.
3. `tools/validate-mac.sh` — every scene × every language on the
   SwiftUI interpreter, the one macOS backend (opens windows briefly;
   needs a logged-in GUI session).
4. The cross-platform matrix, before any feature is called landed:
   `tools/validate-all.sh` — ALL FIVE lanes concurrently by default
   (bounded by the slowest lane, ~1 minute warm; ratified
   2026-07-22). `--serial` for the special cases: single-lane
   benchmarking, debugging under contention, recording mode. The
   lanes remain individually runnable (`tools/validate-linux.sh`,
   `tools/ios/run-sim.sh`, `tools/android/run-emulator.sh`,
   `tools/deploy-win.sh akhil@192.168.64.2 all`;
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
rather than compile-checked. tools/check-verbs.sh now enforces coverage,
but when adding anything new, verify all four layers in BOTH files:
constants, apply arm, render/model, step-verb arm.
