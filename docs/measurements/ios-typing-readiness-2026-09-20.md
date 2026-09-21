# iOS typing readiness, 2026-09-20

The first async-dialog matrix failed during iOS admission, before any iOS leg.
Mac 477, Linux 775, Windows 282, Android 148 and all 61 gates passed. The matrix
took 1,069 seconds. The tree was held unchanged throughout the run.

The iOS journal was `20260920T210639Z-094358`. No leg bundle was created because
admission precedes the leg pool. The lane did preserve the resident driver's
three logs in its printed failure-log path. Those logs and the 13 MB XCTest
result bundle were copied into the slice's scratch directory before another
run could replace them. The driver log, not a rerun, supplied the diagnosis.

## The readings

Simulator `45F06B45-D094-4BB9-8B7D-E3572FF334E1`, export-preflight app:

| Event | Reading |
|---|---|
| Save-name field tapped | XCTest elapsed 51.34 seconds |
| Readiness wait returned | Driver timestamp 1789938473.702, after 1.22 seconds |
| Final diagnostic | 1789938476.770: `safe, focused=false keyboards=0` |
| Typing began | XCTest elapsed 56.42 seconds |
| Typing failed | Three attempts reported no keyboard focus; resident test exited 65 |
| Admission retry | The same exited driver could not answer attach; code 76 again |

typingRefusal had kept the wait's earlier true result. Its later focus and
keyboard reads were printed but did not affect the return. Compiling that real
function against controlled readings of keyboard present then absent reproduced
the same diagnostic and exited 1: readiness disappeared, but typing was admitted.
The extraction and template substitution each counted one.

## Correction and guard

The wait must succeed and the final readings must still show focus or a keyboard.
The diagnostic uses those same final values. The reproduced case now refuses
typing and says readiness disappeared after waiting. An expired wait has a
different sentence; both sentences are exercised in the compiled test.

The remote save sheet's field can report no focus while typing succeeds with
a keyboard present, as measured on 2026-09-06. That state remains admitted.
No claim is made that readiness cannot disappear after the final reading.

check-steps compiles the actual method with
tools/checks/ios-typing-readiness.swift: 20 combinations of initial and final
focus/keyboard readings, including callers that cannot query focus. Three
single-substitution negatives discard current readiness, discard the deadline,
or reject the remote field's keyboard-only readiness. A fourth cuts the
savename caller's refusal. Admission code 76 now describes only an incomplete
flow, with no export-health verdict; its real fault-injection branch is run in
the gate, and a counted diagnostic mutation must fail.

The corrected tree passed 628 core tests and 18 doctests (one ignored), all
61 gates in 176 seconds, and the standalone Mac lane's 477 legs. Its next
two matrices each passed all 139 iOS legs. The first missed the Windows net
ceiling by three seconds; the second also encountered the Android startup
ANR recorded in docs/measurements/android-anr-2026-09-20.md. Neither matrix
was ALL PASS. No iOS admission or typing failure recurred in those two runs.

Final post-reboot validation passed all five lanes in 1258 seconds: Mac 477,
Linux 775, Windows 282, iOS 139 and Android 148, plus all 61 gates. Every
unchanged runtime ceiling held. The standalone Mac lane passed 477 legs in
387 seconds; the core passed 628 unit tests and 18 doctests (one ignored).
