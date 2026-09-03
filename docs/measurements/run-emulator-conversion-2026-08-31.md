# run-emulator.py -> python (runner conversion, stage 3)

The third runner crossing under docs/runner-conversion-plan.md §4 —
the same shape deploy-win (stage 1) and run-sim (stage 2) landed the
same day: tables into a lanes module, rider EQUAL, one crossing, every
parser re-taught with its negatives re-proven red against the import
path.

## The rider (mechanical, before the crossing)

Old side: scratch extract-old-android.py walks the shell body's four
suite blocks for `run_apk` / `run_apk_tablet` / `run_apk_remount`
calls in source order, plus the `VAR="..."` declared-off lists. New
side: tools/lib/lanes/android.py imported. Compared EQUAL on every
axis, re-run immediately before the shim replaced the shell body:

    DESKTOP_ONLY 4, UNWIRED 0, A11Y_SCENES 3, IME_SCENES 1
    legs[compose] 45 + kinds, legs[jvm] 37 + kinds,
    legs[go] 39 + kinds, legs[python] 2 + kinds
    all legs 123 -> rider(android): ALL EQUAL

The KINDS row is this lane's addition to the rider: each leg's call
kind (pool / tablet / remount) had to survive as FLAGS entries, not
merely its name.

## The enumeration (before designing)

