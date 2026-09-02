# The JS/TS binding's first day — 2026-09-01

The ninth binding, built from docs/deferred.md's ninth-binding entry
(every ruling there) to a green mac lane in one session. docs/js-plan.md
is the mechanics; this is what was measured on the way.

## The addon loads without a build of its own

`process.dlopen` on target/debug/libkaya.dylib from node 24.19.0: all
fifteen floor calls answered on the first load (specHash, capabilities,
run, submit, blobRegister, occurrenceBlob, the six asset calls,
openPicked, startPump, exit); the spec hash read back as the generated
wire.ts constant (0x2d485dd5237b14c3 at the time); a string handed to
submit was refused with "submit takes a Uint8Array"; the asset why-not
sentence came through byte for byte. No node header, no node-gyp, no
new crate: Node's API is dlsym'd out of the host at registration.

The first two-thread run failed for one reason only: the ad-hoc launch
lacked KAYA_SWIFTUI_LIB, and the core's own sentence named the fix. With
it set the way tools/validate-mac.py sets it, the todos scene passed
its whole script on the first attempt — add, undo, redo, toggle, the
posted second transaction, the derived label — which is the pump, the
threadsafe handoff, the ambient sugar and the worker bootstrap all
proven at once.

## The ports

42 scene guests (41 scenes plus listdetail on the split guest) ported
line for line from guests/python by five parallel agents plus the four
reference ports; every leg green on the mac backend individually before
the lane ran. ONE binding defect surfaced: `row({ stackWhen })` put the
size class on the wire as an F64 (the one un-wrapped enum in a
tx_create_breakpoint call whose three setter operands were wrapped) —
the core refused it by name ("create_breakpoint's size class is
F64(1.0), wanted i64"), the fix was one `new I64(...)`, and adaptive
passed. No other port needed anything from the binding.

Three translations are not literal, each the JS spelling of the same
semantics: background's thread-and-event becomes a promise the app
thread's own event loop resolves; the three blocking-read scenes
(filedialog, save, clipboard) open in the handler and read through
node:fs on the returned fd, filedialog's parked-thread release gate
becoming a held answer delivered by app.post; stall blocks the worker
with Atomics.wait, which is a real block of the app thread.

## The negatives

bindings/js/kaya_app_checks.ts, 44 checks, all passing on the first
complete run: no signal read, the mirror-read guard in For and When
bodies, one id space across widgets and nodes, insertFresh minting and
absorption, the key rule read off the shipped bytes, every move, the
draft, a mid-handler abort restoring collection and signal mirrors and
shipping nothing with the next dispatch working and the spent key
staying spent, a break refused by name with the zone state reset, the
sum's for-of refused, the async-handler refusal naming app.post, sum
patches witnessing the constructor, the size-policy refusals, the undo
marker leading the batch, an empty a11y label passing through for the
root's wall, the shortcut canonicalizer's accept and reject tables, and
an OCC_UNDONE record packed by hand restoring entries, order and the
signal cache and firing onUndone.

## The censuses

Six gates gained the ninth column the same day: check-steps (the
guests/js row and the js legs in the mac roster), check-staging (js
legs' guest files), check-ambient-tx (the JS lint with its own two
self-tests and a 42-guest census), check-tx-liveness (requireAppThread
and the app.post sentence: 10 tiers), check-file-modes (wire.ts
generated, the three JS redeemers pass-through), check-design-generation
(node reads COMPAT, sdk 14.4.0, minos 13.5 — six hosts now, the split
still both-sided). check-gates counts 52 gates with js-typecheck and
js-app-checks in the list.

## The mac lane

The first run of the lane with `js` in LANGS was ALL PASS: 391 legs
(42 js), legs 275s against 248s for the 349-leg roster the day before
— 27s for the ninth column, the same per-leg cost as the python legs
beside them — with the 52-gate sweep green ahead of it. The js legs sat
in every group python sits in, including the three serial families
(filedialog in the icons panel mode, save, clipboard, undo), each in
its own drain bracket.

## The linux lane

node 24.19.0 pinned by sha256 into the docker image for both arches, a
js leg beside every python leg in tools/linux/run-suites.sh (40), the
npm offline link in the container's build phase. Two runs paid:

- Run 1: 77 of 80 js legs green on the first image. Both wayland
  ranges legs failed typing into each other's window — the js leg had
  been inserted INSIDE the python leg's bracket, and only clipboard's
  alone-rule was held by check-steps. Fixed with a drain and a
  check-steps clause holding undo and ranges alone on linux too (its
  self-test is the measured shape, a second language's leg sharing the
  first's bracket).
- Run 2: 681 legs green, ranges pair included; clipboard-js-wayland
  failed a second time, deterministically, and the harness's refusal
  carried only "SIGABRT". Capturing the writer's stderr into the
  sentence made it say what was wrong: wl-copy refuses to run with a
  closed standard descriptor. Measured from inside the container: node
  marks fds 0-2 close-on-exec (flags 02400001), python does not, and the
  seed writer inherited stdout. Fixed at the spawn site (all three
  descriptors explicit) and held by check-targets' new spawn census
  (docs/traps.md carries the entry). The x11 seed's xclip hung 60s for
  the same reason on the clipboard-only rerun.
- portfolio-python-wayland's fold flake fired on BOTH runs (sightings
  three and four of the WATCH), with no instrument in place; recorded
  on the ledger entry, not rerun for its own sake.
- Run 3, on the settled tree: ALL PASS, 683 legs, legs 235s
  (against 254s on run 2 — the two 60s clipboard hangs gone). The
  clipboard-js pair passed in 2s each on the clipboard-only rerun that
  proved the fix first. The fold flake did not fire on this run.

## Left open on the day

The linux lane is green with the JS legs; the windows lane carries no js legs (node on the VM, the .cmd launchers,
and the win32 picked-file redemption are docs/js-plan.md §6's open
items); tools/guest-floor.py has no .ts rules yet (the census agent's
finding), so the JS guests outside entry and milestone2 are unswept for
floor spellings.

## The first matrix (red, three causes, two fixed)

Launched at load 4.4; the lanes pushed the host to load 43. iOS: the
runner hung on a piped `simctl spawn … launchctl list` for the whole
1800s ceiling, 0 legs — a pipe held by a two-day-old launchd_sim, with
192 leaked clipboard holders on the host (docs/traps.md; both fixed in
tools/ios/run-sim.py: file capture, process-group kill). Linux:
a11yrows-js-x11 printed OK and died of a Bus error on the exit path —
node's teardown under the pump thread (docs/traps.md; fixed in node.rs
and runtime.ts, the stall scene's wedged worker still exiting through
the bounded wait). Mac: save-c, save-js and editor-go — the last three
save-panel legs — failed with `AXIsProcessTrusted=false` at 14:36–14:38
after eight save legs had passed under the same host, the known
macOS 26.6.2 panel-service gate (docs/traps.md) surfacing mid-lane for
the first time; not reproduced standalone (the mac lane had passed all
391 legs an hour earlier), so recorded as a sighting with its timing:
the iOS simulators were booting on the same desk in that window.
Android and windows passed.

