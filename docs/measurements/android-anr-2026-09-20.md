# Android clipboard failure and ANR evidence, 2026-09-20

The third C# async-dialog matrix failed clipboard-jvm on emulator-5554 in
108 seconds. C# does not run on Android; no Android or Java binding code was
changed. The original bundle was in recorder run
`20260920T221654Z-069460`, leg `android-clipboard-jvm`.

## Evidence, read before diagnosis

The bundle held all five declared sections. Its screenshot was inspected and
showed the launcher; shot.when correctly said the app had already exited.
The verb trace held 916 records, none dropped. The first paste succeeded at
27.686 seconds. The second paste returned at 32.626 seconds, but 437 reads
never found the expected text. Accessibility and row-paste checks then failed.
The logcat tail showed Android denying clipboard access because the app was
not focused. It did not show what held focus.

The runner's separate full-buffer file supplied that history:

| Time, PDT | Reading |
|---|---|
| 15:27:31.841 | Focus entered the Java host window |
| 15:27:36.855 | InputDispatcher timed out after 5013ms waiting for FocusEvent(hasFocus=true) |
| 15:27:36.950 | ANR event timestamp, PID 18476 |
| 15:28:01.756 | ANR dialog requested focus |
| 15:28:02.057 | Focus left the app |
| 15:28:02.597 | First clipboard-access denial |
| 15:28:03.951 | Focus entered Application Not Responding: dev.kaya.javahost |

The system-owned ANR file could not be read directly by the ordinary adb
shell. Android's DropBox report was retrieved without rooting or restarting
adb. Its publication timestamp was 15:28:00, so a 15:27 publication filter
missed it. The report's own PID and event timestamp match the logcat event.

The main-thread stack was in LineBreaker.computeLineBreaks, StaticLayout,
Compose ParagraphLayoutCache and TopAppBar measurement. Its scheduler totals
were 6.67 seconds running and 8.55 seconds waiting. Device CPU pressure
`some avg10` was 64.49. These are evidence of contention, not proof that load
was the only cause or that a particular layout call is defective.

The host had also reached load 518.87 with 389 runnable processes earlier in
this matrix. A one-second simulator diagnosticd sample was mostly waiting
workers with some XPC activity; it did not identify a sole source of the load.

## Recorder correction

The failure path now keeps two more sections before returning the emulator
to the pool. `system-events` selects focus, ANR and clipboard events from the
full buffer already saved by the runner. `anr-history` reads DropBox and
keeps reports for the failing package, newest published entries first. The
heading explicitly warns that reports may predate the leg. It does not
attribute an old ANR to a new process. Passing legs add no device calls.

check-flightrec exercises successful package selection, old reports, empty
history, failed reads, timeout and unknown format. Eight counted one-site
mutations cut capture/adoption or corrupt package filtering, attribution,
read status and focus selection; all were watched failing.

The forced-red proof changed exactly one final clipboard expectation, with
the applied count printed. The Java leg failed only that expectation in
18 seconds. Recorder run `20260920T224915Z-099915` held all seven sections:
system-events 815,973 bytes, anr-history 196,887 bytes, 1,589,804 bytes total.
Both new files were read back: the original ANR focus transfer and PID 18476's
LineBreaker stack were present. The report remained labeled historical rather
than attributed to this new, deliberately failed process. The screenshot was
also inspected and showed the launcher, as its timing note reported. The
shared script was restored byte-for-byte; no scene expectation change remains.
The restored Java clipboard leg then passed in two seconds, recorder run
`20260920T225131Z-001261`. This proves the deliberate perturbation was removed;
it does not establish a fix for the contended startup ANR.

## Matrix result

The third matrix took 1671 seconds: Mac 477, Linux 775, Windows 282, iOS 139
and all 61 gates passed; Android passed 147 of 148. Windows exceeded its
1350-second net ceiling by 217 seconds; Android exceeded its 870-second net
ceiling by 38 seconds. The preceding matrix passed every leg and gate but
exceeded Windows' ceiling by three seconds. Neither is an ALL PASS result.
The runtime ceilings were not changed.

## Controlled post-reboot matrix

The maintainer rebooted the Mac and restored the host app's Accessibility
and screen-capture permissions. Fresh core tests passed 628 unit tests and
18 doctests (one ignored), the full sweep passed 61 gates in 159 seconds,
and the standalone Mac lane passed 477 legs in 387 seconds.

The matrix at `20260921T003015Z` was ALL PASS in 1258 seconds. Its lane logs
are retained under `target/validate-lanes/runs/20260921T003015Z/` (built).

| Lane | Legs | Wall seconds | Exclusive wait | Net seconds | Ceiling |
|---|---:|---:|---:|---:|---:|
| Mac | 477 | 581 | 208 | 373 | 1100 |
| Linux | 775 | 864 | 363 | 501 | 1250 |
| Windows | 282 | 1253 | 0 | 1253 | 1350 |
| iOS | 139 | 852 | 173 | 679 | 1150 |
| Android | 148 | 713 | 70 | 643 | 870 |

All 61 matrix gates passed in 436 seconds. No leg failure bundle was produced.
Windows passed 4 picked-file tests, 36 backend tests and 3 exit tests on the VM.
Its suites took 645 seconds, against 1258 before reboot. VM readiness took
342 seconds; a live utmctl status sample showed ScriptingBridge waiting in
AESendMessage. It later proceeded without a runner change. The sample does
not distinguish a permission wait from an unresponsive target.

The host started at load 3.1/4.6/4.0. Startup reached one-minute load 647.08;
the next process census held 1640 processes, 514 runnable, mostly simulator
services. A NewsToday2 sample showed a WidgetKit callback in removeItem,
removefile and unlink; diagnosticd was mostly waiting. These samples identify
activity, not the sole cause of contention. Load later fell below 10 while
Windows finished. A green run after reboot is not an ANR fix; the ledger's
contention investigation remains open.
