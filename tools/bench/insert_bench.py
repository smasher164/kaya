#!/usr/bin/env python3
"""The headless rung: what a guest spends BEFORE the wire.

Every platform's choke report separates the wall into guest-side
accumulation and backend-side realization, and the guest-side half needs
no display — so this rung runs on any machine, including one with no GUI
session, and is the only bench in the family a gate sweep could ever
adopt. It is also where two of 2026-08-24's bugs actually lived: the
Swift binding's linear `modelSet` scan and the Python binding's
per-mutation rollback snapshot, both N² in the accumulation path with no
backend involved (docs/deferred.md, both struck).

The rows are built BEFORE the clock starts and the transaction is
abandoned, so what is timed is the binding's accumulation path and not
Python's f-strings or any submit.

    python3 tools/bench/insert_bench.py --rows 2000,8000,32000 --repeats 3

Reads KAYA_LIB the way every python guest does (bindings/python/kaya/
runtime.py); tools/bench-tables.sh builds and --verify's that library
before calling this.
"""

import argparse
import os
import statistics
import sys
import time
from dataclasses import dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "bindings/python"))
sys.path.insert(0, HERE)

import kaya  # noqa: E402
import record  # noqa: E402


@dataclass
class Row:
    date: str
    ticker: str
    side: str
    total: str


class _Abandon(Exception):
    """Leaves the build closure without submitting: the accumulation path
    is the measurement, and a submit would drag a stage into it."""


def per_row_ms(app, n):
    from cells import cells

    took = None
    try:
        with app.build():
            table = kaya.collection(Row).at()
            rows = [("r%07d" % i, Row(*cells(i))) for i in range(n)]
            start = time.perf_counter()
            for key, value in rows:
                table.insert(key, value)
            took = time.perf_counter() - start
            raise _Abandon()
    except _Abandon:
        pass
    return took * 1000.0 / n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", default="2000,8000,32000")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    counts = [int(x) for x in args.rows.split(",") if x.strip()]
    if args.dry_run:
        counts = [50]
        args.repeats = 1

    argv = ["tools/bench/insert_bench.py", "--rows", args.rows,
            "--repeats", str(args.repeats)]
    if args.dry_run:
        argv.append("--dry-run")
    print(record.header(
        ROOT, "platform=guest (headless; guest-side accumulation only)", argv,
        extra=[("library", os.environ.get("KAYA_LIB", "resolved by runtime.py")),
               ("dry-run", "YES — N forced to 50, one repeat, numbers are "
                           "plumbing proof and NOT a measurement")
               if args.dry_run else ("mode", "measurement")]))

    app = kaya.App()
    medians = {}
    for n in counts:
        samples = []
        for r in range(args.repeats):
            ms = per_row_ms(app, n)
            samples.append(ms)
            print(record.line(platform="guest", binding="python", N=n,
                              repeat="%d/%d" % (r + 1, args.repeats),
                              ms_per_row="%.6f" % ms,
                              total_ms="%.1f" % (ms * n)), flush=True)
        medians[n] = statistics.median(samples)

    print("#")
    smallest = min(counts)
    base = medians[smallest]
    for n in counts:
        print(record.line(platform="guest", binding="python", N=n,
                          median_ms_per_row="%.6f" % medians[n],
                          growth="%.2fx" % (medians[n] / base),
                          growth_baseline_N=smallest))
    print("#")
    print("# growth is per-row cost against the smallest N. A LINEAR "
          "accumulation path holds near 1.00x;")
    print("# the two 2026-08-24 bugs read 9.7-12.6x (python) and 15135ms "
          "vs 18ms at 32000 (swift).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
