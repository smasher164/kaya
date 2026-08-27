# market — the portfolio app's synthetic ledger and price history

- `transactions.csv` — 15,000 transactions across the portfolio book's
  three accounts and six tickers, 2023-10-21 to 2026-08-24, integer
  cents, oldest first. The price walk runs BACKWARD from
  guests/python/portfolio.py's live book, so the last day of history
  meets the dashboard's present; CASH is flat at its anchor, a unit of
  account rather than a walk. The size is DECLARED (gen-market.py's
  `ROWS`) and kept from the recent end: the per-day lot count is a
  draw, so the walk overshoots and the tail is taken. 15,000 is above
  WinUI's measured 12,000-row choke, which is the size row windowing
  exists to make ordinary (docs/virtualization-plan.md §5).
- `prices.csv` — the same walk one column over: 1,096 days x 6 tickers
  of `date,ticker,price_cents`, the WHOLE span (2023-08-25 to
  2026-08-24) rather than the ledger's retained tail, oldest first. It
  is what the dashboard's chart draws (docs/canvas-plan.md §10).

WHY IT IS A SECOND FILE AND NOT A READ OF THE LEDGER. transactions.csv
carries a price on every row, so a history looked derivable from it, and
it is not — measured over the artifact: only 43 of the ledger's 1,033
retained days carry all six tickers, and two tickers' last traded price
sits days short of the anchor (BND 7267 against 7210, NVDA 95913 against
95050). A carry-forward series off the ledger would end where the
dashboard does not.

BOTH TIE TO THE BOOK. The ledger NETS to it (ruled 2026-08-26): for
every account and every
ticker, buys minus sells equal the dashboard's position quantity — zero
where the account holds none — and dividends carry no quantity at all.
The tail decides DENSITY only; positions are walked over the retained
rows, from zero on the first row, so the file is the whole life of every
position and a net over what it contains is the book's. The generator
refuses to write a file that does not tie, and check-assets' C10 nets
this artifact against the guest's BOOK on every run.

The HISTORY ties one column over (2026-08-27): its last day IS the
book's live prices, ticker by ticker, so the chart's right edge is the
money the dashboard shows. The generator refuses to write a history that
ends anywhere else, check-assets' C11 holds the artifact on disk to the
same book, and guests/python/portfolio.py refuses to start against a
history that disagrees.

WHERE THEY CAME FROM: generated, not gathered — no upstream exists;
every byte was written by `python3 tools/gen-market.py`, which
writes it byte-stably (a spelled-out LCG, seed 0x6B617961; no host
randomness, clock, or float ever touches the output). Real market data
is not redistributable; synthetic-and-deterministic is the forcing
app's own doctrine (docs/portfolio-plan.md).

LICENCE: ours, like everything the generator makes (repo licence).

REGENERATE: both CSVs are DERIVED, never committed — `python3
tools/gen-market.py --ensure` regenerates them only when the generator's
own bytes have moved (the stamp lives in target/ and covers the guest
and BOTH artifacts), and the gate sweep's
build step runs that for you. check-assets byte-compares both artifacts
against a fresh regeneration on every run, so a hand-edit or a stale
copy is refused with this command named. Change the shape by editing
the generator, never the CSVs.
