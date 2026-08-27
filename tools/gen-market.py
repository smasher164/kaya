#!/usr/bin/env python3
"""Regenerates the market family's two derived artifacts, byte-stable:
transactions.csv (the ledger) and prices.csv (the price history the
portfolio's chart draws).

Synthetic by doctrine (docs/portfolio-plan.md: deterministic data keeps
the scenes honest) and by licence (real market data is not
redistributable; this is ours). Integer cents everywhere; the LCG is
spelled here so no language runtime's random module is load-bearing.

THE LEDGER NETS TO THE BOOK (ruled 2026-08-26): for every account and
every ticker, buys minus sells equal the dashboard's position quantity —
zero where the account holds none — and dividends move money without
moving quantity. The book is READ OUT OF guests/python/portfolio.py by
ast, never copied here: the price walk already claimed to run backward
from that book's live prices while spelling its own prices, and one more
copy is one more thing to drift.

TWO THINGS THAT MAKE THE TIE POSSIBLE, both of them the obstacle
docs/deferred.md's tie-out entry named:
  - the file is the whole life of every position. The overshoot-and-tail
    below decides DENSITY only (how many lots fall on which day); the
    positions are walked over the RETAINED rows alone, starting at zero
    on the first row, so a net over what the file contains is the book's.
  - CASH is a book holding, so it is a tradeable ticker here — flat, at
    its anchor, because a unit of account does not walk.

AND THE HISTORY TIES TO THE SAME BOOK, one column over (2026-08-27, the
canvas chart): prices.csv is the WHOLE walk, every day and every ticker,
and its last day is the anchors — which is the book's live prices. The
ledger could not serve as that history and this is measured, not
assumed: only 43 of the retained 1033 days carry all six tickers, and
two tickers' last traded price sits days short of the anchor, so a
carry-forward series off transactions.csv ends somewhere the dashboard
does not. The refusal below holds the last day to the book the way the
net check holds the quantities.
"""

import ast
import pathlib

import os

# KAYA_GEN_MARKET_DIR: check-assets regenerates into a scratch DIRECTORY
# to byte-compare (the derivation clause); the default is the real root.
# A directory rather than a file since 2026-08-27, when the family grew
# its second artifact — one env var naming one of two outputs would have
# left the other regenerating over the real root.
ROOT = pathlib.Path(__file__).resolve().parents[1]
DIR = pathlib.Path(
    os.environ.get("KAYA_GEN_MARKET_DIR")
    or ROOT / "guests" / "assets" / "market"
)
OUT = DIR / "transactions.csv"
PRICES = DIR / "prices.csv"
GUEST = ROOT / "guests" / "python" / "portfolio.py"

DAYS = 1096  # three years, fixed span ending 2026-08-24
SEED = 0x6B617961  # "kaya"

# The ledger's DECLARED size. The per-day lot count is a draw, so the
# walk overshoots and the tail is taken: without a declared number every
# density tweak would move `total` in three byte-frozen scenes at once.
# 15,000 is above WinUI's measured 12,000-row choke
# (docs/measurements/choke-windows-2026-08-24.txt), which is the size row
# windowing exists to make ordinary (docs/virtualization-plan.md §5).
ROWS = 15_000
# Lots per account-day, 1..LOTS. ODD ON PURPOSE: this LCG's low bits
# have short periods (bit 0 alternates), so an even modulus draws a
# visibly periodic pattern — `below(8)` and `below(6)` produce the same
# skip sequence here, measured.
LOTS = 11
# Shares per lot, 1..LOT, and the room a position may run above what the
# book holds. BAND bounds the settling lot: a position that wandered
# thousands of shares clear of the book would square itself with one
# absurd trade at the end.
LOT = 40
BAND = LOT
# A unit of account does not walk: every CASH row is priced at its
# anchor, which is also what the dashboard shows for that holding.
FLAT = {"CASH"}


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


def book():
    """The portfolio book, by ast. A reader that cannot find its subject
    agrees with anything, so a missing BOOK is a refusal, not a default."""
    for node in ast.parse(GUEST.read_text(), str(GUEST)).body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id == "BOOK"):
            return ast.literal_eval(node.value)
    raise SystemExit(
        "gen-market: guests/python/portfolio.py no longer spells BOOK at "
        "module scope — this ledger is generated to net to that book and "
        "cannot be written without it")


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
STAMP = ROOT / "target" / "gen-market.src"


def stamp_id():
    """Generator bytes, GUEST bytes and BOTH artifacts' bytes: a stamp
    keyed on the generator alone calls a corrupted artifact current, one
    blind to the guest would call a ledger current after the book it nets
    to moved, and one blind to either artifact would call the family
    current with that file deleted."""
    import hashlib

    def digest(path):
        return (hashlib.sha256(path.read_bytes()).hexdigest()[:16]
                if path.exists() else "absent")

    gid = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()[:16]
    return f"{gid} {digest(GUEST)} {digest(OUT)} {digest(PRICES)}"


def write_stamp():
    STAMP.parent.mkdir(parents=True, exist_ok=True)
    STAMP.write_text(stamp_id() + "\n")


def ensure():
    """Regenerate unless generator, guest AND both artifacts match the
    stamp — the artifacts are DERIVED, never committed (maintainer,
    2026-08-24)."""
    if (OUT.exists() and PRICES.exists() and STAMP.exists()
            and STAMP.read_text().strip() == stamp_id()):
        return False
    generate()
    write_stamp()
    return True


