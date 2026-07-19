# Working on kaya — agent operating rules

<!-- Mirror of CLAUDE.md; edit both together. -->

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
3. **Failures become guards.** Every failure class found gets a
   structural guard — types over generation over runtime checks — plus
   a negative test. Never rely on remembering. If you fix a bug, ask
   what gate would have caught it and add that gate.
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

1. `cargo test -p kaya` — unit tests, wire round-trips, pin tables,
   compile_fail doc-tests.
2. Fast gates (all run by validate-mac, all runnable standalone):
   `tools/gen-header.sh --check`, `tools/gen-bindings.sh --check`,
   `tools/gen-guests.sh --check` (NOTE: diffs generated surfaces against
   git HEAD — cannot pass pre-commit if generated files changed; prove
   idempotence instead and commit generators together with outputs),
   `tools/check-steps.sh`, `tools/check-shell.sh`,
   `tools/check-targets.sh` (cross-compiles every cfg'd backend),
   `tools/check-sugar-surface.sh` (every widget kind has a live-zone
   constructor in all 8 bindings), `tools/check-abort.sh` (uniform abort
   semantics, all languages), `tools/check-verbs.sh` (every harness verb
   and wire constant present in BOTH interpreter backends),
   `tools/check-wheel.sh`, `python3 bindings/python/kaya_app_checks.py`.
3. `tools/validate-mac.sh` — every scene × every language × AppKit and
   SwiftUI (opens windows briefly; needs a logged-in GUI session).
4. The cross-platform matrix, before any feature is called landed:
   `tools/validate-linux.sh` (docker; GTK on X11+Wayland),
   `tools/ios/run-sim.sh`, `tools/android/run-emulator.sh`,
   `tools/deploy-win.sh akhil@192.168.64.2 all` (the UTM VM;
   deploy-win auto-starts it; `tools/probe-env.sh` checks all
   environments). Fix-forward if a platform fails.

## Sequencing pattern for features

Depth then breadth: land the protocol + one backend (AppKit) + one
binding (Rust) + the scene, get it green on mac, then fan out backends
and bindings in parallel, then run the full matrix. Between-phase gates
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
