# validate-mac.py -> python (runner conversion, stage 4, first item)

The fourth runner crossing under docs/runner-conversion-plan.md §4 —
the mac lane, the largest roster (349 legs) and the runner that also
carries the scene×language sweep tables check-steps reads.

## The enumeration (before designing)

A search agent swept every reader of the runner's bytes plus the shell
gates and the basename literals (the stage-3 lesson). The
meaning-parsers: check-steps (SIX reads — wired()'s mac arm, the
feature_selftest fixture, sweep_guests' TWO `SCENES=` reads including
the unguarded exactness clause the stage-1 record had flagged,
sweep_c_floor's two mac clauses, family_serial's clipboard and save
calls, go_desktop_scenes' mac row), check-gates (the delegation
clause + N3, the lane contract, rung2's CLAUDE.md anchor),
check-build-id, check-assets (NOTHING_NEEDED), check-appearance (N9),
check-stubs, scene-features, check-staging (three reads + N1/N3), and
tools/flightrec-selftest.py — the deepest: it CUT the real run() out
of the shell body by brace depth and executed it.

The enumeration's own finds, fixed in this slice:

- An EIGHT-ITEM silent-vacuity list: the check-stubs and
  scene-features mac rows had no roster floor (a shim would green
  them silently), sweep_guests' exactness clause rode a bare `if m:`,
  sweep_c_floor's mac clauses vanish wordlessly with the `make -C`
  line, and check-build-id's verifies_swiftui NEVER included
  validate-mac — the mac lane's second-artifact verify (the
  matrix-handshake skip path) was asserted by nobody for as long as
  it has existed. All eight are module imports with floors or new
  watched clauses now.
- bench-tables.sh's MATRIX_RUNNERS pgrep basename, again.

## What moved where

- tools/lib/lanes/mac.py — SCENES (41), DEPTH_SCENES, C_SCENES (the
  build_c list sweep_c_floor reads from the other side), LANGS,
  GUEST_STEM (listdetail runs split's guests), DARK_LEG, HAND_QUEUED,
  and ORDER: the whole queue as data — scene groups with their OWN
  language order (dirty carries no java leg; styling seats swift
  fourth), drains as explicit entries, the three panel-mode rotations,
  the panel census point, and the serial families as single-language
  groups between drains.
- tools/validate-mac.py — the body. The swift toolchain resolution
  stays in tools/lib/swift-toolchain.sh (ten shell consumers) behind
  a one-line bash bridge; the panel-mode rotation keeps its stamp
  file, read-back verification and modes-run census; the recording
  mode keeps the one-SCK-stream shape, the content-hashed recorder
  binary and the TRACKING gate; the matrix handshake and the
  gates-skip path's swiftui verify are unchanged in meaning.
- tools/lib/flightrec_lane.py gains MacRecorder — the per-leg sampler
  (a thread over the leg's `timeout` process: cheap lines every 2s,
  ONE `sample` plus a window shot while the guest still lives) and
  the at-fail capture (sampler, sample, leg-log, WindowServer, the
  guest's own window by id, bounded unified log). The 254 lines of
  mac-only shell left tools/lib/flightrec.sh with a pointer — the
  linux lane keeps the generic half.
- LaneRecorder.section() now writes an HONEST SKIP naming a capture
  tool the host does not have (the shell's behavior, which the first
  python port had quietly downgraded to a nameless "error" mark —
  flightrec-selftest N2 is what surfaced it).
- tools/flightrec-selftest.py rewritten: it drives the REAL
  MacRecorder imported from the real module (N0 fails a real leg and
  demands all seven sections accounted; N1/N2 doctor a COPY of the
  module and demand the missing section named and the honest skip);
  the one paraphrase left — the driver's leg sequence — is PINNED
  against the runner's own _leg_worker (four recorder calls, in
  order, read out of validate-mac.py by ast). N6 gains the python
  static half: LaneRecorder.leg may not spawn.

## Stated upgrades (each deliberate)

- Per-leg script env: the shell exported KAYA_SELFTEST_SCRIPT once
  per group and it PERSISTED — a leg placed after another scene's
  export silently ran that scene's steps, which the shell's own
  comment records happening. The python runner passes the script in
  each leg's env; the hazard class is structurally gone.
- `dotnet exec` everywhere: the shell's window/panels csharp legs
  spelled bare `dotnet` — same operation, one spelling now.
- The three-mode panel rotation, the stamp-restore-verify dance and
  the SIGKILL-recovery path are behavior-identical.

## The riders

- ROSTER RIDER: the full event stream — 349 legs in order with their
  effective KAYA_SELFTEST, guest stems, the appearance rider, 50
  drains (consecutive drains collapsed, provably inert) and 3
  panel-mode sets — extracted from the shell body vs derived from the
  module: ALL EQUAL. SCENES 41/41, DEPTH 3, C_SCENES 7 EQUAL.
- SCRIPT-BYTES RIDER: the shell's scene_script (`grep -v '^#'`,
  newlines KEPT on this lane, `$()`-stripped) vs the python
  scene_script for all 48 scenes a leg drives: ALL EQUAL.

