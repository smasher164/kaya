# The full matrix's wall, 2026-10-06

Plain `tools/validate-all.py` on an idle host, no Sleep/Wake, every leg green.

| Tree | Wall | mac | linux | windows | ios | android | sweep | android-quiet |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 3815e98e (before) | 2098 s | 1055 | 1302 | 1712 | 1437 | 1011 | 436 | 201 |
| 42eb5384 (after, warm) | 1588 s | 783 | 1163 | 1386 | 1129 | 925 | 336 | 68 |

Lane figures are wall seconds; nets against the ceilings on the second run:
mac 726/1100, linux 791/1250, windows 1236/1650, ios 880/1350, android 778/870.

What moved it, each in docs/traps.md:
- the android-quiet row installs the apks the Android lane built (201 -> 68 s);
- the Android drags hold no matrix-wide token (lanes/android.py's ALONE);
- the Windows media_delivery legs run in pairs;
- WinUI typing posts to the guest's own input site, so search and submit pool;
- the example graph's dependency features named in kaya's manifest, so a
  --lib build and an --example build no longer recompile kaya (mac
  core-build+gates 136 -> 76 s, ios swiftui-examples-built 108 -> 18 s,
  android build-compose 175 -> 57 s, windows build 121 -> 5 s).

The Windows lane remains the wall (1386 s, 150 s of it token waits); the
start's gates.py --build about 134 s, the quiet tail 68 s.
