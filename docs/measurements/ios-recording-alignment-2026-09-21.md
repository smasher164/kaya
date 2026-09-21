# iOS recording: where a step's still lands on the film

Baseline: a472f78a. The ledger's INVESTIGATE entry of 2026-09-20 said the
step-named stills lead their stated scene state: the frame named for the first
delete alert showed the launch screen, and the frame named for the final eject
alert showed the third delete alert. Its run (96498-1789957517) had been
overwritten by a later recording run (6592-1789971902, 06:25Z) before this
measurement; that later run was archived first, under
`target/session-notes/ios-recording-archive-2026-09-21/` (built), and is the
run measured here. Nothing was recorded anew before the measurement.

## The fiducials against the anchors

Each film's dark edge defines its anchor (`anchor = t_mark - dark edge`), so
the light edge is the one independent check the scheme carries. Predicted
light edge (`l_mark - anchor`) against the film's own, per slot:

| Film | Dark edge | Light edge filmed | Light edge predicted | Disagreement |
| --- | ---: | ---: | ---: | ---: |
| suite-0 | 5.135 s | 8.167 s | 8.220 s | 53 ms |
| suite-1 | 6.238 s | 9.125 s | 9.254 s | 129 ms |
| suite-2 | 7.280 s | 10.175 s | 10.257 s | 82 ms |

The marks are stamped by a 200 ms screenshot poll after the flip is visible,
so each mark is late by up to a poll and the two marks' lateness differs by
that much. Film durations equal the wall span between anchor and stop to
within a second over 200 s, so recordVideo's clock does not drift.

## The leg: confirm-swiftui on slot 2

Epoch 1789971967995, anchor-2 1789971902799, so the leg's transcript starts at
film 65.196 s. Every frame of suite-2.mov between 60 and 80 s was listed with
its average luma (263 frames). The events, transcript offset against the film:

| Event | Transcript | Predicted film | Filmed | Pixels lag |
| --- | ---: | ---: | ---: | ---: |
| launch screen goes dark, app draws | scene ready +69 ms | 65.265 s | 65.435 s | 170 ms |
| first alert dims the screen | expect_alert +186 ms | 65.382 s | 65.660 s | 278 ms |
| alert dismissed, undimmed frame | expect label +9458 ms | 74.654 s | 74.920 s | 266 ms |
| same | +9981 ms | 75.177 s | 75.453 s | 276 ms |
| same | +10477 ms | 75.673 s | 75.953 s | 280 ms |
| same | +10964 ms | 76.160 s | 76.437 s | 277 ms |
| same | +11451 ms | 76.647 s | 76.920 s | 273 ms |

The lag is a constant 266 to 280 ms across the leg, with no drift. Part of it
is the anchor's own lateness (up to a poll, measured 53 to 129 ms above); the
rest is render, composition and capture. The extraction sampled expects with
no bias and actions 300 ms late, so every expect's still was the covering frame
BEFORE its state: at 65.382 s the film is still the launch screen, which is the
ledger's first observation, and at 75.742 s the third delete alert is still up,
which is its second. Both reproduced from this run's own stills before any
change.

## Correction

One measured lag for every step, expects included: `KAYA_EXTRACT_LAG_MS`,
which tools/ios/run-sim.py sets to 300 for its extraction (`REC_LAG_MS`). The
value sits just past the measured spread on purpose: a dismissed alert is on
film for only about 90 ms before the next one is presented (74.920 to 75.013 s),
so a bias inside the spread lands three of five label stills one frame early,
measured at 275 ms; at 300 every still lands inside its window. Re-extracted
from the archived film and viewed: the first alert's still shows the delete
alert, the "deleted" and "kept" stills show those labels with no alert, and
the eject alert's still shows the eject alert over "kept". On the fresh run's
films the same four stills carry their named state too; a label expect that the
scene follows with a click in the same millisecond shows its label under the
next alert's first frame, since both changes reach the film together — the
scene's own timing, not the extraction's.

The extractor's own self-test runs the same synthesized video under the lag
and demands a different answer from the split's (rggb against rrgb), so an
ignored lag is red. The mac and windows lanes still extract under the old split
because their lags are unmeasured; the lag is per lane by construction.

## The guard

tools/ios/run-sim.py checks every film's anchor against the second fiducial
before any still is cut: the light edge the anchor predicts must land within
400 ms of the film's own (`REC_FIDUCIAL_TOL_MS`, from the 53 to 129 ms measured
here plus a poll), and a wider disagreement refuses the extraction naming both
numbers. The check is watched refusing a 401 ms disagreement and admitting an
82 ms one on every recording start, beside the extractor's self-test. What no
guard holds yet is the lag itself per run: a per-leg probe of the launch edge
against the transcript's scene-ready line would measure it on every recording
and is the natural next instrument if the 300 ms value ever misfits.

## Validation

harness-extract self-test, check-shell, check-python, check-ledger and
check-doc-refs passed; the archived leg re-extracted and viewed as above; a fresh
iOS recording run passed all 139 legs with the three anchors 71, 68 and 53 ms
from their second fiducials and every recorded leg's stills extracted; the full
matrix passed Mac 477, Linux 777, Windows 283, iOS 139 and Android 148 legs
and 61 gates in 1008 seconds with every ceiling held.
