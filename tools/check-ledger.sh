#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# THE LEDGER MAY NOT DISAGREE WITH ITSELF.
#
#   tools/check-ledger.sh              check docs/deferred.md
#   tools/check-ledger.sh <path>       check some other copy of it —
#                                      THE TEST SEAM. It is how the
#                                      watched negatives run against a
#                                      COPY instead of the real file,
#                                      and how this gate was calibrated
#                                      against `git show
#                                      0375e3e:docs/deferred.md`.
#
# THE DEFECT THIS EXISTS FOR, measured 2026-08-17. Two top-level entries
# carried headlines in the present tense — "GAP — the stall diagnostic
# DESIGN promises is not implemented", "GAP — a kaya app cannot do
# background work" — while their own bodies, twenty lines down, recorded
# "COMPLETE 2026-07-28, matrix ALL PASS at 808 legs" and "BREADTH SWEEP
# COMPLETE 2026-08-01". Both had been finished for three weeks. A survey
# read the HEADLINES, believed them, and reported a solved problem as the
# largest open item in the project. A ledger entry is read the way a
# diagnostic is read: whoever reads it next acts on the sentence.
#
# TWO CLAUSES.
#
#   A. An UNSTRUCK headline whose entry carries an ENTRY-LEVEL TERMINAL
#      RESOLUTION. That is the shape above.
#   B. A STRUCK headline with no resolution note. Striking a line
#      through and saying nothing about where the work went leaves the
#      next reader with a closed entry and no record.
#
# THE DISCRIMINATOR IS THE WHOLE PROBLEM, and it is calibrated against
# this file's real shapes rather than guessed. Entries legitimately mix a
# finished slice with an open remainder — "Saving a file" carries "DEPTH
# LANDED: spec + the core's SaveDestination + …" above five open depth
# stubs — so a rule that fired on the ledger's ordinary closing words
# would fire on those and be turned off within a week. Measured over both
# the current file and 0375e3e, at entry level, in unstruck entries:
#
#   DEPTH SLICE LANDED 2026-07-31    a slice, with breadth still open
#   FIXED FOR GO AND RUST 2026-07-28 two languages of nine
#   CLOSED 2026-07-31 for the remaining five   scoped by its own clause
#   CLOSED 2026-08-05 by the completion pass   with a ratification still
#                                              owed to the maintainer
#
# So LANDED, FIXED and CLOSED cannot carry the rule. COMPLETE can: this
# ledger reserves it for a whole-entry verdict, and spells it exactly
# that way where the entry IS closed — `~~**Clipboard**~~ — COMPLETE
# 2026-08-04`. The second recognized shape is a scoped-sounding word
# corroborated by a full five-lane result on the same line (`CLOSED …
# matrix ALL PASS`), which is the ledger's own phrase for "the whole
# matrix went green on this".
#
# AND WHAT THAT MEANS THIS GATE CANNOT SEE, said out loud because a
# guard nobody has bounded is believed past its evidence: an entry that
# finishes and records itself with a bare `CLOSED <date>` and is never
# struck goes unflagged. The exits are to strike the entry (the
# convention in CLAUDE.md) or to write the verdict the way this ledger
# writes a whole-entry verdict. Widening the vocabulary is NOT an exit
# while those four slice-scoped spellings live in the file; a gate that
# fires on half the ledger teaches people to ignore it.
#
# TOP-LEVEL ENTRIES ONLY. Sub-bullets are a different grammar — a depth
# stub struck by its own backend arm, a finding kept for its lesson —
# and the failure class measured was entry-level. That is a declared
# limit, not an oversight.
#
# THE CENSUS DISCIPLINE (check-gates, tpl-surfaces): a reader that found
# implausibly few entries agrees with everything, so this refuses a
# verdict rather than printing one. Both clauses are watched failing on
# every run, against the real bytes doctored in memory, with the
# perturbation count printed — zero substitutions is a FAILED self-test,
# never a passed one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

exec python3 - "$ROOT" "$@" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
if len(args) > 1:
    sys.exit("usage: check-ledger.sh [ledger-path]")
target = pathlib.Path(args[0]) if args else root / "docs/deferred.md"

status = 0


def fail(msg):
    global status
    print(f"check-ledger: {msg}", file=sys.stderr)
    status = 1


# ------------------------------------------------------------- parsing

def entries(text):
    """Top-level entries: a `- ` bullet at column 0, running until the
    next one or until a line that is neither blank nor indented (a
    heading, or the file's own prose between sections)."""
    out, cur = [], None
    for n, line in enumerate(text.split("\n"), 1):
        if re.match(r"^- ", line):
            if cur:
                out.append(cur)
            cur = {"at": n, "lines": [(n, line)]}
        elif cur is not None:
            if line.strip() == "" or line.startswith("  "):
                cur["lines"].append((n, line))
            else:
                out.append(cur)
                cur = None
    if cur:
        out.append(cur)
    return out


