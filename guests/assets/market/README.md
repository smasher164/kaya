# market — the portfolio app's synthetic transaction ledger

- `transactions.csv` — 15,000 transactions across the portfolio book's
  three accounts and five tickers, 2023-10-12 to 2026-08-24, integer
  cents, oldest first. The price walk runs BACKWARD from
  guests/python/portfolio.py's live book, so the last day of history
  meets the dashboard's present. The size is DECLARED (gen-market.py's
  `ROWS`) and kept from the recent end: the per-day lot count is a
  draw, so the walk overshoots and the tail is taken. 15,000 is above
  WinUI's measured 12,000-row choke, which is the size row windowing
  exists to make ordinary (docs/virtualization-plan.md §5).

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
