# The windows and android lanes over their ceilings, 2026-10-16

The matrix at ee6b56b6 (the styling breadth) read windows 1809 s wall, 1771 s
net against 1650, and android 1159 s wall, 897 s net against 870. The matrix
wall was 2023 s against the ~27 min (1620 s) target. Nothing here changes a
ceiling or a set; it is the measurement and a proposal for the maintainer.

Sources: the three matrix logs (pinned = the matrix before the styling depth,
skin = ee6b56b6's first attempt, skin2 = this one), the lane logs under
target/validate-lanes/runs/, and the windows lane's flight-recorder journal
(~/.local/state/kaya/flightrec/runs/20261016T234627Z-009896/journal.jsonl),
whose leg records carry the time each leg ended. Block walls below are the
gap between one block's last leg ending and the next block's last.

## What sets the matrix wall

| path | seconds |
|---|---|
| windows, alone | 1809 |
| mac exit (1231) + the gate sweep (623) + android-quiet (77) | 1931, matrix 2023 with launch and joins |

The sweep starts when BOTH android and mac have exited (android's for load,
mac's because a gate's cargo build relinks the libkaya the mac guests load).
This matrix's mac lane spent 360 s of its 1231 waiting for an idle host (the
240 s panel budget and 120 s for the deferred takeover legs) because the
maintainer was at the machine. That wait was on the matrix's critical path,
not windows. On an idle host mac would have exited at ~871 s and the sweep
would have waited for android (1159), giving a critical path of
max(1809, 1159 + 623 + 77) = 1859 s.

## Windows

| | pinned | skin2 |
|---|---|---|
| legs | 473 | 503 |
| build + deploy | 8 + 39 | 144 + 141 |
| other one-time phases | 66 | 70 |
| suites | 1649 | 1436 |
| net | 1742 | 1771 |

The pinned matrix was ALREADY 92 s over the ceiling with a warm build. The
suites phase came down 213 s (not attributed here). What added time this run is the
cold build and deploy: the breadth changed the core and every binding, so
285 s against 47 s. The 30 new legs (cards, grounds, shapes, tracks, dock)
added about 80 s of leg time, which is 13 s of pool at six wide, plus the
six cards legs (below).

The suites phase by block, from the journal:

| part | blocks | legs | leg seconds | wall |
|---|---|---|---|---|
| first pool (capture group, first 228) | 1 | 228 | 1204 | ~330 |
| other pools | 16 | 181 | 1286 | 453 |
| alone | 94 | 94 | 505 | 645 |
| total | 111 | 503 | 2995 | 1428 (phase 1436) |

The pools run at about 3.6x on a six-wide pool whose VM has six vCPUs, and the
2026-10-09 measurement showed those pools CPU-bound on the VM (88-100% busy
standalone); in a matrix the host itself is at load 100-120 on 18 cores, so
more slots or more vCPUs would compete for the same cores.

The alone blocks, wall against leg seconds, largest first:

| family | legs | wall | leg s | reason on record (tools/lib/lanes/win.py) |
|---|---|---|---|---|
| dnd | 6 | 96 | 57 | real mouse; EXCLUSIVE |
| tasks | 2 | 61 | 50 | drag + notification + relaunch |
| numberfield | 6 | 54 | 42 | a neighbour's launch takes activation and the field commits (measured, five runs) |
| media_tracks | 6 | 50 | 46 | the maintainer's media-stall ruling, 2026-10-01 |
| timecode | 6 | 48 | 45 | numberfield's reason |
| numberfieldde | 6 | 47 | 44 | numberfield's reason |
| cards | 6 | 38 | 13 | `hover` moves the VM's real pointer; EXCLUSIVE |
| dndforeign, dndwitness | 2 | 41 | 36 | real mouse, second process |
| clipboard | 6 | 29 | 24 | system clipboard |
| chat | 1 | 24 | 24 | go-only |
| media_session | 6 | 18 | 15 | one system media session manager |
| filedialog | 6 | 18 | 15 | system dialog |
| the rest | 31 | 121 | 94 | each with its reason |

