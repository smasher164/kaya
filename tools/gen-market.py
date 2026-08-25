#!/usr/bin/env python3
"""Regenerates guests/assets/market/transactions.csv, byte-stable.

Synthetic by doctrine (docs/portfolio-plan.md: deterministic data keeps
the scenes honest) and by licence (real market data is not
redistributable; this is ours). The walk runs BACKWARD from the
portfolio book's live prices (guests/python/portfolio.py), so the last
row of history meets the dashboard's present and the canvas charts can
share this file. Integer cents everywhere; the LCG is spelled here so
no language runtime's random module is load-bearing.
"""

import pathlib

import os

# KAYA_GEN_MARKET_OUT: check-assets regenerates into a scratch file to
# byte-compare (the derivation clause); the default is the real root.
OUT = pathlib.Path(
    os.environ.get("KAYA_GEN_MARKET_OUT")
    or pathlib.Path(__file__).resolve().parents[1]
    / "guests" / "assets" / "market" / "transactions.csv"
)

# The book's anchor prices in cents (portfolio.py's present day).
TICKERS = [
    ("AAPL", 18000),
    ("NVDA", 95050),
    ("VTI", 26025),
    ("BND", 7210),
    ("VXUS", 6140),
]
ACCOUNTS = ["brokerage", "retirement", "savings"]
DAYS = 1096  # three years, fixed span ending 2026-08-24
SEED = 0x6B617961  # "kaya"

# The ledger's DECLARED size, kept from the most recent end. The per-day
# lot count is a draw, so the walk overshoots and the tail is taken:
# without a declared number every density tweak would move `total` in
# three byte-frozen scenes at once. 15,000 is above WinUI's measured
# 12,000-row choke (docs/measurements/choke-windows-2026-08-24.txt),
# which is the size row windowing exists to make ordinary
# (docs/virtualization-plan.md §5).
ROWS = 15_000
# Lots per account-day, 1..LOTS. ODD ON PURPOSE: this LCG's low bits
# have short periods (bit 0 alternates), so an even modulus draws a
# visibly periodic pattern — `below(8)` and `below(6)` produce the same
# skip sequence here, measured.
LOTS = 11


class Lcg:
    """Numerical Recipes constants; 32-bit state, spelled out so every
    regeneration on any host is the same bytes."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self):
        self.state = (self.state * 1664525 + 1013904223) & 0xFFFFFFFF
        return self.state

    def below(self, n):
        return self.next() % n


def dates():
    """DAYS calendar dates ending 2026-08-24, oldest first. A fixed
    civil-date walk, no time module: regeneration cannot drift."""
    y, m, d = 2026, 8, 24
    mlen = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    out = []
    for _ in range(DAYS):
        out.append(f"{y:04d}-{m:02d}-{d:02d}")
        d -= 1
        if d == 0:
            m -= 1
            if m == 0:
                y, m = y - 1, 12
            leap = m == 2 and (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0))
            d = 29 if leap else mlen[m - 1]
    return list(reversed(out))


# The stamp is DERIVED BOOKKEEPING and lives outside the asset root on
# purpose: the root ships to every platform as a unit and its listing
# is byte-frozen in tools/scenes/assets.steps.
STAMP = pathlib.Path(__file__).resolve().parents[1] / "target" / "gen-market.src"


def stamp_id():
    """Generator bytes AND artifact bytes: a stamp keyed on the
    generator alone calls a corrupted artifact current, and the fix
    check-assets names would then heal nothing."""
    import hashlib
    gid = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()[:16]
    aid = (hashlib.sha256(OUT.read_bytes()).hexdigest()[:16]
           if OUT.exists() else "absent")
    return f"{gid} {aid}"


def write_stamp():
    STAMP.parent.mkdir(parents=True, exist_ok=True)
    STAMP.write_text(stamp_id() + "\n")


def ensure():
    """Regenerate unless generator AND artifact both match the stamp —
    the artifact is DERIVED, never committed (maintainer, 2026-08-24)."""
    if OUT.exists() and STAMP.exists() and STAMP.read_text().strip() == stamp_id():
        return False
    generate()
    write_stamp()
    return True


def generate():
    rng = Lcg(SEED)
    span = dates()

    # Backward walk per ticker: from the anchor, step at most 1.4% a
    # day, floored at 5% of the anchor so nothing goes absurd.
    prices = {}
    for ticker, anchor in TICKERS:
        walk = [anchor]
        for _ in range(DAYS - 1):
            step = rng.below(29) - 14  # -14..14 per mille
            prev = walk[-1] * 1000 // (1000 + step)
            walk.append(max(prev, anchor // 20))
        prices[ticker] = list(reversed(walk))

    rows = []
    for i, day in enumerate(span):
        for account in ACCOUNTS:
            # A quiet day for this account, so per-day row counts vary.
            if rng.below(5) == 0:
                continue
            for _ in range(1 + rng.below(LOTS)):
                ticker, _ = TICKERS[rng.below(len(TICKERS))]
                price = prices[ticker][i]
                side = ("buy", "sell", "div")[rng.below(3)]
                qty = 1 + rng.below(40)
                if side == "div":
                    qty = 0
                    total = (1 + rng.below(90)) * 25  # cents
                else:
                    total = qty * price
                rows.append((day, account, ticker, side, qty, price, total))
    if len(rows) < ROWS:
        raise SystemExit(
            f"gen-market: the walk produced {len(rows)} rows, fewer than the "
            f"declared {ROWS} — raise LOTS or DAYS")
    rows = rows[-ROWS:]

    lines = ["date,account,ticker,side,qty,price_cents,total_cents"]
    for day, account, ticker, side, qty, price, total in rows:
        lines.append(f"{day},{account},{ticker},{side},{qty},{price},{total}")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    print(f"{OUT}: {len(rows)} transactions, {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    import sys
    if "--ensure" in sys.argv:
        print("regenerated" if ensure() else "current (stamp matches)")
    else:
        generate()
        if "KAYA_GEN_MARKET_OUT" not in os.environ:
            write_stamp()
