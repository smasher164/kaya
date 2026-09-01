# Runner conversion — tranche three of the python-first ruling

Ruled 2026-08-31 (docs/deferred.md, the retire-the-shell entry): new
scripts are python first, and the runners convert as the third tranche,
deploy-win.sh first. This moves the 2026-08-27 ruling's
runners-stay-shell boundary, which was recorded present-tense for
exactly this revisit. Tranches one (generators, 511a3da) and two
(keyed/build-id as importable data, 36d7213) are landed; this document
is the design the third needs before anyone types a line of it.

## 1. What a runner is, measured

10,076 lines across six files: deploy-win.sh 2,255, run-emulator.sh
2,810, run-sim.sh 2,500, validate-mac.sh 1,703, validate-all.sh 317,
validate-linux.sh 51 (plus gates.sh 440, the sweep driver). Three
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

EIGHT gates parse deploy-win.sh's TEXT today — check-appearance,
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
   reads.
4. **gates.sh** last: its census/EXCLUDED table is decision logic and
   moves to data; the loop is a launcher and converts with it.

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
