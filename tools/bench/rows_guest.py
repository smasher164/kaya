"""The bench's table guest: KAYA_ROWS four-column rows, KAYA_CHUNK rows
per transaction.

Recreated from docs/measurements/choke-macos-2026-08-24.txt PART B, which
is the shape the mac baselines in docs/measurements/README.md were taken
against. KAYA_CHUNK=0 is PART A, the natural one-transaction spelling
stamped inside the build closure — the shape that used to hit the 64 KiB
pump cap at N=161 (that wall is gone; docs/deferred.md's pump entry).

Not a lane guest: it is not in guests/, has no .steps file and no scene
name of its own. tools/bench-tables.sh launches it.
"""

import os
import sys
from dataclasses import dataclass

import kaya

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cells import cells  # noqa: E402

N = int(os.environ.get("KAYA_ROWS", "2000"))
CHUNK = int(os.environ.get("KAYA_CHUNK", "100"))


@dataclass
class Row:
    date: str
    ticker: str
    side: str
    total: str


app = kaya.App()

with app.window(title="rows"):
    rows = kaya.collection(Row)
    with kaya.row():
        for item in rows.columns("Date", "Ticker", "Side", "Total", grow=1):
            with kaya.row():
                kaya.label(bind=item.date)
                kaya.label(bind=item.ticker)
                kaya.label(bind=item.side)
                kaya.label(bind=item.total)
    if CHUNK <= 0:
        # PART A: one transaction, the build closure's own.
        for i in range(N):
            rows.insert("r%d" % i, Row(*cells(i)))
        print("KAYA_BENCH: submit_done", flush=True)

if CHUNK > 0:
    # PART B: KAYA_CHUNK rows per posted transaction, chained. The
    # binding opens the transaction for the handler (check-ambient-tx).
    state = {"next": 0}

    def land():
        start = state["next"]
        end = min(start + CHUNK, N)
        for i in range(start, end):
            rows.insert("r%d" % i, Row(*cells(i)))
        state["next"] = end
        if end < N:
            app.post(land)
        else:
            print("KAYA_BENCH: submit_done", flush=True)

    app.post(land)

sys.exit(app.run())