def entry_level(entry):
    """The entry's OWN lines — everything not inside a sub-bullet.

    A sub-bullet is `  - ` (or deeper) and its continuations are
    indented 4+. A 2-space line after one is back at entry level. This
    is what makes 'the entry says it is done' different from 'one of its
    sub-items says IT is done', which is most of what the file is."""
    out, in_sub = [], False
    for n, line in entry["lines"]:
        if re.match(r"^ +- ", line):
            in_sub = True
            continue
        if line.strip() == "":
            continue
        if re.match(r"^    ", line):
            if in_sub:
                continue
        else:
            in_sub = False
        out.append((n, line))
    return out


# `- ~~X~~ — LANDED …` and `- **~~X~~ REVERSED …**` are both struck
# headlines; the strike opens the headline in each. A strike further in
# is a struck PHRASE inside a live headline and says nothing about the
# entry.
STRUCK = re.compile(r"^- (?:\*\*)?~~")

# The ledger's whole-entry verdict, in the two shapes it is written.
TERMINAL_WORD = re.compile(r"\bCOMPLETE\b")
SCOPED_WORD = re.compile(r"\b(?:CLOSED|FIXED|RESOLVED|SWEPT)\b[^.]{0,40}\d{4}-\d{2}-\d{2}")
FULL_MATRIX = re.compile(r"ALL PASS")

# A resolution note: one of the ledger's closing words with the date it
# closed on. SWEPT is in the list because the file uses it
# (`~~**`split` and `listdetail` are rust-only…**~~ — SWEPT 2026-07-27`)
# and clause B is about whether a note EXISTS, not about how final it is.
RESOLUTION = re.compile(
    r"\b(?:LANDED|CLOSED|FIXED|COMPLETE|COMPLETED|DONE|RESOLVED|REVERSED"
    r"|ANSWERED|SHIPPED|SWEPT|SUPERSEDED|WITHDRAWN)\b[^.]{0,60}?\d{4}-\d{2}-\d{2}"
)


def terminal(line):
    return bool(TERMINAL_WORD.search(line)
                or (SCOPED_WORD.search(line) and FULL_MATRIX.search(line)))


def findings(text):
    """Every self-disagreement in `text`, as (clause, entry, detail).

    One function for the real file and for every doctored copy, so a
    self-test cannot pass against a code path the run does not use."""
    out = []
    for entry in entries(text):
        at, head = entry["lines"][0]
        body = entry_level(entry)
        if STRUCK.match(head):
            joined = " ".join(line.strip() for _, line in body)
            if not RESOLUTION.search(joined):
                out.append(("B", at, head, body[-1][0], None))
            continue
        for n, line in body:
            if terminal(line):
                out.append(("A", at, head, n, line))
                break
    return out


def report(clause, at, head, n, line):
    short = head[:96].rstrip()
    who = target if str(target) != str(root / "docs/deferred.md") else "docs/deferred.md"
    if clause == "A":
        where = "the headline itself" if n == at else f"line {n}"
        fail(f"{who} entry at line {at} disagrees with itself — the "
             f"headline is NOT struck through but the entry records a terminal "
             f"resolution.\n"
             f"    line {at}: {short}\n"
             f"    {where}: {line.strip()[:96]}\n"
             f"    Strike the headline with its resolution and sweep the "
             f"entry's KEY nouns through docs/ and the code comments, or say "
             f"in the entry what is still open. A headline is what the next "
             f"reader believes.")
    else:
        last = f"{at}-{n}" if n and n != at else f"{at}"
        fail(f"{who} entry at line {at} is struck through with no "
             f"resolution note — nothing in it says where the work went.\n"
             f"    line {at}: {short}\n"
             f"    entry-level text at {last} carries no closing verdict with a "
             f"date (LANDED/CLOSED/FIXED/COMPLETE/… <date>).\n"
             f"    A struck entry with no record is a closed entry nobody can "
             f"audit.")


# ---------------------------------------------------- 0. the self-tests
#
# Every clause is a pattern match, and a pattern that never matched
# agrees with everything. So each is watched failing FIRST, against the
# real bytes of the real ledger, doctored in memory, with the count
# printed. This is the rule check-tx-liveness and the wayland seat guard
# both learned the hard way (three clauses passed with the guard
# deleted; a pattern that never matched passed vacuously, twice).

if not target.is_file():
    sys.exit(f"check-ledger: {target} does not exist")
text = target.read_text(encoding="utf-8")
all_entries = entries(text)
struck = [e for e in all_entries if STRUCK.match(e["lines"][0][1])]
open_ = [e for e in all_entries if not STRUCK.match(e["lines"][0][1])]

# N1 — CLAUSE A. A synthetic entry in the measured shape: an unstruck
# headline making a present-tense claim over a body that says the work
# is done. Appended to a COPY of the real text, never to the file.
SYNTH_A = """
- **GAP — the selftest widget cannot be constructed.** As found, nothing
  in crates/ builds one, so an app asking for it gets nothing.
  COMPLETE 2026-08-17, matrix ALL PASS at 999 legs across all five lanes.
"""
doctored = text + SYNTH_A
grew = len(entries(doctored)) - len(all_entries)
print(f"check-ledger: self-test N1 appended 1 unstruck-headline entry with a "
      f"terminal body to a copy, parser saw {grew} new entr(y|ies)")
