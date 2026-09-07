# The gate sweep, measured (2026-09-07)

The 57 fast gates run standalone on the mac host, one at a time, with
no lane running and the host quiet (load average under 8). Nothing was
cached: `KAYA_FAST` was unset, so every gate ran in full. The serial sum
is 378s. The same list four wide
(`tools/gates.py`, the schedule of 2026-09-07: the three generator
checks first and alone, then a pool of four taking the heaviest gates
first, check-targets last) ran 57/57 in 151s of wall.

Why it was measured: the matrix starts the sweep only after the
Android lane exits, and one gate at a time that made the wall Android
plus the whole sweep in series — the last such matrix read 654s
(android) + 422s (sweep) = 1082s. These numbers are the WEIGHT table in
tools/gates.py and the reason check-table-tier heads the pool: it is 36%
of the serial sum on its own, so it must start first or it is the
sweep's tail.

THE t0 LAUNCH, MEASURED AND REJECTED THE SAME NIGHT (matrix #24): with
the four-wide niced sweep starting beside the five lanes at t0, the
sweep itself took 341s, the wall fell 1082 -> 966s, and EVERY lane
slowed by 150-200s past its ceiling — mac 716 -> 932, linux 750 -> 948,
ios 788 -> 949, android 654 -> 852, windows 946 -> 961 (the last delayed
matrix's readings first). The host was as quiet at launch as the
matrix before (load 4.5/11.2/14.4 against 7.3/5.3/5.6, the maintainer's
browser on both). Four swiftc compiles at t0 fight every lane's own
build phase, and `nice` on macOS does not keep them out of the way.
After Android, four wide, the sweep's ~250s hides behind the four lanes
that run longer than Android anyway, so the wall is the slowest lane
with nothing slowed to get there.

| gate | seconds |
|---|---|
| check-table-tier | 136.2 |
| swift-typecheck | 56.9 |
| check-sugar-surface | 22.9 |
| check-abort | 17.5 |
| check-assets | 15.2 |
| check-harness-ceiling | 12.0 |
| check-empty-child | 10.2 |
| check-pane-ladder | 10.1 |
| check-pins | 10.0 |
| check-canvas-blit | 8.8 |
| gen-guests | 7.5 |
| check-verbs | 7.1 |
| check-app-identity | 6.3 |
| check-keyed | 5.6 |
| check-steps | 4.7 |
| java-typecheck | 4.0 |
| check-shell | 3.8 |
| check-compose | 3.4 |
| check-file-modes | 3.2 |
| check-c-bounds | 3.2 |
| check-diagnostics | 3.1 |
| check-targets | 2.9 |
| check-doc-refs | 2.5 |
| check-wheel | 2.3 |
| check-detekt | 2.3 |
| go-typecheck | 1.8 |
| js-typecheck | 1.6 |
| check-python | 1.2 |
| gen-header | 1.1 |
| check-universal-props | 1.0 |
| check-roles | 1.0 |
| check-native-undo | 1.0 |
| check-staging | 0.9 |
| check-table-card | 0.7 |
| kaya-app-checks | 0.6 |
| gen-bindings | 0.6 |
| check-stubs | 0.6 |
| check-go-env | 0.6 |
| check-ledger | 0.5 |
| check-compose-state | 0.4 |
| check-c-ids | 0.4 |
| check-slider-commit | 0.3 |
| check-gates | 0.3 |
| check-design-generation | 0.3 |
| check-build-id | 0.3 |
| js-app-checks | 0.2 |
| check-search | 0.2 |
| check-mirror | 0.2 |
| check-exclusive | 0.2 |
| check-tx-liveness | 0.1 |
| check-symbol-parity | 0.1 |
| check-jni | 0.1 |
| check-case | 0.1 |
| check-appearance | 0.1 |
| check-symbols | 0.0 |
| check-ambient-tx | 0.0 |
| check-accent | 0.0 |
