# market — the portfolio app's synthetic transaction ledger

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

IT NETS TO THE BOOK (ruled 2026-08-26): for every account and every
ticker, buys minus sells equal the dashboard's position quantity — zero
where the account holds none — and dividends carry no quantity at all.
The tail decides DENSITY only; positions are walked over the retained
rows, from zero on the first row, so the file is the whole life of every
position and a net over what it contains is the book's. The generator
refuses to write a file that does not tie, and check-assets' C10 nets
this artifact against the guest's BOOK on every run.

WHERE THEY CAME FROM: generated, not gathered — no upstream exists;
every byte was written by `python3 tools/gen-market.py`, which
writes it byte-stably (a spelled-out LCG, seed 0x6B617961; no host
randomness, clock, or float ever touches the output). Real market data
is not redistributable; synthetic-and-deterministic is the forcing
app's own doctrine (docs/portfolio-plan.md).

LICENCE: ours, like everything the generator makes (repo licence).

REGENERATE: the CSV is DERIVED, never committed — `python3
tools/gen-market.py --ensure` regenerates it only when the generator's
own bytes have moved (the stamp lives in target/), and the gate sweep's
build step runs that for you. check-assets byte-compares the artifact
against a fresh regeneration on every run, so a hand-edit or a stale
copy is refused with this command named. Change the shape by editing
the generator, never the CSV.
