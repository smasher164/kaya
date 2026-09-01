# The deploy-win port — enumeration, rider and re-teach record (2026-08-31)

Tranche three, stage one of docs/runner-conversion-plan.md: the windows
runner's tables became tools/lib/lanes/win.py, the body became
tools/deploy-win.py (tools/deploy-win.sh is the pinned two-line shim),
and the eight gates that parsed the shell body's text were re-taught in
the same slice. This file records what was measured, because the plan
ratified the schema against the enumeration and the enumeration found
things the plan's list did not name.

## The enumeration (before the schema)

Every parse site was re-verified against the tree at c9f18a7 before a
line of the module was written. Corrections to the received map:

- check-steps' roster reads use `run_suite\s+([a-z0-9_]+)\s*$` on
  comment-stripped lines — no `run_suite (\w+)` regex exists, and
  `clipboard_device` is ANDROID-only; the windows clipboard barrier is
  `family_serial` with `WIN_LEG`. `runner_list_scenes` never reads
  deploy-win (it serves run-sim/run-emulator, stages 2-3).
- check-steps sites with NO anti-vacuity floor: `launchers()` (an empty
  roster iterated zero times and returned green), `duplicate_legs`,
  sweep_guests' second SCENES read (a bare `if m:`), both of
  sweep_c_floor's patterns, and wired()'s deploy-win arm.
- check-staging's `words()` existed for exactly one line —
  deploy-win.sh:401's `${KAYA_WIN_DEPTH_SCENES:-…}` default-unwrap.
  Its runners loop matched ZERO deploy-win lines (both regexes were
  vacuous on that file, guarded by nothing).
- check-gates' keyed.sh detector never applied to deploy-win; its
  deploy-win facts were the verdict spelling, `flightrec_start
  windows`, and the wrapper-journal read through flightrec.sh's
  `flightrec_win_leg` body (N17 doctors the library, and nothing
  perturbed deploy-win's own bytes).
- check-build-id:86-87 demanded `build-id.sh" --verify` or
  `build-id.sh --verify` as substrings — no negative, no floor, and a
  python argv spelling matched neither. The one clause that would have
  drifted silently.
- check-appearance N10 and check-assets N4 would have died LOUDLY
  (doctor want=1 against 0 matches — SELF-TEST BROKEN), the correct
  failure mode; check-stubs and check-app-identity would have gone
  silently vacuous.

## The roster rider (plan §5)

Extracted mechanically from the shell body and compared EQUAL to the
module, before the body was replaced and again afterward against the
git-materialized c9f18a7 copy: SCENES (41), DEPTH_SCENES default (3,
env override honoured and cleared), GO_ONLY (1), PY_ONLY (2), 201 legs
in submission order, 32 blocks (the drain structure), and the
arg-arm/roster bijection (every leg runnable alone — now true by
construction, since the roster IS the argument grammar).

## What each gate reads now

- check-steps: imports lanes.win — wired() checks roster membership,
  sweep_guests takes the module's SCENES, duplicate_legs/launchers walk
  `legs()`, and the serial barriers are structural (`a leg's block is
  [leg]`). menu_serial grew the `undo_` arm the old body's comment had
  recorded as missing, and launchers() now covers the milestone2 bare
  five the `<scene>_<lang>` regex never could. The deleted-leg red was
  watched live: the nav family line removed from the module reddened
  check-steps with `scene "nav" has no leg in the win lane module`,
  then the module was restored from a saved copy under shasum -c.
- check-staging: imports the module per call through
  importlib (`load_win_lane`), so its shadow negatives perturb a COPY;
  N2 adds a ghost leg to the module, N6 deletes a .ps1 from
  deploy-win.py's ONE deploy_artifacts() list (the shell's two
  hand-written lists collapsed into it), and a new N7 plants a ghost
  .ps1 on disk that no list names.
- check-gates: the lane contract branches on runner language — a .py
  runner prints its verdict with `print(...)`, opens
  flightrec_lane.WinRecorder, and journals through a recorder class
  that binds `"windows"` in its constructor; N17 doctors
  tools/lib/flightrec_lane.py and demands the red.
- check-appearance: the windows LEGS entry reads `"canvasdark_rust"`
  out of the module; N10 perturbs the module text.
- check-assets: the STAGES entry reads tools/deploy-win.py (staging is
  behaviour, not a table); N4's `run_ssh` anchor carried over.
- check-build-id: the coverage clause reads non-comment LINES naming
  build-id and --verify together (both languages spell that), and got
  its first watched negative — the flag doctored away in memory must
  fail the clause, count printed.
- check-stubs and tools/lib/scene-features.py: their windows rows point
  at tools/lib/lanes/win.py; the `\b<scene>[-_]<lang>` regex reads the
  module's quoted leg names exactly as it read shell legs (verified
  non-vacuous against five sample scenes).
- check-app-identity: no edit — deploy-win.py names neither
  KAYA_ICON_FILE nor any icon path, so the walker's predicates stay
  inert on it, as they were on the shell body.

## The flightrec crossing

tools/lib/flightrec_lane.py carries the generic lane-side recorder
plus the windows half (LaneRecorder/WinRecorder); the `-- Windows --`
section left tools/lib/flightrec.sh with its only consumer. A pass is
still one O_APPEND spool write, no subprocess, no VM round trip; the
collect/pull/foreground failure path and the per-lane clock sync moved
verbatim in behaviour.

## Found while converting

- Five docs cited the shell body by line number
  (app-identity-plan:221, assets-plan:417, chrome/assets-survey:91,
  chrome/identity-winui:289 and :382); check-doc-refs' shrank-past
  clause caught all five on the first sweep and each was re-anchored
  to the python body.
- The leg-reachability audit and phase audit embedded in the shell
  body (its `python3 - "$0"` heredoc) died with it: both defect
  classes (a leg with no case arm, a phase reachable only from `all`)
  are unrepresentable when the roster and the phase table are the
  argument grammar.
- The first lane run died of a strict decode: the guest's output
  files carry cmd.exe codepage bytes, and `subprocess.run(text=True)`
  killed the leg WAITER on byte 0x83 while the leg ran on. Every
  guest-origin capture now says `encoding="utf-8", errors="replace"`
  (docs/traps.md, "NOT UTF-8" — the lesson run-sim and run-emulator
  inherit before their tranches).

KEY: deploy-win conversion record, lanes module, roster rider, eight
parsers re-taught
