# GTK capture refuses a failed run

Baseline: 8749e318. This is a capture-tool correction, not a binding or native
widget semantic change. No new user ruling is needed.

## Before

The existing helper's real shell payload was extracted from its Python AST
(one assignment). Seven `/work` path substitutions moved it into scratch.
Stub commands controlled failures without changing a toolchain or tracked
source. A planted previous image was present at the shared capture path.

| Case | Build exit | Capture exit | Payload exit | Old image copied |
| --- | ---: | ---: | ---: | --- |
| Failed build | 42 | 0 | 0 | yes |
| Failed capture | 0 | 43 | 0 | yes |

Cargo's pipeline reported tail's success; conversion after a semicolon could
run despite a capture failure. Shared output paths made the prior screenshot
usable. Both cases ran build, capture and conversion. These are controlled
executions of the original shell, not native cargo/Xvfb failures.

## Change and guard

The helper's own Python runs inside the existing Linux image under Xvfb.
Build, build-id verification, screenshot and conversion are checked calls.
The host creates a fresh mounted capture directory per run, and copies the
result only after a zero container exit and a PNG signature/size check.
Guest exit before or during capture refuses; cleanup terminates and reaps the
guest, with a bounded kill fallback. `<requested output>.log` retains command
output and guest output. Build or capture failure does not publish over the
requested photograph; this is not a guarantee against an output-disk write error.

Build-id verification of the preexisting Rust confirm executable refused:
NO build id. The checked build therefore selects both lib and example, like
the lane, then verifies libkaya.so. The example's successful cargo build is
required separately from the library's embedded core-source marker.

The existing tools/check-build-id.py gate runs the actual helper function
bodies with controlled subprocesses: 12 container cases and four host cases.
Ten counted source mutations were watched failing, with 12 substitutions in
total. They remove command checking, verification, early-exit refusals, image
checks, termination, kill or host refusal before publication. Test fixtures
with a PNG header are not claimed to be decoded photographs.

A native confirm capture succeeded: 3,697 bytes, viewed as the confirm window
with its status label and delete/eject buttons. The retained log named all four
checked commands and contained the guest's window metrics and held steps.
A second native container probe called the capture body with a deliberately
absent example target. Real cargo returned 101; the helper reported the build
failure, launched no guest (no guest log), and left a planted output unchanged.
The CLI's scene-existence check was bypassed only by this direct-function probe
to reach the build-failure branch. No tracked source was mutated for it.
Scratch evidence is under `target/session-notes/gtk-capture-2026-09-21/` (built).

## Validation

Core/harness passed 644 unit tests and 25 doctests, with one existing ignored
doctest. All 61 gates passed, including the new 16 execution cases and ten
counted mutations. Standalone Mac passed all 477 legs.

The final matrix was ALL PASS in 1104 seconds (18m24s):

| Lane | Legs | Wall seconds | Exclusive wait | Net seconds |
| --- | ---: | ---: | ---: | ---: |
| Mac | 477 | 582 | 192 | 390 |
| Linux | 777 | 1095 | 486 | 609 |
| Windows | 283 | 1088 | 162 | 926 |
| iOS | 139 | 998 | 399 | 599 |
| Android | 148 | 662 | 149 | 513 |

The matrix's independent 61-gate sweep passed in 316 seconds. Every unchanged
timing ceiling held. No binding surface changed, so no language carve-out or
spelling change is introduced. The KEY sweep covered the ledger, HACKING,
GTK chrome notes, traps and the capture helper's pointer.