def generate():
    rng = Lcg(SEED)
    span = dates()

    the_book = book()
    accounts = list(the_book)
    holdings = {a: {t: q for t, q, _ in the_book[a][1]} for a in accounts}
    anchors = {t: cents for a in accounts for t, _, cents in the_book[a][1]}
    universe = list(anchors)

    # Backward walk per ticker: from the anchor, step at most 1.4% a
    # day, floored at 5% of the anchor so nothing goes absurd.
    prices = {}
    for ticker, anchor in anchors.items():
        if ticker in FLAT:
            prices[ticker] = [anchor] * DAYS
            continue
        walk = [anchor]
        for _ in range(DAYS - 1):
            step = rng.below(29) - 14  # -14..14 per mille
            prev = walk[-1] * 1000 // (1000 + step)
            walk.append(max(prev, anchor // 20))
        prices[ticker] = list(reversed(walk))

    # THE DENSITY DRAW. Every lot draws a side, a share count AND a
    # dividend amount, whichever it turns out to be: a stream that
    # branched on the side would move under the walk below, which
    # rewrites sides.
    draws = []
    for i, day in enumerate(span):
        for account in accounts:
            # A quiet day for this account, so per-day row counts vary.
            if rng.below(5) == 0:
                continue
            for _ in range(1 + rng.below(LOTS)):
                ticker = universe[rng.below(len(universe))]
                side = ("buy", "sell", "div")[rng.below(3)]
                qty = 1 + rng.below(LOT)
                amount = (1 + rng.below(90)) * 25  # cents
                draws.append((day, account, ticker, side, qty, amount,
                              prices[ticker][i]))
    if len(draws) < ROWS:
        raise SystemExit(
            f"gen-market: the walk produced {len(draws)} rows, fewer than the "
            f"declared {ROWS} — raise LOTS or DAYS")
    draws = draws[-ROWS:]

    # THE POSITION WALK, over the retained rows alone. Each pair's LAST
    # lot is its settling lot: whatever squares that position with the
    # book, or a dividend when the walk already arrived there.
    settle = {}
    for at, d in enumerate(draws):
        settle[(d[1], d[2])] = at
    orphans = [f"{a}/{t}" for a in accounts for t in universe
               if (a, t) not in settle]
    if orphans:
        raise SystemExit(
            "gen-market: no lot in the retained window for " +
            ", ".join(orphans) + " — that pair could never be settled "
            "against the book, so the ledger would not net to it: raise "
            "ROWS or LOTS")

    held = {(a, t): 0 for a in accounts for t in universe}
    rows = []
    for at, (day, account, ticker, side, qty, amount, price) in enumerate(draws):
        target = holdings[account].get(ticker, 0)
        have = held[(account, ticker)]
        if at == settle[(account, ticker)]:
            short = target - have
            side = "buy" if short > 0 else "sell" if short < 0 else "div"
            qty = abs(short)
        elif side == "buy":
            room = target + BAND - have
            # No room left, so the lot goes the other way rather than
            # being a buy of nothing.
            side, qty = ("buy", min(qty, room)) if room > 0 else ("sell", min(qty, have))
        elif side == "sell":
            # Nothing held: the same flip, mirrored. Positions never go
            # short, which is what keeps every settling lot small.
            side, qty = ("sell", min(qty, have)) if have > 0 else ("buy", min(qty, target + BAND))
        if side == "div":
            qty, total = 0, amount
        else:
            total = qty * price
            held[(account, ticker)] = have + (qty if side == "buy" else -qty)
        rows.append((day, account, ticker, side, qty, price, total))

    for account in accounts:
        for ticker in universe:
            want = holdings[account].get(ticker, 0)
            if held[(account, ticker)] != want:
                raise SystemExit(
                    f"gen-market: {account}/{ticker} nets to "
                    f"{held[(account, ticker)]} and the book holds {want} — "
                    "the settling lot did not settle (this is the invariant "
                    "the whole generator exists to hold)")

    lines = ["date,account,ticker,side,qty,price_cents,total_cents"]
    for day, account, ticker, side, qty, price, total in rows:
        lines.append(f"{day},{account},{ticker},{side},{qty},{price},{total}")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    print(f"{OUT}: {len(rows)} transactions, {OUT.stat().st_size} bytes")

    # THE HISTORY, the same walk one column over: every day and every
    # ticker, so a chart reads a series rather than reconstructing one
    # out of whatever days happened to trade.
    for ticker, anchor in anchors.items():
        if prices[ticker][-1] != anchor:
            raise SystemExit(
                f"gen-market: {ticker}'s history ends at {prices[ticker][-1]} "
                f"and the book prices it at {anchor} — the last day of "
                "history IS the dashboard's present, and a chart drawn off "
                "this file would end somewhere the dashboard does not")
    history = ["date,ticker,price_cents"]
    for i, day in enumerate(span):
        for ticker in sorted(universe):
            history.append(f"{day},{ticker},{prices[ticker][i]}")
    PRICES.write_bytes(("\n".join(history) + "\n").encode("ascii"))
    print(f"{PRICES}: {len(span)} days x {len(universe)} tickers, "
          f"{PRICES.stat().st_size} bytes")


if __name__ == "__main__":
    import sys
    if "--ensure" in sys.argv:
        print("regenerated" if ensure() else "current (stamp matches)")
    else:
        generate()
        if "KAYA_GEN_MARKET_DIR" not in os.environ:
            write_stamp()
