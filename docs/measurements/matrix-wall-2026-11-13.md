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
| 20261113T134617Z | 1646df47 | 2028 | ALL PASS | (the three reds' fixes: docs/traps.md, a matrix launched with Docker down; the modem a cold boot left out of service; the textarea the first step reached before it loaded) |

On the second and third the android lane ran no leg, so the sweep started
at about 100 s beside four lanes (648 and 662 s against its 600 s ceiling),
and android-quiet read 34 s instead of about 100.

## Phases (seconds)

| phase | record | 1st | 2nd | 3rd | 4th (green) |
|---|---:|---:|---:|---:|---:|
| start (`gates.py --build`, launch to the lanes) | ~107 | seconds | ~13 | ~13 | ~10 |
| windows build | 245 | 6 | 4 | 6 | 201 |
| windows native-images (since the change, with the start health reading, beside the build) | 4 | 12 | 11 | 19 | 12 |
| windows deploy | 63 | 72 | 47 | 79 | 98 |
| windows package, desk-warm, go-warm, media-server, unit-tests | 40 | 37 | 40 | 50 | 39 |
| windows caption-centre (since the change, beside go-warm..unit-tests) | 25 | 27 | 27 | 31 | 34 |
| windows suites | 1448 | 1386 | 1429 | 1503 | 1492 |
| windows lane | 1846 | 1524 | 1542 | 1661 | 1854 |
| mac core-build+gates | 49 | 30 | 27 | 24 | 45 |
| linux core-build | 43 | not run | 69 | 45 | 36 |
| quiet tails (android-quiet + linux-quiet) | 98 + 61 | 101 + 0 | 34 + 65 | 34 + 63 | 98 + 66 |

The wall on the second and third is the start, the windows lane and the two
tails: 13 + 1542 + 34 + 65 and 13 + 1661 + 34 + 63.

The fourth, ALL PASS, is the first green run of the speedups: 2028 s against
the record's 2114, the same shape (about 10 + 1854 + 98 + 66). Its windows
build compiled the core once, but the core had changed (winui/mod.rs), so the
phase read 201 s under the matrix's load (59 s standalone the night before);
with the core unchanged since the lane's last build it reads 4-6 s and the
lane would have been about 1660 s. The other rows: mac 1031 (911 legs), linux
1251 (1523), ios 1608 (309), android 1118 (314), the sweep 540 with rung 1
skipped on the warm's key, android-quiet 98 (4), linux-quiet 66 (16).

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

## The quiet tails, 212b240a (charges: quiet-tail)

linux-quiet now starts once every lane but windows, and the sweep, have
exited, and android-quiet after it; content_fresh no longer recompiles the
core for build-script runs of configurations nobody builds (docs/traps.md,
the core recompiled for a configuration nobody built), and the JVM apk's
reuse no longer reads its own jniLibs.

| run | tree | wall | verdict | why red |
|---|---|---:|---|---|
| 20261113T174539Z | 212b240a | 1927 | red | the Windows VM was unreachable at launch (ssh connected and hung, its QEMU at about 590% CPU) and `utmctl stop` timed out (OSStatus -1712), so the lane died in vm_boot with 0 legs; linux media_formats-rust-x11's leg-end video ink self-test read "the video view snapshotted to nothing at 160x90: no frame yet" at a host load near 200 |

Rows: mac 1073, android 1177, windows 1390 (0 legs), linux 1463, ios 1550
(1405 net, over its 1350 ceiling at that load), the sweep 571 from about
1178 to about 1749, linux-quiet 50 (core-build 2 against 17 at 1646df47,
guest-builds 15, legs 23), android-quiet 112 (build-jvm 5 with the apk
reused, legs-isolated 67 against 57). The core was unchanged since 1646df47.
With windows dead at 1390 the tail order bought nothing on this run: the
saving it was made for needs a windows lane that outlasts the sweep, which
on a clean core (windows about 1660) it may not. The rebuild cuts took
linux-quiet from 66 s to 50; the sweep's own libkaya aged the derive once
(no record yet) and skipped it on its second build.

After the coordinator restarted the VM and UTM (killed the wedged QEMU,
relaunched UTM, `utmctl start`), the interactive session again had a second
800x600 display beside its 1280x800 one; `DisplaySwitch.exe /internal` as an
`/it` task left the 1280x800 one alone (docs/traps.md, UTM's graceful stop).

| run | tree | wall | verdict | why red |
|---|---|---:|---|---|
| 20261113T192036Z | 212b240a + 111960b9 | 2131 | red | linux media_delivery-rust-notsdemux-wayland: the harness step ceiling, 60 s inside `Expect(label#1, "hls_mpegts.m3u8")` at a container load of 5.9; windows taskspkg_rust and notifypkg_rust: the guest wrote no output before the timeout (an earlier draft of this row gave taskspkg a colour read that is in no log of the run; docs/traps.md, the packaged leg launched eight minutes late) |

Rows: mac 996, android 1027, linux 1247, ios 1402, the sweep 446 from
about 1027 to about 1473, linux-quiet 54 from about 1473 BESIDE the windows
lane (its 16 media_tracks legs green), windows 2016 (1962 net, over its 1900
ceiling; build 12 with the core unchanged), android-quiet 100 after windows.
The wall is the start, the windows lane and android-quiet (about 10 + 2016 +
100); the old order would have added linux-quiet's 54 s after them. The
media_formats-rust-x11 video-ink red of the first run passed here.

