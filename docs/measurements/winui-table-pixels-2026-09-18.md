# WinUI table tracks: independent rounding feeds a resize ramp

Measured 2026-09-18 on the Windows ARM64 VM, with the Mac and Linux lanes
providing the same real workload as the original layout-fault investigation.
This changes no binding API or scene grammar.

## Before

The old allocator divided spare DIP equally. WinUI rounds each fixed-width
column independently. Four half-pixel tracks therefore gained two physical
pixels in native layout. Nested tables could feed that larger desired width
back into the next allocation.

The temporary chrome probe read actual/desired widths, margins, padding and
borders for the table grid, decorative card, header, rule, body band, folded
wrapper and first row, plus both ScrollViewers' viewport/extent/scrollable
widths. A second probe added display scale and requested/resolved column
widths. No guessed cause was printed by the instrument.

One quiet portfolio run passed with 67 stamps. Under the Mac/Linux lanes,
rounds 1 through 7 passed with 57 to 66 stamps; round 8 passed with 177 stamps
and 51 consecutive two-DIP increases on one table. The existing bounded
layout-abandon path fired twice, once for each nested table. The container's
padding was 12 DIP on either side; the decorative card's border was one DIP,
but its desired width was zero. Neither ScrollViewer reserved a border or
padding. Header and folded wrapper alternated in reporting the extra width.

The follow-up native read at scale 1 settled the cause:

| Column | Requested DIP | Resolved DIP |
| --- | ---: | ---: |
| 1 | 120.5 | 121 |
| 2 | 105.5 | 106 |
| 3 | 121.5 | 122 |
| 4 | 136.5 | 137 |

The header and body extents were 558 DIP against a 556-DIP viewport. WinUI's
[Grid implementation](https://github.com/microsoft/microsoft-ui-xaml/blob/main/dxaml/xcp/core/core/elements/Grid.cpp)
independently layout-rounds every fixed-width definition, matching the read.

## Allocation and guard

Convert the measured content floors to physical pixels, recover the whole
pixel count from their single-precision storage, and divide spare whole
pixels by quotient and remainder. The first remainder columns receive one
extra pixel. Convert back to DIP only for the native definitions. Header and
rows retain identical tracks; extras differ by at most one physical pixel.

The budget starts with the rounded outer width and subtracts rounded TOTAL
padding and TOTAL spacing separately. Rounding the inner width indiscriminately
can add a pixel at a half-pixel boundary; ceiling the padding can shrink a
hugging container on every pass. The cache compares already-quantized tracks
exactly, so a one-pixel change is not ignored at a high display scale.

Three WinUI unit tests guard the captured four-column case, content overflow
and floor recovery, and 20,072 combinations of width, column count and scale.
The scale loop uses native single-precision DPI/96 values, as
[WinUI's layout rounding](https://github.com/microsoft/microsoft-ui-xaml/blob/main/dxaml/xcp/core/core/elements/uielement.cpp)
does. This is a pixel-budget invariant test, not a replacement for native
layout. It also checks stability under 0.01 physical pixel input noise.
The Windows deployment always runs the WinUI test module and refuses a
verdict if its test count does not match the source.

Four doctored copies of the exact production function and test bodies were
compiled and run on the Mac. Each substitution count was 1. Restoring the
old allocation failed 3 tests; ignoring scale failed 2; erasing floors failed
3; ceiling padding failed 1. The unmodified copy passed all 3. No production
file was mutated for these negatives.

## After

All 50 portfolio repetitions passed: 50 to 77 stamps per leg (mean 64.34),
no two-pixel ramp, no abandoned row-window report, and no growing sequence
longer than two stamps. Every one of 10,668 nonzero requested/resolved column
readings matched exactly. The Windows unit phase passed 36/36 WinUI tests,
including the three new tests, plus 4/4 file-handle and 3/3 exit-grace tests.

Load qualification: Linux ran all 775 legs successfully and finished around
repetition 41. The Mac load run exercised its gate sweep but stopped before
GUI legs: the new trap pointer had not yet been written, and whole-file
formatting broke an unrelated negative's exact mutation pattern. Both are
corrected in the final tree. This is not a claim of 50 repetitions under two
complete concurrent GUI lanes. The captured native rounding and pixel-budget
tests establish the mechanism; the final validation ladder is recorded in
the commit message.

The temporary chrome probe is removed after recording these readings. The
existing stamp trace and bounded transient-layout guard remain unchanged.

Raw logs are retained in the session scratch directory (ephemeral):

```
/tmp/kaya-table-chrome.yHhj8i/
  quiet.log
  repeat/001.log through repeat/008.log
  resolved.log
  after/001.log through after/050.log
  after-repeat.log
```

The temporary registry trace setting was removed and read back as absent
after each runner, including the cleanup path.
