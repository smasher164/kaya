# Runner conversion — tranche three of the python-first ruling

Ruled 2026-08-31 (docs/deferred.md, the retire-the-shell entry): new
scripts are python first, and the runners convert as the third tranche,
deploy-win.py first. This moves the 2026-08-27 ruling's
runners-stay-shell boundary, which was recorded present-tense for
exactly this revisit. Tranches one (generators, 511a3da) and two
(keyed/build-id as importable data, 36d7213) are landed; this document
is the design the third needs before anyone types a line of it.

## 1. What a runner is, measured

10,076 lines across six files: deploy-win.py 2,255, run-emulator.py
2,810, run-sim.py 2,500, validate-mac.py 1,703, validate-all.py 317,
validate-linux.py 51 (plus gates.py 440, the sweep driver). Three
layers live in each:

- **LEG TABLES** — the roster of legs and their ORDER (201 `run_suite`
  lines in deploy-win alone, and the order is semantic: the serial
  families and drain barriers are measured contention fixes, not
  style), SCENES/DEPTH_SCENES, the launcher and artifact maps, the
  declared-off lists (*_DESKTOP_ONLY_SCENES, IOS_UNWIRED_SCENES).
- **ORCHESTRATION** — the slot pool, drains, per-leg
  verdict/log/secs files, ceilings, the flight recorder hook.
- **PLATFORM ACTS** — ssh/scp to the VM, simctl, adb, schtasks: thin
  subprocess calls, some necessarily delivered as in-guest payloads.

## 2. Why the tables are the prize

EIGHT gates parse deploy-win.py's TEXT today — check-appearance,
check-app-identity, check-assets, check-build-id, check-gates,
check-staging, check-stubs, check-steps — with regexes over shell
assignments and `run_suite` lines, each needing its own anti-vacuity
floor because a regex that matches nothing agrees with everything.
run-sim and run-emulator are parsed the same way (check-steps'
`runner_list_scenes` reads `VAR="..."` assignments). keyed-inputs'
2026-08-31 lesson is the warning written down: a census over text goes
progressively vacuous the moment the text's shape moves, and nothing
reds until someone trips over the crater.

So the conversion is NOT a translation of 10k lines of bash into
python. It is: the leg tables become one importable data module per
lane, the runner consumes it, and the eight parsers become imports of
the same tables — the gates and the runner reading ONE source of
truth, with the regex-and-floor machinery deleted rather than ported.

## 3. The schema (to ratify at build time, not here)

`tools/lib/lanes/<lane>.py` (win, mac, linux, ios, android), plain
data on the model of build-id.py's GATES:

- `SCENES`, `DEPTH_SCENES` — as today, lists.
- `LEGS` — an ORDERED list of entries: name, scene, language, the
  launcher/artifact it executes, its serial family (None for
  poolable), env overrides. Drain barriers appear as explicit entries,
  not as positions someone infers.
- `DECLARED_OFF` — the per-lane declarations with their reasons.
- The .cmd/.ps1 GUEST payloads stay files; the module names them.

