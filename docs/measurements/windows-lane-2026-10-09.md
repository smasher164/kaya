# The windows lane's wall, 2026-10-09

The windows lane read 1581 s net against its 1650 s ceiling on the expander
matrix (20261009T203533Z), from 1242-1466 s a few days before. Every lane run
below is `tools/deploy-win.py akhil@192.168.64.2 all`, whole, on a VM no other
lane was using.

## Where the time went (the matrices' own logs)

Twelve matrices, 2026-10-07 to 2026-10-09 (target/validate-lanes/runs/*/windows.log):

| phase | seconds |
|---|---|
| build | 5-8, or 81-113 when the core changed |
| deploy | 23-32, or 57-75 with a rebuilt core |
| unit-tests | 6-8, or 43-109 when the core changed: the test binary's host compile, serial |
| go-warm, package, desk-warm, media-server | 20-30 together |
| caption-centre | 21-30 |
| suites | 1201-1450 (1398 on the expander matrix) |

The legs went from 425 to 455 and their summed seconds from 2041-2065 to
2737-2880 over the same days. The alone legs' sum held at 482-560 s; the
pooled legs' sum moved with the host (1542-2350 s), since the VM's pools are
CPU-bound: during the first pool its six cores read 88-100% busy with a run
queue of 18-37, standalone. Per leg, the seconds over the harness's own were
1.3-2.1 for C#, Java, Python, JS and Rust standalone and 2.8 for Go, and
3.7-9.2 for Go in the matrices.

One standalone run of the tree as it was (before1 below), by block, from the
flight recorder's journal:

| part | seconds |
|---|---|
| first pool (186 legs) | 100 |
| media pool | 72 |
| media_delivery, two wide | 84 |
| media_tracks, alone | 34 |
| capture and capture_denied, twelve alone | 100 |
| media_session, alone | 10 |
| second pool (78 legs) | 45 |
| the rest, tasks to clipboard, mostly alone | 466 |

## Changes

| change | seconds | evidence |
|---|---|---|
| Go legs run a copy of go-warm's one build instead of linking the guest each (docs/traps.md, the Windows Go legs linked the guest once each) | Go legs' seconds 383 -> 290 standalone, 1137 -> 822 under load; per Go leg over the harness 12.3 -> 7.7 s under load | before1/after2, loadbefore/loadafter |
| capture legs pool in the first block, one at a time among themselves (SERIAL_GROUPS), and a grouped leg claims a slot ahead of the pool | the 100 s serial capture run (115 s under load) gone; the first block 100 -> 103-111 s standalone, 342 -> 369 under load | before1, after2, after3, loadbefore/loadafter; the first try without slot priority read 133 s (docs/traps.md) |
| capture devices start once and stop after the last capture block, not around each leg | inside the row above (2-4 s a leg before) | journals |
| the unit test binary compiles on the host while the VM is staged and warmed | unit-tests phase 54 -> 6 s under load with the core changed; 5 s on after3, core changed | loadbefore, after3 |
| WinUI `press return` on an entry or submitting textarea no longer waits 2 s for a newline nobody inserts (docs/traps.md) | submit block 17 -> 7 s and chat_go 34 -> 22 standalone; 26 -> 15 and 38 -> 33 under load; 29 false sentences a lane -> 0 | before1/after3, loadbefore/loadafter |
| media_timeout_rust submitted first in the media pool | media pool 71 -> 61 s; its 37 s no longer ends the block | after3/final |

Lane runs (seconds):

| run | tree | load | suites | lane | result |
|---|---|---|---|---|---|
| before1 | HEAD d1f4944f | none | 903 | 979 | ALL PASS |
| after1 | Go, unit tests, capture group | none | 843 | 933 | media_feed_js red, see below |
| after2 | + slot priority | none | 804 | 895 | ALL PASS |
| after3 | + Return skip (core rebuilt) | none | 787 | 938 (build 51) | ALL PASS |
| loadbefore | HEAD | 24 spinners, host load 50-130 | 1623 | 2082 (build 89, unit-tests 54) | ALL PASS |
| loadafter | after3 | 24 spinners, host load 50-120 | 1490 | 1683 (core unchanged) | ALL PASS |
| final | everything above (core rebuilt) | none | 777 | 922 (build 51) | ALL PASS |

Under load the saving is 133 s of suites, plus the unit-test compile on a
matrix where the core changed (43-109 s on the matrices above). The spinners
were stopped after each loaded run and the process list read back empty.

## Measured and not changed

- Defender is not the cost. A 60 s `New-MpPerformanceRecording` inside the
  first pool totalled about 4.5 s of scan time, most of it Task Scheduler's
  task files and AMSI over the waiter's script.
- The waiter, tools/guest/wait-exit.ps1: a PowerShell start costs 300-360 ms
  of CPU on the VM and its 150 ms poll about 40 ms of CPU a second, about a
  quarter of a core across a pool. Replacing its Test-Path and Select-String
  with one .NET read made no difference (688 against 750 ms of CPU over 10 s),
  so it was put back. A compiled waiter is the remaining route.
- The pools are bound by the VM's six cores, not by the pool's width: under
  load the first block's legs summed 2107 s in 369 s, six wide. A wider pool
  needs more vCPUs, a UTM setting left to the maintainer.
- The serial tail is scene time, not launch cost: an alone leg's overhead
  is under a second (commands_rust to commands_python, 0.74 s apart). Its
  largest parts are the number field and timecode legs (19 alone, about 140 s,
  each 7 s of scene: a neighbour's launch takes the window's activation and
  the field commits, docs/traps.md, the WinUI keystrokes posted to the input
  site), the drags (about 75 s with the witnesses), chat_go and the
  media_delivery/media_tracks rulings.
- media_session's six alone legs (10 s standalone) could join the camera
  group's shape, but they play media and the adaptive pipeline's losses under
  load are a ruling's subject (docs/media-plan.md §7c).
- Every action verb that the app does not answer ends on the harness's 400 ms
  answer silence; the number field legs spend about 3 s of their 7 there.

## Sighted once, not reproduced

after1's media_feed_js read `r9 in` where `r9 whole` was wanted after
`scroll_end`, in the media pool this work did not change; the next four runs
were green. Its bundle's verb trace carries one record and does not say why
the last row stopped short of whole
(the flight recorder's run 20261010T034955Z-094674, bundle windows-media_feed_js).
