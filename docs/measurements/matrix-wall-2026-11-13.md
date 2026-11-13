# The full matrix's wall, 2026-11-13

Three changes against the record matrix of b2fe5c4b (2114 s, ALL PASS,
20261113T023353Z), each with its entry in docs/traps.md:

- the windows release build compiles the core once (serde_core's `result`
  named in kaya's manifest; deploy-win refuses a second lib compile);
- rung 1 runs on the sweep's warm beside the lanes, not at validate-all's
  start;
- the windows lane's native-image phase runs beside the cross build, and its
  caption-centre probe beside go-warm, the media server and the guest's unit
  tests.

## Matrices (plain `tools/validate-all.py`, idle host, AC power)

| run | tree | wall | verdict | why red |
|---|---|---:|---|---|
| 20261113T093436Z | 49a284d0 | 1637 | red | Docker was not running: linux and linux-quiet 0 legs |
| 20261113T100314Z | 49a284d0 + ab9a8c51's sentence | 1652 | red | Docker Desktop's window took the foreground (mac chat-go-swiftui); one phone's modem out of service (android preflight); windows richdocax_rust's first select_text before the RichEditBox loaded |
| 20261113T103246Z | ab9a8c51 | 1770 | red | the same phone's modem out of service (android preflight, 0 legs) |

On the second and third the android lane ran no leg, so the sweep started
at about 100 s beside four lanes (648 and 662 s against its 600 s ceiling),
and android-quiet read 34 s instead of about 100.

## Phases (seconds)

| phase | record | 1st | 2nd | 3rd |
|---|---:|---:|---:|---:|
| start (`gates.py --build`, launch to the lanes) | ~107 | seconds | ~13 | ~13 |
| windows build | 245 | 6 | 4 | 6 |
| windows native-images (since the change, with the start health reading, beside the build) | 4 | 12 | 11 | 19 |
| windows deploy | 63 | 72 | 47 | 79 |
| windows package, desk-warm, go-warm, media-server, unit-tests | 40 | 37 | 40 | 50 |
| windows caption-centre (since the change, beside go-warm..unit-tests) | 25 | 27 | 27 | 31 |
| windows suites | 1448 | 1386 | 1429 | 1503 |
| windows lane | 1846 | 1524 | 1542 | 1661 |
| mac core-build+gates | 49 | 30 | 27 | 24 |
| linux core-build | 43 | not run | 69 | 45 |
| quiet tails (android-quiet + linux-quiet) | 98 + 61 | 101 + 0 | 34 + 65 | 34 + 63 |

The wall on the second and third is the start, the windows lane and the two
tails: 13 + 1542 + 34 + 65 and 13 + 1661 + 34 + 63.

## What each change bought

- The windows build: 245 s to 4-6 s with the core unchanged since the lane's
  last build; with the core changed, one compile (37 s for the lib and 24 s
  relinking the examples standalone, 59 s for the phase) where the record
  paid two (1m55s and 1m54s under the matrix). The second invocation
  compiled nothing on all three matrices.
- The start: about 107 s to about 13 s, nix develop's entry included. The
  warm's rung 1 passed on all three and the sweep skipped its own run on the
  key it handed on.
- The windows setup: caption-centre's 27-31 s now overlaps go-warm, the
  capture check, the media server and the unit tests (about 15 s of them).
  The native-image phase now carries the start health reading and, beside a
  4-6 s build, its join still lands in the deploy phase; it is hidden only
  when the core changed and the build is the longer of the two. The deploy
  phase itself read 47-79 s across the three, which is larger than either
  overlap.

## The revert's premise (docs/traps.md, the sweep's second unit suite)

With rung 1 gone from the start, the lanes' target/debug holds only the lib
graph when the mac lane builds `--lib --example ...`. On the first matrix the
mac lane's `Compiling kaya` was the examples alone: its lib-kaya fingerprint
and libkaya.dylib were both last written before the launch. Its
core-build+gates read 30, 27 and 24 s against 49 on the record and 439 on the
2026-10-06 matrices the revert was about. The linux lane compiled kaya once in
its container (the core had changed since its last run), and the windows
build's second invocation compiled nothing.