A generator for the guest-side tools/guest/*.cmd family (the 188-file
generation problem, its own HOLD) becomes possible off the same
tables but is NOT this tranche.

## 4. Sequencing (depth then breadth)

1. **deploy-win**: extract its tables into the win module of the
   `tools/lib/lanes/<lane>.py` family and convert the runner body
   to python in the same slice (a half-shell
   runner reading python tables doubles the interfaces; the ruling's
   answer is one crossing). Re-teach the eight gates to import the
   module, EACH with its watched negatives re-proven red against the
   import path. Validate: leg-roster equality first (names, order,
   families extracted from the old body and the new module must be
   identical — the one byte-comparable artifact a nondeterministic
   lane offers), then repeated green windows lanes, then the matrix.
   LANDED 2026-08-31 exactly on this shape — rider EQUAL both sides
   of the crossing, gates 50/50, two green lanes, matrix ALL PASS
   1,390 legs (docs/measurements/deploy-win-conversion-2026-08-31.md
   and the ledger's retire-the-shell entry hold the record).
2. **run-sim**, then **run-emulator** — same shape, mobile-lane
   validation. run-sim LANDED 2026-08-31, the evening after stage 1:
   rider EQUAL (113 legs), gates 50/50 after a NINTH parser surfaced
   (tools/swift-typecheck.sh reads the swift roster — the shell gates
   parse runners too), two green lanes, matrix ALL PASS 1,390
   (docs/measurements/run-sim-conversion-2026-08-31.md).
   run-emulator LANDED the same night: rider EQUAL (123 legs WITH
   their pool/tablet/remount call kinds), a second rider held every
   scene's script payload byte-equal across the crossing, gates
   50/50, two green lanes, matrix ALL PASS 1,390
   (docs/measurements/run-emulator-conversion-2026-08-31.md). The
   emulator-state library stays shell by §6 — probe-env.sh still
   sources it, and the python runner bridges to it.
3. **validate-mac**, **validate-linux**, **validate-all** — the mac
   runner also carries the scene×language sweep tables check-steps
   reads. validate-mac LANDED 2026-09-01, the night after stages 2-3:
   rider EQUAL (the full 349-leg event stream with drains and panel
   modes, plus the script bytes for all 48 scenes), gates 50/50, lane
   green twice, matrix ALL PASS 1,390
   (docs/measurements/validate-mac-conversion-2026-09-01.md). The
   mac flightrec half crossed into MacRecorder and its selftest
   drives the real capture; swift-toolchain.sh stays shell by §6
   (ten consumers) behind a bridge. validate-linux and validate-all
   LANDED the same night: the docker wrapper carries no tables
   (run-suites.sh is an in-container payload, §6), the matrix
   driver's launch block and BUDGETS moved with every measured
   ceiling comment intact, check-gates' six matrix negatives
   re-spelled to the python pins, matrix ALL PASS 1,390
   (docs/measurements/validate-all-conversion-2026-09-01.md). The
   lane tier is fully python; gates.py remains, last by design.
4. **gates.py** last: its census/EXCLUDED table is decision logic and
   moves to data; the loop is a launcher and converts with it.
   LANDED 2026-09-01, closing the tranche: the shell wrapper's
   python heredoc became tools/gates.py — GATES/EXCLUDED/BUILD as
   importable module data under a variable-status main() (tranche
   two's build-id shape) — with ZERO consumer re-teach, because the
   consumers already read data (--list JSON, --fingerprint, the shim
   path). Riders on the same tree against the git-materialized old
   body: --fingerprint identical, --list and --selftest output
   byte-identical (docs/measurements/gates-conversion-2026-09-01.md).
   The tranche's closing census: 59 pinned shims, 40 real shell
   bodies remaining and every one in a §6 class — the in-container
   payload (run-suites.sh, 1,375 lines) and its leg wrappers, the
   in-toolchain probe/build launchers, the three shared libraries
   with shell consumers (swift-toolchain, flightrec's generic half,
   android-emulator-state), and the stated survivors
   (swift-typecheck, probe-env, the bench instruments,
   fetch-winappsdk).

Fix-forward per lane; a runner port is landed only on its own lane
green plus a full matrix, like any feature.

## 5. What the byte-comparison rider becomes

A lane run is nondeterministic, so the gate-tier rider (both streams
byte-identical) does not transfer. Its replacements, per runner:

- The ROSTER RIDER: legs, order, serial families, scene lists
  extracted from the old shell body and the new data module compare
  EQUAL, mechanically, before the old body is deleted.
- The VERDICT-SURFACE RIDER: per-leg verdict/log/secs file names and
  the lane's terminal verdict line are byte-stable — check-gates and
  the flight recorder read them.
- The census gates' negatives re-proven red against the import path
  (a leg deleted from the module must red check-steps exactly as a
  deleted `run_suite` line does today).
- N repeated green lane runs plus the matrix.

## 6. Out of scope, stated

In-container and in-toolchain payloads (docker, swiftc wrappers), the
guest-side .cmd schtasks stubs (the 2026-08-31 HOLD), and
tools/lib/*.sh helpers until their consumers convert — flightrec.sh,
swift-toolchain.sh and android-emulator-state.sh each cross WITH the
first runner that stops sourcing them.

KEY: runner conversion, leg tables, lanes module, deploy-win port,
roster rider
