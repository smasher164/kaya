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

THE MAC CAUSE IS THIS SESSION'S HOST. `AXIsProcessTrusted()` read
FALSE from the session's own shell afterwards, and its process chain
is `claude --bg-pty-host` — Claude Code's background pty daemon, not
the terminal that holds the Accessibility grant (docs/traps.md, the
26.6.2 entry: TCC attributes lane guests to the app hosting the lane
shells). The standalone mac lane had passed every dialog leg earlier
in the same session, so the attribution changed during it; the
measurement is the false reading, and the fix is the grant on the
daemon host or running the matrix from the terminal.

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
