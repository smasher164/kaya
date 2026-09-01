# The run-sim port — stage two's record (2026-08-31)

Tranche three, stage two of docs/runner-conversion-plan.md, the
evening after stage one (deploy-win, bbe4daf): the same shape, and
this file records only what stage 2 measured beyond stage 1's map
(docs/measurements/deploy-win-conversion-2026-08-31.md holds the
method).

The iOS runner followed the deploy-win shape: tables in
tools/lib/lanes/ios.py — four suite rosters (SWIFT_ENTRIES with the
`scene:guest` pairs, GO_SCENES, PYTHON_SCENES, RUST_SCENES), the
declared-off lists, PAD_EXTRAS and the per-leg MODS (cuts, drops,
keeps, extras) — body tools/ios/run-sim.py, shim pinned, IosRecorder
joining flightrec_lane.py. The rider compared EQUAL on every axis (38
swift entries, 36 go scenes, 2 python, 31 rust + 3 pad legs = 113 legs
in queue order) before and after the crossing.

What stage 2 measured beyond stage 1's map:

- A NINTH PARSER the enumeration missed: tools/swift-typecheck.sh —
  the gate tier's one deliberate shell survivor — reads IOS_MIN and
  IOS_SWIFT_SCENES out of run-sim.sh to know which guests reach a
  phone. Its own floor REFUSED A VERDICT loudly on the first sweep
  ("cannot read IOS_MIN/IOS_SWIFT_SCENES … REFUSING A VERDICT"), the
  correct failure mode, and it imports the lane module for the roster
  now (IOS_MIN stays a text read of the python body). The lesson for
  stages 3-4: sweep the SHELL gates for runner reads too, not only the
  python bodies.
- expect_app_icon caught a real conversion slip on the first lane run:
  the rust suite's identity bundle lost its `identity` make_bundle
  argument in translation (the swift and go loops carried it), the
  bundle shipped without CFBundleIcons, and the leg went red naming
  exactly that — the assertion's documented can't-pass-vacuously
  property doing its job. 112/113 on run 1; 113/113 twice after the
  one-line fix.
- check-python's population extended to tools/**/*.py via the
  prelude's pruned walk, with a second byte-pinned header variant for
  depth-2 runners (`parent.parent / "lib"`) — run-sim.py joins the 11
  rules, ruff and the shim pin (55 bodies, 54 shims).
- check-steps' clipboard_ios/picker_ios walls — 26 watched negatives
  over run-sim text — were re-spelled to the python body and the
  module (the pad-membership and guest-list negatives doctor
  lanes/ios.py through a throwaway import), all counts printed, all
  reds demanded. scene-features and check-stubs now IMPORT lanes/
  rows through a wired_scenes() floor, closing the two readers the
  enumeration flagged as silently-vacuous-on-a-shim.
- 18 doc line-anchors into run-sim.sh re-anchored (the module for
  scene-list citations, the python body for behaviour).
- The deleted-scene red watched live: the nav family removed from
  lanes/ios.py reddened check-steps with `scene "nav" has no leg in
  the ios lane module`, restored under shasum -c.

Validated: gates 50/50 (after the ninth parser's re-teach), the ios
lane green twice (113/113 both runs), matrix ALL PASS 1,390 legs in
631s with ios at 460s.

KEY: run-sim conversion record, ios lane module, ninth parser
