"""The encode benchmark: pins "derives target the encoder, not a value
tree" (DESIGN.md, milestone 3) as a suite leg rather than review
vigilance. Encodes N collection_insert records through the generated
wire encoder and requires a floor rate — the bound has ~10x headroom on
any machine that runs the suites, so only a structural regression (per-
record reflection, tree building) can trip it.
"""

import sys
import time

from kaya import wire

N = 200_000
FLOOR = 20_000  # records/second

start = time.perf_counter()
chunk = []
for i in range(N):
    chunk.append(wire.tx_collection_insert(1, [], f"k{i & 1023}", 0, ["send report", False]))
    if len(chunk) == 1000:
        chunk.clear()
elapsed = time.perf_counter() - start

rate = int(N / elapsed)
if rate >= FLOOR:
    print(f"ENCODE_BENCH: OK (python: {rate} rec/s)")
else:
    print(f"ENCODE_BENCH: FAIL (python: {rate} rec/s, floor {FLOOR})", file=sys.stderr)
    sys.exit(1)