A search agent swept every reader of the runner's bytes plus the
shell gates (the stage-2 lesson: tools/swift-typecheck.sh was stage
2's ninth parser). Nine meaning-parsers: check-steps (six distinct
reads including the synthetic feature_selftest fixture and the
clipboard/device clause), tools/lib/android-leg-order.py (the deepest
— ~19 clause families over the shell body's text),
tools/lib/scene-features.py, check-gates, check-build-id,
check-assets, check-appearance, check-stubs. Plus the byte-readers
(check-shell's >=40 census, check-pins' tools/**/*.sh sweeps,
check-doc-refs' line-length clause), the path literals
(validate-all.py, bench-tables.sh), and the sourced shell library.

Two findings outside the android runner itself:

- tools/bench-tables.sh's MATRIX_RUNNERS still named deploy-win.py
  and run-sim.py — a stage-1/2 miss. The shims exec python3, so a
  pgrep for the .sh basenames could no longer see a live lane (the
  running process's command line names the .py body) and the bench
  would have measured beside a running matrix without refusing. All
  three converted names now point at the .py bodies.
- check-build-id's 2b-android clause held two bare substrings
  ("kaya_write_compose_marker", "component compose") with no negative
  and no floor — exactly the kind of clause a conversion silences.
  It reads the python body line-wise now, with both halves watched
  red (marker writes deleted want=5, compose verify deleted want=1).

## What moved where

- tools/lib/lanes/android.py — SUITE_APPS, SUITES, LEGS (123 legs in
  queue order), FLAGS (tablet / remount / asset_dir / appearance /
  per-leg append), MODS (the cuts, drops and appends per scene),
  A11Y_SCENES, IME_SCENES, DESKTOP_ONLY_SCENES, UNWIRED_SCENES.
- tools/android/run-emulator.py — the body, one crossing. The
  emulator/snapshot state library stays SHELL
  (tools/lib/android-emulator-state.sh — tools/probe-env.sh still
  sources it, docs/runner-conversion-plan.md §6) and is called
  through a `bash -c 'source …; "$@"'` bridge, so there is one copy.
- tools/lib/flightrec_lane.py gains AndroidRecorder (bundle on FAIL,
  leg-log adopt, `adb devices -l` section, spool every leg).
- tools/lib/android-leg-order.py — rewritten whole against the python
  body and the module: the eight-step run_apk_on order, the guarded
  pre/post disarms (the post anchored to the function's tail), the
  staging chain (single install site, disarm-then-install adjacency,
  14 refusal markers, the compose-only tablet targeting line, the
  verify -> icon -> assets -> stage -> legs order), the worker's
  slot/IME/verdict order, the module censuses (A11Y from picker
  verbs, IME from the compose verb, ranges/editor roster membership,
  a 100-leg floor). 38 self-tests, counts printed, every one watched
  red before the file was accepted — two of the first drafts' were
  caught by their own reds (a drain count invisible to non-overlapping
  substring counting; a moved post-disarm whose insertion recreated a
  valid tail shape because the clause was not anchored to the
  function end).

## Stated upgrades over the shell body (each deliberate)

- An unknown suite argument is refused. The shell ran zero blocks and
  printed `run-emulator: ALL PASS`.
- Every scene script (not only the cuts) is precomputed at startup,
  so a missing .steps file kills the lane before boot instead of
  launching an empty script.
- All guest-facing text decodes with errors="replace"
  (docs/traps.md, "NOT UTF-8") — applied preemptively; the class was
  measured on the windows lane in stage 1.
- Deleted: the shell's no-op `am force-stop "${component%%:*}"`
  (force-stop of a component string, stderr-suppressed since it
  always errors).

## The live module red

`table-compose` deleted alone from the module: check-steps stays
green, CORRECTLY — table-jvm and table-go still wire the scene, the
same answer the shell text gave a single deleted `run_apk` line. All
three table legs deleted: check-steps red naming the scene ("no leg
in the android lane module and is not declared off"). Restored from
the saved copy under `shasum -c`, sweep green again.

## Validation

- android-leg-order: 38/38 self-tests, real clauses green.
- check-steps: OK with 4 new android negatives (tablet flag, slot
  lock, claim/release bracket, 3-leg clipboard roster removal) plus
  the module-driven wired()/android_scenes/feature_selftest arms.
- check-gates: OK — LANE_RUNNERS reads run-emulator.py, AndroidRecorder
  joins PY_RECORDERS, the pool pin is the python spelling (N8
  re-proven).
- check-build-id, check-assets (C7 python pattern, N7 doctor moved),
  check-appearance (module row), check-stubs (lanes row),
  check-python (56 bodies, 55 shims incl. run-emulator's),
  check-shell, check-doc-refs (11 anchors re-anchored by meaning),
  check-keyed, keyed-inputs, check-staging, check-case: all OK.
- Full sweep, lane runs and the matrix: recorded below.

## Record

- Script-bytes rider: the OLD shell scene_script/cut/drop functions
  materialized from git HEAD and executed as real bash against the
  same tree, compared with the new script_for() for every scene a leg
  drives: 39/39 EQUAL, every cut and the identity drop included. The
  payload each of the 123 legs sends did not move by one byte.
- Full gate sweep on the converted tree: 50/50.
- Android lane run 1: ALL PASS, 123/123 legs journaled (the run's
  flight-recorder journal carries all 123 under lane `android`),
  staging OK on 5/5 (compose, phones+tablet) and 4/4 ×3. TIMING on
  the warm pool: preflight 3s, boot 3s, cliphelper 2s, legs-compose
  29s, build-jvm 2s, legs-jvm 23s, build-go 3s, legs-go 24s,
  build-python 2s, legs-python 13s.
- Android lane run 2: ALL PASS, 123/123 — boot 2s, legs-compose 31s,
  legs-jvm 24s, legs-go 24s, legs-python 13s.
- Matrix, first attempt: ALL FIVE PLATFORM LANES PASS (mac 349,
  linux 604, windows 201, ios 113, android 123 legs at 242s) and the
  one red was check-doc-refs refusing THIS FILE — the bench-tables
  paragraph quoted the pgrep pattern, whose `.*` reads as a
  glob-shaped path matching nothing. The recording sweep catching the
  record it rides in is the 38d99ac class working as built; the
  sentence carries no path-shaped string now.
- Matrix, the record run: ALL PASS, 1,390 legs — mac 341s/349,
  linux 397s/604, windows 418s/201, ios 465s/113, android 226s/123,
  the gate sweep 50/50 inside it, 616s wall (parallel).
