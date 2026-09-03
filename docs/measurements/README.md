# Measurements

Recorded performance numbers, and the recipe that produces them.

The point of this directory is that the next performance question gets
answered by re-running yesterday's measurement, not by inventing a new
one. A number with no recorded method beside it cannot be compared to
anything.

## What is here

| File | What it is |
|---|---|
| `choke-macos-2026-08-24.txt` | The five-platform choke investigation that sized the row-windowing work. One file per platform, each recording its own recipe, its numbers, and its own caveats. |
| `choke-linux-2026-08-24.txt` | " |
| `choke-windows-2026-08-24.txt` | " |
| `choke-android-2026-08-24.txt` | " |
| `choke-ios-2026-08-24.txt` | " |
| `choke-ios-guest-2026-08-24.swift` | The iOS choke guest's source, kept because that rig's guest is Swift and not reconstructible from the report alone. |
| `tables-guest-2026-08-26.txt` | The first run of the checked-in recipe below. |
| `canvas-cross-isa-2026-08-26.txt` | Whether one frozen `expect_drawing_hash` can stand for five platforms: the canvas raster's bytes on aarch64 against x86_64. |
| `canvas-marshal-2026-08-26.txt` | What one animated canvas frame costs a guest to BUILD AND SUBMIT, in python, java and rust — the number that decides whether the reserved packed-encoding lane is needed. Found the Java record encoder's 4096-byte ceiling on the way. |
| `canvas-marshal-guest-2026-08-26.py` | That report's python guest. |
| `canvas-marshal-guest-2026-08-26.java` | Its java twin, in package `dev.kaya`. Run against the tree's own `KayaWire` it prints the 4096-byte ceiling and stops, which is the watched negative for that defect. |
| `canvas-chart-raster-2026-08-27.txt` | What the portfolio chart's re-raster costs per tick, and how much of it is the seven shaped label runs — docs/canvas-plan.md §11's rows 5 and 6. Also records the measurement that did NOT work: a harness A/B whose two arms both read 0ms. |
| `canvas-palette-look-2026-08-27.txt` | The §6 palette reviewed in BOTH modes on the real chart, by rendering the core's own display raster per mode instead of switching the host's appearance. Contrast numbers per role, the eyeball reading the pixels corrected, and the one question a dark machine still owes. |

`canvas-marshal-2026-08-26.txt` keeps its two guests beside it, on the
`choke-ios-guest-2026-08-24.swift` precedent, and its own recipe; its
rust half is a `#[test]` that has to live inside the crate and is
therefore written out in the report itself.

The 2026-08-24 files were written by hand from one-off scripts that no
longer exist. `tools/bench-tables.sh` is those scripts turned into
something re-runnable; where it does not yet drive a rig, the rig's
recorded procedure is written out under "The five rigs" so the next
session repeats the measurement instead of designing a new one.

## Running it

```
tools/bench-tables.sh <guest|macos|linux|windows|android|ios> [--dry-run]
                      [--rows N,N,N] [--repeats K] [--chunk C] [--out PATH]
```

A real run records a dated file matching `docs/measurements/tables-*.txt`
(platform and date in the name). A
`--dry-run` records under `target/bench/` instead, because a dry run is
not a measurement and must never be mistaken for one later.

The script refuses before it measures anything, and the refusals are the
part worth having:

| Exit | Refusal |
|---|---|
| 2 | Not a bench platform, or an argument it does not know. |
| 3 | A matrix is live. Either this shell carries `KAYA_MATRIX_GATES_TOKEN` (so `tools/validate-all.py` started it) or a lane runner is in the process table. |
| 4 | The platform's environment is absent, in the terms `tools/probe-env.sh` uses. |
| 5 | The environment is fine but this script does not drive that rig yet; the recipe is below. |

Two platforms are automated today, `guest` and `macos`. The other four
are recorded procedures rather than never-run orchestration code, on the
reasoning in CLAUDE.md invariant 3: a branch nobody has watched is a
guess, and four untested drivers would rot in silence. The debt is in
`docs/deferred.md`.

## What each number means

### `platform=guest` — what a guest spends before the wire