## The iOS lane after the runner fix

Standalone, twice. Run 1 kept the pipe fix AND killed the seed holder
as a process group: 97 legs passed, then the first clipboard leg's seed
timed out and SpringBoard denied the 17 launches after it — the group
kill was measured wrong and reverted (docs/traps.md, the ledger's
clipctl entry). Run 2, pipe fix alone: ALL PASS, 113 legs, 24 holders
left behind as the known leak says.

## The second matrix (red, all environmental)

Load-gated at 5.5, then the host went to load 75 while the iOS lane
reseeded three simulators. Verdicts: windows PASS (201 legs), android
FAIL on the portfolio title WATCH alone (122 legs), mac FAIL with every
file-dialog leg reading `AXIsProcessTrusted=false` (371 green), linux
FAIL on one leg (682 green), iOS 0 legs because the LocalStorage
export probe would not install on any of the three simulators after
the forced shutdowns.

THE MAC CAUSE WAS THE ACCESSIBILITY TRUST, MEASURED BOTH WAYS.
`AXIsProcessTrusted()` read FALSE from the session's own shell at
15:40, with the process chain walked to its root: zsh ← the claude
session ← `claude --bg-pty-host` ← `claude daemon run` ← the
interactive claude ← zsh ← login ← Terminal.app. At 15:58, after the
maintainer opened the Accessibility pane and found every entry
enabled, the same shell read TRUE and a filedialog leg passed; nothing
in the chain or the tree had moved. What flipped it is NOT
established — the pane visit refreshing TCC's cache is the candidate,
the daemon host being attributed separately from Terminal was the
hypothesis the true reading argues against. The measured rule that
survives: read the trust from the lane's shell before a matrix
(tools/probe-env.sh's panel-trust line), because a false reading
fails every dialog leg identically and reads like a lane defect.

THE LINUX SIGHTING: table-js-wayland read ONE row of three for 15s
at the first `expect_rows` and then every sorted read after the header
click was right — the wayland surface-size premise the portfolio fold
WATCH names, on a table this time, js's leg only, python's beside it
green. First sighting of that shape; the fold entry carries the
instruction.

Three lanes exceeded their ceilings in that window (mac 621 against
560, linux 663 against 530, windows 667 against 520). The mac and
linux ceilings move in this commit for the roster's growth (42 and 80
legs), with the standalone deltas as the reason; windows carries no js
leg, its 667 was the same load-75 window, and its ceiling stays.

