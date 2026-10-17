# The gate sweep, measured (2026-10-17)

The matrix at 5d834ab8 was ALL PASS on every lane and failed on the
sweep alone: `gates: DURATION ANOMALY — 733s ... exceeds the 600s
ceiling`. Its per-gate times summed to 1931s, against 1657s on the
matrix of 2026-10-14. Three gates were 59% of the sum: check-verbs 409s,
check-abort 355s, check-table-tier 346s.

## Where the time went (quiet host, standalone)

- **check-verbs, 403s, 394s of it user time in one python thread.**
  cProfile: 336s of 399s was `re.Pattern.sub`, from one helper,
  content_type_routes' `flat()` (`re.sub(r"\s+", "", text)`), called
  238,963 times. The routes tables (skin 174s, netimage 106s, expander,
  segmented, safearea, reveal, toast) flatten WHOLE interpreter files
  (KayaSwiftUI.swift is 1.68 MB) once per clause, and again for every
  doctored cut (765 negatives). No compiler is involved.
- **check-table-tier, 251s.** Twelve swiftc builds of the whole
  interpreter (about 15s each, 182s) and twelve probe runs (65s), one
  after another, every one on its own doctored copy and binary.
- **check-abort, 257s.** 176 subprocesses in series: Swift 170s (58
  compiles of about 7s), Haskell 31s (cabal 19s), Java 26s, C# 20s,
  Rust and Go 10s, OCaml 3s.
- **gates.py's WEIGHT table was stale.** check-verbs was weighted 7, so
  the pool started it twelfth, behind the gates weighted heavier. In the
  matrix it started about 300s in and ran 409s, which made it the tail.

## What changed

- `flat()` moved to the prelude (tools/lib/kaya_gate.py), spelled
  `"".join(text.split())` (3.3x faster on the Swift file and the same
  character set as re's `\s`, checked over every code point by selftest
  F12), and memoized for texts over 4096 characters (an LRU of 48).
  Caching every text thrashed (a 64-entry cache: 87k hits, 153k misses);
  caching 1024 texts took 1.5 GB of RSS; the large-only cache takes 662
  MB. check-verbs: 403s -> 57s, its output identical line for line.
  Splitting check-verbs into threads would not help: the work is pure
  python and holds the GIL.
- `in_parallel(fn, items, width)` in the prelude: results in item order,
  every worker finished before it returns, and the first failure in item
  order raised (SystemExit included, selftest F11). Width is
  `KAYA_PROBE_JOBS`, default 4.
- check-table-tier builds and runs its twelve probes on it, then judges
  them in declaration order with the same sentences: 251s -> 77s.
- check-abort runs as nine concurrent `--part` children (two of the
  Swift sections are about 50s each, which bounds it): 257s -> 71s.
- WEIGHT re-measured, and the sweep prints `WEIGHT is stale for <gate>`
  for any gate over 30s that ran more than twice its weight (selftest H).

## The sweep

| run | wall | summed gate time |
| --- | --- | --- |
| `tools/gates.py`, quiet, before (HEAD 5d834ab8) | 620s | 1549s |
| `tools/gates.py`, quiet, after | 319s | 890s |

Both walls include the build phase and the unit suite (rung 1), which a
matrix sweep skips when validate-all's key still holds. The longest
gates after the change are check-table-tier, check-abort,
check-sugar-surface and check-app-identity at 80-90s each, so four
wide, no single gate is the tail.

Estimate for a matrix: that sweep ran 1.25x its quiet summed time
(1931 / 1549) beside the other lanes' tails. Applying the quiet ratio
(319 / 620) to the 733s gives about 380s. The parallel parts get less
help on a loaded host, so expect 380-450s, under the 600s ceiling. At
four gates wide, with two of them running four probes each, at most
about ten compilers run at once on the 18-core host.