Runs anywhere, needs no display, and is the only rung a gate sweep could
adopt. It times the binding's *accumulation* path: rows are built before
the clock starts and the transaction is abandoned rather than submitted,
so no stage and no backend is involved.

| Key | Meaning |
|---|---|
| `N` | Rows inserted into one fresh collection. |
| `ms_per_row` | Wall time of the insert loop divided by `N`. |
| `total_ms` | The insert loop's whole wall time. |
| `median_ms_per_row` | Median of the repeats at that `N`. |
| `growth` | Per-row cost against the smallest `N` in the run. |

`growth` is the number that matters. A linear accumulation path holds
near `1.00x`. This is where two of 2026-08-24's bugs lived, and both
showed up here as growth: the Swift binding's linear `modelSet` scan
(32,000 inserts cost 15,135 ms, 18 ms once fixed) and the Python
binding's per-mutation rollback snapshot (`9.7-12.6x` growth before the
fix, `0.97-1.01x` after). Both entries are struck in `docs/deferred.md`.
`bindings/python/kaya_app_checks.py` guards the Python one at gate time
with a bound of `3.0x`; this rung is the same measurement without a
verdict attached, across more values of `N`.

The first recorded run, `tables-guest-2026-08-26.txt`, read
`0.00298 ms/row` at N=2,000 and `0.00300 ms/row` at N=32,000, a growth of
`1.01x`. That is the Python fix holding sixteen times past the size the
gate checks it at.

### `platform=macos` — launch to verdict on the SwiftUI interpreter