if grew != 1:
    fail("self-test N1: the appended entry was not parsed as one new top-level "
         "entry — the parser is not reading what this gate thinks it reads")
else:
    hits = [f for f in findings(doctored) if f[0] == "A"]
    if not any("selftest widget" in f[2] for f in hits):
        fail("self-test N1: an unstruck headline over a COMPLETE body was not "
             "flagged — clause A is vacuous")

# N1b — THE DISCRIMINATOR, from the other side. The shape clause A must
# NOT fire on: a depth slice recorded as landed, with the entry's own
# remainder still open. If this fires, the gate is about to flag half
# the ledger and will be turned off rather than heeded.
SYNTH_NOT_A = """
- **Selftest breadth** — IN FLIGHT 2026-08-17. DEPTH SLICE LANDED
  2026-08-17: spec + the core + the Rust surface. Matrix ALL PASS at 841
  legs on the depth lane. What is still open:
  - **DEPTH STUB: selftest on winui** — the windows runner wires no legs.
"""
mixed = text + SYNTH_NOT_A
print("check-ledger: self-test N1b appended 1 depth-slice-with-remainder entry "
      f"to a copy, parser saw {len(entries(mixed)) - len(all_entries)} new "
      f"entr(y|ies)")
if any("Selftest breadth" in f[2] for f in findings(mixed) if f[0] == "A"):
    fail("self-test N1b: a DEPTH SLICE LANDED entry with an open remainder was "
         "flagged — the discriminator is too wide and this gate would be noise")

# N2 — CLAUSE B. A struck headline whose resolution note is removed. The
# perturbation is applied to a REAL struck entry's real bytes.
if not struck:
    fail("self-test N2 impossible: the ledger has no struck entry, so clause B "
         "is measuring nothing")
else:
    victim = struck[0]
    v_at, v_head = victim["lines"][0]
    lines = text.split("\n")
    span = [n for n, _ in entry_level(victim)]
    subs = 0
    for n in span:
        stripped, k = RESOLUTION.subn("<resolution note deleted by selftest>",
                                      lines[n - 1])
        lines[n - 1] = stripped
        subs += k
    print(f"check-ledger: self-test N2 deleted the resolution note from the "
          f"struck entry at line {v_at}, {subs} substitution(s)")
    if subs < 1:
        fail(f"self-test N2 applied NO substitution — the struck entry at line "
             f"{v_at} has no resolution note as written, so clause B is not "
             f"reading what it thinks")
    else:
        hits = [f for f in findings("\n".join(lines)) if f[0] == "B" and f[1] == v_at]
        if not hits:
            fail(f"self-test N2: the struck entry at line {v_at} lost its "
                 f"resolution note and was not flagged — clause B is vacuous")

# N3 — THE CENSUS REFUSAL. A reader that parsed almost nothing must
# refuse a verdict rather than agree with everything.
FLOOR_ENTRIES, FLOOR_STRUCK, FLOOR_OPEN = 40, 5, 5


def census(es):
    s = [e for e in es if STRUCK.match(e["lines"][0][1])]
    o = [e for e in es if not STRUCK.match(e["lines"][0][1])]
    if len(es) < FLOOR_ENTRIES or len(s) < FLOOR_STRUCK or len(o) < FLOOR_OPEN:
        return (f"read {len(es)} top-level entries ({len(s)} struck, {len(o)} "
                f"open) — below the floor of {FLOOR_ENTRIES}/{FLOOR_STRUCK}/"
                f"{FLOOR_OPEN}. A census that read almost nothing agrees with "
                f"everything, so this is a REFUSAL, not a pass: either the "
                f"ledger's bullet shape moved and this parser went blind, or "
                f"the file handed to it is not the ledger.")
    return None


tiny = entries("\n".join(text.split("\n")[:30]))
refusal = census(tiny)
print(f"check-ledger: self-test N3 ran the census over the ledger's first 30 "
      f"lines, {len(tiny)} entr(y|ies) parsed -> "
      f"{refusal.split(' — ')[0] if refusal else 'ACCEPTED'}")
if refusal is None:
    fail("self-test N3: the census accepted a 30-line fragment — the refusal is "
         "decorative")

# ------------------------------------------------------- 1. the clauses

problem = census(all_entries)
if problem:
    fail(problem)
else:
    for clause, at, head, n, line in findings(text):
        report(clause, at, head, n, line)

if status == 0:
    shown = "docs/deferred.md" if target == root / "docs/deferred.md" else target
    print(f"check-ledger: OK ({shown}: {len(all_entries)} top-level entries, "
          f"{len(struck)} struck with a resolution note, {len(open_)} open with "
          f"no terminal resolution)")
else:
    print("check-ledger: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)
PY
