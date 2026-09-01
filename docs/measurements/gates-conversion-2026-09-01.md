# gates.sh -> python (runner conversion, the last item)

The sweep driver, last by the plan's own ordering
(docs/runner-conversion-plan.md §4 item 4) — converted only once
every lane it drives was proven stable on python. The shell body was
already a python heredoc behind a wrapper, so this crossing is
tranche two's build-id shape: the heredoc becomes tools/gates.py on
the prelude, GATES / EXCLUDED / BUILD are importable module data
under a variable-status main() and a main guard (no mid-body
exit(0), per check-python's own rule), and gates.sh is the pinned
shim.

## Zero re-teach, by construction

The consumers already read DATA: check-gates and check-keyed consume
`gates.sh --list`'s JSON, the lanes call `--fingerprint` and the
sweep through the shim path, and check-gates' delegation clause pins
the "tools/gates.sh" spelling in the runners — all unchanged. The
census/EXCLUDED table is importable python for any future consumer
that wants the module instead of the JSON.

## The riders (same tree, old body materialized from git)

- `--fingerprint`: IDENTICAL (5c8aa26b6b77671a) — the first
  comparison was invalid and instructive: captured before the
  crossing, it necessarily differed, because the keyed input sets
  cover tools/ and the crossing itself moved them. Re-run with the
  old heredoc extracted from git HEAD and driven on the SAME tree.
- `--list`: byte-identical (10,090 bytes).
- `--selftest`: output byte-identical, both rc 0 — the four count
  refusals (under-run via the Truncated iterator, one failing gate,
  missing script, all-green) fire the same way.
- One stated deviation: the unknown-argument usage message goes to
  stderr with rc 1 (the heredoc's sys.exit(string) printed to stderr
  with rc 1 as well; behavior preserved, spelling structured).

## The two sweep "hangs", resolved

The first validation sweep through gates.py went silent at check-keyed
(31/50) with 30 gates having used 208s of compute against ~25 minutes
of wall, the same shape as the previous night's silence at
check-sugar-surface — both gates clean on standalone reproduction,
no processes left behind, no stall the armed sampler ever saw. The
cause was neither gate and neither driver: the laptop lid was closed
and THE MACHINE SLEPT mid-sweep, the monitor's timeout then killing
the suspended run. The stage-4a record's "transient, recorded" entry
is superseded by this — one cause, two sightings, zero code
findings.

## Record

- Full sweep through gates.py, machine awake: 50/50.
- Closing matrix, first attempt: ios and android PASS; three reds —
  check-ledger refusing THIS conversion's own ledger paragraph (the
  calibrated whole-entry word "COMPLETE" under an unstruck headline;
  the gate did its exact job on my prose, reworded), the windows
  ranges_rust leg ("0 matches" wanted "3 matches", first of its
  shape, joining the sightings list), and portfolio-python-wayland's
  fold assertion RECURRING — same sentence as eight hours earlier,
  which by the recorded rule promoted it to a ledger WATCH entry
  with its instrument-next-time instruction.
- Closing matrix, the record run: ALL PASS, 1,390 legs — mac
  336s/349, linux 386s/604, windows 392s/201, ios 452s/113, android
  221s/123, the gate sweep 50/50 through gates.py inside it, 589s
  wall — the fastest matrix of the whole conversion stretch, every
  lane well under its ceiling.