Opens real windows, so it needs a logged-in GUI session (rung 3 of
CLAUDE.md's validation ladder).

| Key | Meaning |
|---|---|
| `N` | Rows stamped into the table. |
| `wall` | Launch to the `KAYA_SELFTEST` verdict line. |
| `script_start` | Launch to `KAYA_HARNESS: epoch`, i.e. the interpreter being up. Roughly constant; a jump here is a launch problem, not a table problem. |
| `submit_done` | Launch to the guest's last transaction. The guest's own share of `wall`. |
| `verdict` | `PASS`, `FAIL`, or `CAP-120s`. |
| `rc` | The guest process's exit code. |

`wall` minus `submit_done` is the backend's share. Keeping the two apart
is what told the 2026-08-24 investigation that the mac's cost was
model-side and not `NSTableView`'s row realization.

The cap is 120 s, kept from the 2026-08-24 rig so that a capped run today
means what a capped run meant then. **A capped run is the measurer's
limit, not the product's**; most "chokes" in the tables below are that.

## The 2026-08-24 baselines

Launch to verdict, in seconds. These are what the platforms did **on the
day they were measured**, which for several of them is *before* the fixes
that landed the same day. Read the next section before comparing.

| N | macOS native, chunked | Linux GTK, `shell=scroll` | Windows WinUI | Android Compose, chunk=100 | iOS synthesized, chunk=150 |
|---|---|---|---|---|---|
| 500 | 0.22 | 0.39 | 0.45 | 1.4 | 1.2 |
| 1000 | 0.25 | 1.18 | 1.05 | 1.8 | 2.2 |
| 2500 | 0.44 | 7.32 | 4.74 | 2.6 | 4.2 |
| 5000 | 0.71 | 41.74 | 18.99 | died | 11.2 |
| 10000 | 1.18 | cap 120 | 77.58 | died | 37.2 |
| 20000 | 2.89 | cap 120 | cap 120 | died | 120 cap (144.2 uncapped) |
| 42500 | 6.50 | — | — | — | — |

Two numbers per platform, in the investigation's own terms. DEGRADED is
the first N over five seconds; CHOKE is the first N that fails.

| Platform | Tier | DEGRADED | CHOKE (one transaction) | CHOKE (chunked) | How it failed |
|---|---|---|---|---|---|
| macOS | native `NSTableView` | 30,000 | 161 | 43,750 | Harness retry window expiring |
| Linux | synthesized, realizes every row | ~1,950 | 1,361 | 6,000 | X11 `BadAlloc`; then the cap |
| Windows | synthesized | 2,550 | — | 12,000 | The cap, process still working |
| Android | synthesized | ~4,500 | 157 | 4,000 | `java.lang.OutOfMemoryError` |
| iOS | synthesized | 3,000 | 161 | 20,000 | The cap; SIGKILL at ~4.5 GB by 40,000 |

Where the time went, from `sample` on a 100,000-row mac leg
(`choke-macos-2026-08-24.txt`, note 2):

- ~41% of main-thread samples in `kayaTableGeometryGeneration`, a
  recursive hash of the whole table subtree re-run per body evaluation.
- ~37% in per-child `ObservationTracking` register/cancel, which the
  walk above caused by reading every node property inside the tracking
  scope.
- ~0 in `NSTableView` row realization.
- Pump thread: 5,240 of 5,746 samples parked. The core was not the limit.

Other attributed costs worth not re-deriving:

- Linux: cost tracks **cells**, not rows or inserts. Quartering the cells
  per row cut the time 4.6-7x. A plain `For` with identical widget counts
  was 14-47x faster than the synthesized table.
- Windows: the guest was 0.3% of wall at N=10,000 (209 ms of 77,580 ms).
  The rest was a quadratic reindex on every child append, flat at
  ~1.5 µs per call pair from N=500 to 10,000.
- Android: ~52 KB of Java heap per stamped row against ART's 192 MB
  growth limit. The allocations were Compose's, not the guest's model and
  not the core.
- iOS: the same 5,000 rows cost 13.2 s through the synthesized table and
  34.2 s through a generic flex, with guest work identical.

## What changed after these were taken

Several of the numbers above were bugs that were fixed the same day or
the next. A future run comparing itself to the raw table above will look
like a miracle for the wrong reason. From `docs/deferred.md`, all struck:

| Fixed | Effect on the baseline |
|---|---|
| WinUI's quadratic child reindex | N=2,500 5.3 s to 0.75 s; N=10,000 82.9 s to 4.5 s; the 12,000-row choke became 50,000 in 13.6 s |
| mac's table generation hash became a stored epoch | N=20,000 2.5 s to 1.0 s; the 45,000 choke passes at 5.3 s |
| Swift binding's linear `modelSet` | 32,000 inserts 15,135 ms to 18 ms |
| Python binding's per-mutation rollback snapshot | Growth `9.7-12.6x` to `0.97-1.01x` |
| The 64 KiB pump cap | The N=161 one-transaction wall is gone |
| The wedged-main-thread silence | A step now has a ceiling and publishes a verdict; `tools/check-harness-ceiling.py` holds it |

Row windowing landed after all of these, which moves the whole shape
again. **Re-measure before quoting any number in this file as current.**

## CAVEATS

These decide whether a number is worth anything. Each is recorded
somewhere already; these are pointers, not second copies.

- **A quiescent tree.** Editing the repo during a run invalidates it. A
  matrix attempt printed a mac duration anomaly at 648 s because the tree
  moved underneath it and the lane's same-tree token failed, so it swept
  every gate itself; the untouched rerun was 277 s. Recorded in
  `docs/tables-plan.md`. `tools/bench-tables.sh` stamps the working
  tree's clean/dirty state into every record's header for this reason.
- **No `KAYA_FAST`.** The bench never sets it and neither should you.
  The rule and its reasoning are in CLAUDE.md's environment section and
  `tools/keyed.py`; a run that goes on the record consults no cache.
- **Host contention.** Every 2026-08-24 number was taken with the other
  four lanes' pools live on one machine. The mac report puts the
  run-to-run spread at roughly +/- 50% for that reason, which is why
  every boundary there was repeated three times. The Linux report says
  the same about its 5,000-6,000 band, where 2,250 once came in slower
  than 2,500. The iOS report notes 12.2 GB of swap already in use before
  its first run. This is why `tools/bench-tables.sh` refuses to start
  next to a matrix, and why `--repeats` defaults above one.
- **The human in the GUI session.** The mac lane runs in the logged-in
  session, so anyone using the machine is part of the test surface.
  Watching a video during a matrix failed 46 accessibility and dialog
  legs; one copy to the clipboard mid-lane failed a clipboard leg with
  the user's own text in the sentence. Recorded in `docs/traps.md` under
  "Heavy concurrent GUI churn degrades the macOS accessibility
  subsystem, LANE-WIDE". Bench on a machine nobody is using.
- **A cap is not a choke.** Most failures in the tables above are the
  120 s cap. The iOS report proved the point by raising the cap to 400 s
  and finishing at 144.2 s.
- **Chunk size does not matter.** Measured on three platforms
  (25/50/100/150 rows per transaction all landed within noise).
  Chunking itself is a workaround for the pump cap, not the product's
  shape, and that cap is gone.

## The five rigs

What was actually run on 2026-08-24. `guest` and `macos` are automated by
`tools/bench-tables.sh`; the rest are here so they can be repeated.

**macOS.** Python guest, four columns, strings from a counter, launched
from the repo root with `PYTHONPATH=bindings/python`,
`KAYA_SWIFTUI_LIB=target/swiftui/libkaya_swiftui.dylib`,
`KAYA_LIB=target/debug/libkaya.dylib`, `KAYA_SELFTEST=rows`,
`KAYA_SELFTEST_SCRIPT` inline, `KAYA_ROWS`, `KAYA_CHUNK=100`; cap 120 s
then SIGKILL. Now `tools/bench/drive_mac.py` and
`tools/bench/rows_guest.py`.

**Linux.** Python guest in the `kaya-linux` docker image, X11 under Xvfb
at 1600x1000x24 with `GDK_BACKEND=x11`, repo mounted read-only, one leg
mimicking `tools/linux/run-suites.sh`'s `run_one`. Row count in
`KAYA_CHOKE_N`; mechanism probes used `KAYA_CHOKE_COLS=1` and
`KAYA_CHOKE_TABLE=0`. Three window shells were measured, `bare`, `sized`
and `scroll`; **only `scroll` is comparable to the other platforms**,
because `bare` measures X11's 32,767 px window ceiling rather than row
cost. Geometry read with `xwininfo`; CPU split measured guest against
Xvfb.

**Windows.** Python guest on the lane's VM, staged under its own
directory, launched through its own `schtasks` task and a hidden-window
shim, driven from the host over an ssh mux. Row count in
`KAYA_CHOKE_ROWS`, script inline in `KAYA_SELFTEST_SCRIPT`. Every guest
output line is stamped with ms since launch, so the verdict line carries
its own wall time. Cap 120 s.

**Android.** Rust guest on the Compose interpreter, built from a copy of
the tree and installed under its own application id so the lane's own
app is untouched. Headless emulator from the standing pool, launched
with `am start -W`; `KAYA_ROWS` and `KAYA_CHUNK` ride as intent extras.
Timed host-side from `am start -W` to the logcat verdict line, or to the
process dying, or to the cap. Memory from `dumpsys meminfo`.

**iOS.** Swift guest, source kept beside this file as
`choke-ios-guest-2026-08-24.swift`, compiled exactly as
`tools/ios/run-sim.py` compiles a swift-suite leg, all three artifacts
`build-id --verify`'d first. Simulator from the standing pool, launched
under `timeout 120 xcrun simctl launch --console-pty`, script passed as
`SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT`. `KAYA_CHUNK=0` selects the natural
one-transaction spelling; `KAYA_NO_COLUMNS` was the A/B against a generic
flex. Peak RSS from an external sampler.

Both mobile rigs proved their own cleanup rather than asserting it: the
Windows run verified its scheduled task and directory gone and the staged
dll's hash unchanged, and the iOS run diffed its installed-app listing
against a pre-run snapshot and deleted 15 crash reports.

## Provenance

The 2026-08-24 files were written by the session that ran them, from
scripts kept in a session scratchpad that is now gone. The reports are
therefore the only surviving record of those runs, which is why they are
checked in verbatim rather than summarized. Their raw `sample` traces
were read into the reports and deleted at the time; **they cannot be
recovered**, and re-deriving any of those percentages means re-running
the rig.

`tables-guest-2026-08-26.txt` was produced by the recipe in this
directory and can be reproduced by re-running it.

The row-cell formula the guests stamp lives in one place,
`tools/bench/cells.py`, so a change cannot make a guest's data disagree
with the harness expectation built from it.