## The live module red

The whole ("table", LANGS) group deleted from the real module:
check-steps red TWICE OVER — wired()'s mac arm naming the scene, and
the per-guest exactness sweep naming every missing leg by its exact
name. Restored from the saved copy under `shasum -c`, green again.

## The recorder fix the first live bundle bought

Lane run 1 went 348/349 — save-c-swiftui red, "save dialog state
unavailable" for 15s on its FIRST save panel, the identical steps
green seconds later, all eight other save legs green. The MacRecorder
fired for real for the first time and its bundle held the answer:
WindowServer at 53.8% when the leg started (decaying 50 → 31 → 17 →
~13 as the preceding drain's load settled), so the panel's
accessibility state was late — the pre-existing contention class, now
EVIDENCED instead of guessed. Reading that bundle also caught a real
conversion defect: `guest_pid=none` for the leg's whole 29s. The
shell sampler received the leg SUBSHELL's pid and found `timeout`
among its descendants; the python sampler receives the `timeout`
Popen itself, and the anchored walk never looked at the root. Fixed
(the root is an anchor when its comm is `timeout`), and
flightrec-selftest's N0 now fails a guest that LIVES five seconds and
demands `guest_pid=<digits>` in the sampler history — /usr/bin/false
exits before the first tick and proved nothing about resolution —
with N0b watching the descendants-only shape stay refused.

## One transient, recorded — CAUSE FOUND the next morning

The first post-conversion gate sweep hung at check-sugar-surface
(gate 14/50): the log went silent for 23 minutes after that gate's
haskell self-tests and the monitor killed it. Standalone
reproduction immediately after: clean at normal speed; the rerun
sweep with a stall sampler armed: 50/50 with no stall. RESOLVED: the
laptop lid was closed and the machine slept — the same silence
recurred at check-keyed during the gates.py conversion's sweep, and
the maintainer's morning message supplied the cause
(docs/measurements/gates-conversion-2026-09-01.md). Not a code
finding.

## Record

- Full gate sweep on the converted tree: 50/50.
- Mac lane run 1: 348/349 (the evidenced save-c contention red
  above); core-build+gates 277s, guest-builds+bench 13s, legs 269s;
  the three panel view modes rotated and restored (1, 2, 3,
  restoring 3).
- Mac lane runs 2 and 3, after the recorder fix: ALL PASS 349/349
  both — legs 248s and 243s, guest builds 13s.
- Matrix, first attempt: mac PASS under the matrix (348s, 349 legs),
  linux/windows/android/gates PASS — the one red was the iOS lane's
  a11y-swift, a 3s process CRASH at its first expect_ax ("Object of
  class _DictionaryStorage deallocated with non-zero retain count 3",
  the guest dead before any verdict). Nothing in this stage touches
  that lane; the leg was green in every prior matrix including three
  the same night, and its bundle (leg log + device roster) is run
  20260901T075133Z. First sighting of this shape — if it recurs it
  earns a WATCH entry in the ledger.
- Matrix, the record run: ALL PASS, 1,390 legs — mac 340s/349,
  linux 438s/604, windows 425s/201, ios 491s/113, android 240s/123,
  the gate sweep 50/50 inside it, 657s wall (parallel).