## The third matrix (trust restored)

mac PASS, 391 legs in 376s — every JS leg green under the matrix for
the first time, and under the raised ceiling with room. windows PASS
(201 legs). linux 682 of 683: table-js-wayland again, the same one-row
first read for 15s then every sorted read right — the second sighting
of that shape in two matrices, js's leg only, python's beside it green
both times, and the two guests are the same shape (one window body,
inserts inside it), so the difference is TIMING: node's start under
load lands the first transaction later against the compositor's
configure, which is the wayland surface-size premise the fold WATCH
names; it carries the sibling now. android 122 of 123: the portfolio
title WATCH, its third sighting today. iOS 0 legs: one simulator
(8F0680C5) kept an unhealthy LocalStorage export through the runner's
reseed, and device preparation is all-or-nothing, so the lane refused
every leg — a simulator-state fault, not the tree's; the same lane was
113 green standalone forty minutes earlier.

## The two wayland WATCHes, instrumented and read

Both instruments went into gtk.rs and the three non-mac lanes ran
concurrently (linux, iOS, android — the matrix's load without the
matrix). The two legs failed on cue, and their logs carried the premise.

THE FOLD (portfolio-python-wayland). The scene asks `resize_window
900x600`, expects the summary column unfolded, `resize_window 560x600`,
expects it folded, `resize_window 900x600`, expects it unfolded. The
window-metrics lines around the last request:

    KAYA_DIAG window_metrics default=900x600 allocated=560x600 mapped=true
    KAYA_DIAG window_metrics default=575x600 allocated=575x600 mapped=true

The toplevel's default size was set to 900 and the compositor's next
configure delivered 575 — the window's natural width — and GTK adopted
it as the new default. The request was lost to a configure already in
flight from the 560 step, and the fold derivation then read a 575-wide
surface, which is compact, which is folded: a CORRECT verdict over a
premise nothing held. The verb waited 1s for the width to cross the
600 boundary and then moved on in silence. Now it re-issues
`set_default_size` every 500ms until the width is on the wanted side
and refuses after 5s naming the width the surface holds; the re-issue
prints a KAYA_DIAG line.