Every alone family still has a measured reason. Two things stand out:

1. The EXCLUSIVE legs cost 4-7 s each beyond their own seconds (cards 38 s
   wall for 13 s of legs, dnd 96 for 57, fullscreen 12 for 6): the pool join,
   `dismiss_toasts` over ssh and the token. That is about 90 s over 25 legs.
2. The number-field family (19 legs, 149 s wall) is alone for a measured
   cause in kind, a neighbour's launch activating its window. The 2026-10-09
   measurement adds that about 3 s of each leg's 7 is the harness's 400 ms
   answer silence on verbs the app does not answer.

## Android

| | pinned | skin | skin2 |
|---|---|---|---|
| legs | 258 | 274 | 273 |
| leg seconds | 2282 | 3868 | 3032 |
| token waits | 277 | 413 | 262 |
| net | 682 | 1168 | 897 |

The 258 legs both runs share went from 2282 to 2834 leg seconds (+24%) with
no change in kind: legs whose scene is two seconds (align-compose 2 -> 21,
layout-compose 2 -> 20, confirm-compose 3 -> 21, select-go 2 -> 16) took ten
times as long, which is the host under the matrix (load 121 at android's
exit), as docs/measurements/android-ceiling-2026-10-09.md found: a matrix
roughly doubles android's leg time. The 16 new legs add 198 leg seconds, about
50 s across four phones. The queued phases are the leg seconds over four
phones plus the token waits inside them (1001 s queued, 262 of them waiting,
against 750 s of legs over four), so the pool is not idle; ALONE is
clock24-compose alone and EXCLUSIVE/QUIET are the three microphone legs, each
with its measured reason. There is no serial set left to pool.

## Proposal

Ceilings, where the growth is real legs and a cold build (re-measured, the
usual ~1.07x over the reading):

- windows 1650 -> 1900: 1771 net with a cold build and 503 legs; the warm
  matrix before it was already 1742.
- android 870 -> 960: 897 net with 273 legs, the per-leg growth being load.

Parallelism and order, which is what moves the matrix toward 27 min, in the
order of what each buys:

1. The gate sweep's mac wait (up to 360 s this matrix, whenever the maintainer
   is at the host, and mac's whole tail otherwise). The wait exists because a
   gate's cargo build relinks the libkaya the mac guests load. If the sweep
   builds in a target directory of its own, the sweep no longer waits for the
   mac lane at all and the critical path drops to
   max(windows, android + sweep + quiet): 1859 s this matrix rather than 2023.
   Needs a measurement of the sweep's own cold build in a separate target.
2. Windows EXCLUSIVE overhead (~90 s): `dismiss_toasts` only when a
   notification leg ran since the last dismissal, and the token taken once for
   a run of consecutive EXCLUSIVE legs rather than per leg. Both are a probe
   away from a number.
3. The number-field family (~149 s, 19 legs alone): the cause is a launch
   taking activation. A harness launch that shows the guest's window without
   activating it would remove the cause rather than the symptom; if it holds
   over five pooled runs as the original measurement did, the 19 legs pool and
   the lane loses ~120 s. It is a lane-rule change and the maintainer's.
4. Android: nothing serial to pool. Its exit gates the sweep for load
   (docs/measurements/gate-sweep-2026-09-07.md); with item 1 done android
   (1159) + sweep (623) + quiet (77) = 1859 is the next critical path, so the
   sweep's own 623 s (511 on the pinned matrix, 490 ceiling) is the next thing
   to measure.

Not proposed: a wider windows pool or more vCPUs, since in a matrix the host's
18 cores are already saturated and the VM's pools were measured CPU-bound.


RULED 2026-10-16 (the maintainer: "accept all"): give the gate sweep its own
cargo target directory so it stops waiting on the mac lane; trim the windows
exclusive-leg overhead; probe whether the windows number-field and timecode
guests can launch without taking activation so they pool (the rule change
follows the probe's measurement); then re-measure the ceilings as proposed,
windows 1650 -> 1900 and android 870 -> 960. Also ruled: a mac session leg
whose Now Playing stays held by another app is reported NOT RUN, as the
takeover legs are (docs/traps.md, "The browser that took Now Playing").


## The rulings carried out (2026-10-16), with what each measured

**The sweep in its own cargo target.** validate-all launches the sweep with
`CARGO_TARGET_DIR=target/gate-sweep` (tools/lib/host_lib.py's SWEEP_TARGET) once
Android exits, no longer waiting for the mac lane; gates.py refuses a matrix
sweep anywhere else, and the sweep and the mac lane each still refuse a verdict
when the lanes' libkaya moves under them. The separate target costs builds the
shared one got for free: cold, the lib took 25 s and check-targets 111 s
against 5.6 s; after a change to the core (`cargo clean -p kaya` in that
target), the lib took 6.7 s and the harness test binary that check-abort's
cargo test needs took 19.8 s on a quiet host, about 55-80 s under a matrix's
load. So validate-all also runs `nice -n 10 tools/gates.py --warm` (those two
builds) beside the lanes at t0 and joins it before the sweep, and the sweep
starts with them already done. The target holds 14 GB (7.2 GB of it the
examples `cargo test` builds).

**Estimated critical path, on this matrix's timings.** The sweep starts at
Android's exit (1159 s) instead of the mac lane's (1231 s), which saves 72 s
here; the saving is the mac lane's exit minus Android's whenever the mac lane is
later, which it is when the maintainer is at the host (this matrix's mac lane
waited 360 s on him and still exited only 72 s after Android), and nothing on an
idle host. The linux tail ruled the same day adds 43 s after the android tail,
so this matrix reads about 2023 -> 1994 s (-29 s), or -72 s without the tail.
Windows (1809 s) is no longer on the critical path, so its trim below does not
move the wall: Android plus the sweep is the path (1159 + 623 + 77 + 43). The
first matrix after this change pays the cold check-targets once (about +105 s).

**Windows exclusive overhead.** The toast dismissal is asked only when a
notification leg has started since the last one, or none has run yet
(lanes/win.py's toasts_may_be_up): of this matrix's 25 dismissals one found a
toast up. On the windows lane run alone (503 legs, ALL PASS, 19m31s) it was
asked 3 times and skipped 22, at 0.8 s each, so the trim is about 18 s alone and
perhaps 20-45 s under a matrix, not the ~90 s estimated above. The token is a
mkdir and costs milliseconds; holding it across a run of consecutive exclusive
legs was not done, because Android, now on the critical path, already waits for
it (262 s over 17 waits on this matrix). Alone, an exclusive leg cost 0.5 s
beyond its own seconds, the same as any one-leg block (24 and 70 legs), so the
4-7 s seen in the matrix is the host's load and the token waits on admits
(3.3 + 18.5 + 9.4 s, iOS's saves), not anything the exclusive funnel does.

**The number-field probe: a launch without activation does not make the 19 legs
poolable.** A temporary knob showed each WinUI guest's window with
`AppWindow.ShowWithActivation(false)` in place of `Window.Activate()` (the code
and the merged block are gone again). Pooled four wide: with activation, 16/19
passed (a commit mid-scene, `commits: 1` wanted `commits: 0`, and typed values
lost); without it, 17/19, 15/19 and 18/19, with the same two failures plus a new
one: in a window never activated, the posted keys of `type` did not land (the
field kept its initial value). The cause is not only the neighbour's
activation, so the rule stays as it is.

**Ceilings.** windows 1650 -> 1900 and android 870 -> 960 in validate-all's
BUDGETS. No gate holds the numbers.

**The linux quiet tail (ruled the same day).** media_tracks in eight languages
on both protocols (16 legs) runs in a `linux-quiet` row after the android tail.
Measuring the tail found that the linux lane's 67-90 s `core-build` was the
container downloading the crates.io index and every dependency again on every
run (docs/traps.md); with the registry mounted the build took 1.45 s, the tail
43 s (core 2, guests 11, legs 24, 16/16), and the main linux lane loses about
60 s.