THE TABLE (table-js-wayland). Serial runs of the four table legs
(python and js, both protocols) all showed one healthy chain: the
apply-time report `first=0 count=0 page=0.0 average=0.0 laid_out=false`,
then the window's metrics, then `first=0 count=8 page=199.0
average=28.0 laid_out=true` — with an invisible pass between them that
measured the first row (the average is the pitch it measured) and
derived count 0 from the extent it had read BEFORE measuring. The
failing leg's log had the first report, the metrics line, and then
nothing for 15s until the header click's own pass reported (0, 8)
over torn-down rows. The chain needed one more relayout signal after
the measuring pass, and under load it did not come. window_report now
re-reads the extent after it measures, so the pass that measures the
first row is the pass that realizes the page. Every pass prints its
inputs and whether it sent, the adjustment's changed signal prints its
values, and a deferred pass says so — a failing leg's log now shows
the whole chain.

THE RUN WITH BOTH FIXES: linux ALL PASS 683 legs (legs 290s), android
ALL PASS 123, iOS ALL PASS 113, all three concurrent, the host's
five-minute load peaking at 120 during the iOS boots. The android
title instrument stayed quiet. The matrix decides the two WATCHes.

## The fourth matrix (every lane and gate green; the iOS ceiling)

Launched at load 4.6 with the trust reading TRUE: mac PASS 391 legs in
364s, linux PASS 683 in 511s, windows PASS 201 in 469s, iOS PASS 113 in
551s, android PASS 123 in 223s, the gate sweep 52/52 in 393s; 619s wall,
1,511 legs, both wayland legs green. The one red was the iOS lane's
DURATION ANOMALY, 551s against a 540s ceiling set against the 74-leg
roster — the lane has been 113 legs since 2026-08-31 and its five
accepted matrices measured 452-491s under it. Investigated before any
number moved: the windows lane, whose roster has not changed, was 7-20%
over its own band on the same host; the LocalStorage admission hit the
slow-flow re-probe on two of three phones, which is backgrounded under
the swift build and reaches the critical path only if it outlasts it,
and nothing timed that. So the runner prints the admission's per-device
time and the join's wait now, and the ceiling is re-set to 600 against
the 113-leg band (1.22x its top) with the whole reasoning beside the
number.

## The fifth matrix (three findings, all measured, all fixed)

Launched at load 3.8 on the tree with the iOS ceiling re-set: linux PASS
683 in 501s, windows PASS 201 in 462s, android PASS 123 in 225s, the
sweep 52/52 in 414s; mac PASS 391 legs but 791s against 620; iOS FAIL,
112 of 113, `adaptive-swiftui` reading `row@narrow axis "horizontal",
wanted "vertical"` in 565s.

THE MAC ANOMALY WAS A DUPLICATE SWEEP. The flight recorder's per-leg
times summed to 285s against 495s the matrix before, no leg grew, and
the lane's `core-build+gates` phase read 535s: the lane had run all 52
gates itself because the matrix's skip token — a fingerprint whose
keyed keys carry the artifacts' real bytes — was taken at t0 over the
previous build's libkaya, and the lane's own fresh build of the edited
tree no longer matched it. validate-all builds before it takes the
token now (docs/traps.md).

THE iOS ADMISSION REACHED THE CRITICAL PATH, timed by the instruments
the fourth matrix asked for: two phones' LocalStorage admission took
143s and 149s (the slow-flow re-probe path) against 37s on the third,
and the join waited 99s past the builds. The probe's failed drive was
followed by the full 60s result wait it could not satisfy; that wait is
a 5s grace now, and the drive's last words are printed on the slow path
so the next run says why simdrive failed.

THE ADAPTIVE LEG WAS A DROPPED REPORT, a second cause under the
2026-08-29 entry's sentence: `metrics window=0 375x734 class=1` was the
right premise, and the core had not taken it — on iOS the app's window
lays out before the pump's first call builds the presentation scene,
and `with_window_scene` answered a report made before that with
nothing. Every report is latched and seeds the next scene now
(capi.rs); the unit test was watched failing with the seed removed.

## The sixth matrix (two more premises, both measured, both fixed)

The token fix held: mac PASS 391 in 347s with no second sweep; windows
PASS 201 in 498s; android PASS 123 in 250s; the sweep 52/52 in 395s; the
adaptive leg PASSED with the latch; the admission join waited 28s
(65s, 74s, 88s per phone; the slow phone's drive said the save dialog
was still up after six presses of Save across 47s). Two reds:

- linux 681 of 683, listdetail-js-x11 and select-js-x11: `KAYA_SELFTEST:
  OK` then Bus error and Segmentation fault inside the second — the
  Node exit race's second sighting, on the ORDERLY path: the addon's
  exit was libc `exit`, which runs Node's static destructors under the
  worker still executing the app. harness_exit is `_exit` on unix now
  and the addon exits through it (docs/traps.md, the Node exit entry).
- iOS 112 of 113, varied-python: `scroll_to_row column@varied` at +3ms
  refused "not a windowed tier" and the same verb scrolled the same
  table at +30844ms — the synthesized window registers at its first
  placement, and the harness got there first under load. The verb
  waits for the registration, bounded at 5s (docs/traps.md).

## The seventh matrix: ALL PASS

Launched at load 4.8: mac PASS 391 in 344s, linux PASS 683 in 509s,
windows PASS 201 in 480s, iOS PASS 113 in 506s, android PASS 123 in
225s, the sweep 52/52 in 388s; 623s wall, 1,511 legs, no anomaly on
any lane. Every finding of the day's five matrices is green under it:
the two wayland legs, the adaptive leg with the latch, the two x11 JS
legs through the hard exit, the varied leg through the waiting verb,
the mac lane without its second sweep, the iOS lane under its re-set
ceiling with the admission timed.

## The clipboard seed holder retired

The 192-process leak (and the 24 per lane run since) ends in
tools/ios/clipctl: the hold polls a release file the runner names and
exits `H released` when it appears, or `H expired` after 600s. By hand
on a booted phone: the census pattern (`hold <run dir>/release-`) saw
the four processes of a live holder; the file was touched; half a
second later it saw none and the seed log ended `H released`. The go
suite then ran clipboard-go green in 77s with `clipboard seed holders
outliving this run: 0 (late at release: 0)` at its verdict and zero
holders on the host afterwards. The verdict is gated on that census.
Under the eighth matrix (ALL PASS, five lanes and 52 gates, 1,511 legs
in 647s): the iOS lane's verdict is gated on the census, so its PASS
over five clipboard legs is zero survivors and zero late by
construction, and the host census afterwards read zero holders — the
first matrix since the leak was found to leave none behind.

## The ninth matrix (the sugar rulings' tree)

Four lanes green with the four JS-only shapes in: linux PASS 683 in
482s, windows PASS 201 in 460s, iOS PASS 113 in 578s, android PASS 123
in 240s, the sweep 52/52 in 444s, zero clipboard holders left. mac
FAIL, 390 of 391: portfolio-python-swiftui, a PYTHON leg, read `title
"portfolio", wanted "Transactions"` on a click 130ms after a pop, with
the later `back` finding the entry that had been pushed late — the
android title WATCH's shape on the mac, second sighting of that leg's
entry. The SwiftUI harness now carries the android instrument's twin
(click-after-pop gap, push-after-pop gap, the model's view on the
refusal). The standalone mac lane on the same tree minutes earlier was
ALL PASS, 391 legs, 41 of them JS, with the 52-gate sweep green ahead
of it.
The tenth matrix, with the SwiftUI instrument in: ALL PASS on all five
lanes and 52 gates, 1,511 legs in 711s (mac 411s, linux 501s, windows
496s, iOS 586s, android 237s), zero holders left, the portfolio leg
green and its instrument quiet.

