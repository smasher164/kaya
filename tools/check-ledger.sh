#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# THE LEDGER MAY NOT DISAGREE WITH ITSELF. A ledger entry is read the
# way a diagnostic is read: whoever reads it next acts on the sentence.
#
#   tools/check-ledger.sh              check docs/deferred.md
#   tools/check-ledger.sh <path>       check some other copy — THE TEST
#                                      SEAM, how the watched negatives
#                                      run against a COPY
#
# TWO CLAUSES.
#
#   A. An UNSTRUCK headline whose entry carries an ENTRY-LEVEL TERMINAL
#      RESOLUTION (the measured shape: a present-tense "GAP —" over a
#      body recording COMPLETE three weeks earlier).
#   B. A STRUCK headline with no resolution note — a closed entry and no
#      record of where the work went.
#
# TWO SYNTAXES, ONE RULE. A BULLET ENTRY is a `- ` at column 0; a
# SECTION ENTRY is a `## `/`### ` heading over a prose body. A section is
# closed in its heading two ways, both in the file: struck, and prefixed
# `SOLVED:`. Both must read as closed to clause A and both owe clause B
# a dated note.
#
# FOUR HEADINGS ARE NOT ENTRIES — the file's taxonomy, whose bodies are
# lists of bullet entries read one at a time. They are named in
# ORGANIZING below and their presence is ASSERTED, because a named
# exemption that can rot silently is worse than none. Everything else at
# `##` or deeper is an entry BY DEFAULT, and that default points the
# safe way.
#
# THE DISCRIMINATOR IS THE WHOLE PROBLEM. Entries legitimately mix a
# finished slice with an open remainder, so LANDED, FIXED and CLOSED
# cannot carry the rule — all three appear slice-scoped in unstruck
# entries ("DEPTH SLICE LANDED", "FIXED FOR GO AND RUST", "CLOSED …
# for the remaining five"). COMPLETE can: this ledger reserves it for a
# whole-entry verdict. The second recognized shape is a scoped-sounding
# word corroborated by a full five-lane result on the same line
# (`CLOSED … matrix ALL PASS`).
#
# THE DECLARED LIMITS. An entry that records itself with a bare
# `CLOSED <date>` and is never struck goes unflagged; the exits are to
# strike it or to write a whole-entry verdict, NOT to widen the
# vocabulary while those slice-scoped spellings live in the file. And
# SUB-BULLETS are a different grammar: ENTRY LEVEL for a section is its
# heading plus the column-0 lines that are neither bullets nor a
# bullet's continuation, which is what keeps the depth-stub sections
# open (self-test N4b is that shape, watched NOT firing).
#
# THE CENSUS DISCIPLINE (check-gates, tpl-surfaces): both syntaxes have
# a floor, and a SECOND, deliberately different reader counts the same
# two things off the lines. The two must agree — they do so by
# construction today, and the refusal exists so they cannot silently
# STOP agreeing. Every clause is watched failing on every run, against
# the real bytes doctored in memory, with the count printed.
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

HEADING = re.compile(r"^(#{2,6}) +(\S.*)$")

# The ledger's taxonomy, not its entries. Naming them is the exemption;
# asserting they are still present stops the list rotting into a skip.
ORGANIZING = (
    "Next milestones",
    "Protocol / core",
    "Bindings / ergonomics",
    "Testing / infrastructure",
)


def organizing(head):
    m = HEADING.match(head)
    return bool(m) and m.group(2).startswith(ORGANIZING)


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


def sections(text):
    """Section-style entries: a `## `/`### ` heading and its body, up to
    the next heading of any level. The four ORGANIZING headings are the
    file's taxonomy and are not entries; everything else at that depth
    is one."""
    out, cur = [], None
    for n, line in enumerate(text.split("\n"), 1):
        if HEADING.match(line):
            if cur:
                out.append(cur)
            cur = None if organizing(line) else {"at": n, "lines": [(n, line)]}
        elif cur is not None:
            cur["lines"].append((n, line))
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


def section_level(sec):
    """The same distinction one indentation level out. Under a section
    heading a SUB-ITEM is a bullet at column 0 (`- **DEPTH STUB: …**`)
    and its continuations are indented 2+; the section's own lines are
    the heading and the column-0 prose between and after those bullets.
    Indented blocks that follow no bullet — the ledger's measurement
    tables — are the section's own and are kept."""
    out, in_sub = [], False
    for n, line in sec["lines"]:
        if re.match(r"^ *- ", line):
            in_sub = True
            continue
        if line.strip() == "":
            continue
        if re.match(r"^  ", line):
            if in_sub:
                continue
        else:
            in_sub = False
        out.append((n, line))
    return out


# The strike must OPEN the headline. A strike further in is a struck
# PHRASE inside a live headline and says nothing about the entry.
STRUCK = re.compile(r"^- (?:\*\*)?~~")

# The same, one syntax over, plus the `SOLVED:` heading prefix.
SEC_STRUCK = re.compile(r"^#{2,6} +(?:\*\*)?~~")
SEC_SOLVED = re.compile(r"^#{2,6} +(?:\*\*)?SOLVED\b")

# The ledger's whole-entry verdict, in the two shapes it is written.
TERMINAL_WORD = re.compile(r"\bCOMPLETE\b")
SCOPED_WORD = re.compile(r"\b(?:CLOSED|FIXED|RESOLVED|SWEPT)\b[^.]{0,40}\d{4}-\d{2}-\d{2}")
FULL_MATRIX = re.compile(r"ALL PASS")

# A resolution note: one of the ledger's closing words with its date.
# Clause B asks whether a note EXISTS, not how final it is.
RESOLUTION = re.compile(
    r"\b(?:LANDED|CLOSED|FIXED|COMPLETE|COMPLETED|DONE|RESOLVED|REVERSED"
    r"|ANSWERED|SHIPPED|SWEPT|SUPERSEDED|WITHDRAWN)\b[^.]{0,60}?\d{4}-\d{2}-\d{2}"
)

# CLAUSE C's live phrases: a CLOSED entry whose body still claims open
# work. Measured 2026-08-19 — six instances in one triage, including a
# "STILL OPEN" paragraph describing work that had shipped, under a
# correctly-struck headline where no skim ever looks. The phrase is
# legal when the same line or the next POINTS at where the work went
# (a promotion, its own entry, a doc) — the honest pointer form.
LIVE_CLAIM = re.compile(
    r"STILL OPEN|is not done|not done yet|never landed|did NOT land"
    r"|remains unbuilt|filed rather than done", re.I)
# The honest forms a closed entry may keep a live phrase in, measured
# off the eight instances the clause's first run found: a promotion, a
# named entry or file, a designed-red gate holding the remainder, or a
# stated deliberate hold. Searched over the WHOLE body — a pointer
# anywhere in the entry legalizes its claims, which trades one missed
# mixed case for zero false alarms on the honest shapes.
LIVE_POINTER = re.compile(
    r"PROMOTED|own entry|docs/[a-z0-9-]+\.md|tools/[a-z0-9/.-]+"
    r"|held (?:open )?by|gate that is RED|deliberately|by design", re.I)
TILDE_SPAN_ALL = re.compile(r"~~.*?~~", re.S)


def terminal(line):
    return bool(TERMINAL_WORD.search(line)
                or (SCOPED_WORD.search(line) and FULL_MATRIX.search(line)))


def closed_head(head):
    """Does the headline itself say the work is done? A struck bullet, a
    struck heading, or a `SOLVED:` heading."""
    return bool(STRUCK.match(head) or SEC_STRUCK.match(head)
                or SEC_SOLVED.match(head))


def findings(text):
    """Every self-disagreement in `text`, as (clause, entry, detail).

    One function for the real file and for every doctored copy, so a
    self-test cannot pass against a code path the run does not use. Both
    syntaxes go through it, so a shape that would be caught in a bullet
    is caught in a section and vice versa — one rule, two spellings."""
    out = []
    units = ([(e, entry_level(e)) for e in entries(text)]
             + [(s, section_level(s)) for s in sections(text)])
    for unit, body in units:
        at, head = unit["lines"][0]
        if closed_head(head):
            joined = " ".join(line.strip() for _, line in body)
            if not RESOLUTION.search(joined):
                out.append(("B", at, head, body[-1][0] if body else at, None))
            # STRIKE PARITY ACROSS LINES: a `~~` span can open on one
            # line and close lines later, and a per-line strip reads its
            # middle as live text — two of the first run's eight false
            # candidates were exactly that.
            whole = "\n".join(line for _, line in body)
            if not LIVE_POINTER.search(TILDE_SPAN_ALL.sub("", whole)):
                inside = False
                for n, line in body:
                    scan = line
                    if inside:
                        if "~~" not in line:
                            continue
                        scan = line.split("~~", 1)[1]
                        inside = False
                    scan = re.sub(r"~~.*?~~", "", scan)
                    if scan.count("~~"):
                        scan = scan.split("~~", 1)[0]
                        inside = True
                    if LIVE_CLAIM.search(scan):
                        out.append(("C", at, head, n, line))
            continue
        for n, line in body:
            if terminal(line):
                out.append(("A", at, head, n, line))
                break
    return sorted(out, key=lambda f: f[1])


def report(clause, at, head, n, line):
    short = head[:96].rstrip()
    who = target if str(target) != str(root / "docs/deferred.md") else "docs/deferred.md"
    kind = "section entry" if HEADING.match(head) else "entry"
    if clause == "A":
        where = "the headline itself" if n == at else f"line {n}"
        fail(f"{who} {kind} at line {at} disagrees with itself — the "
             f"headline is NOT struck through but the entry records a terminal "
             f"resolution.\n"
             f"    line {at}: {short}\n"
             f"    {where}: {line.strip()[:96]}\n"
             f"    Strike the headline with its resolution and sweep the "
             f"entry's KEY nouns through docs/ and the code comments, or say "
             f"in the entry what is still open. A headline is what the next "
             f"reader believes.")
    elif clause == "C":
        fail(f"{who} {kind} at line {at} is closed but its body still claims "
             f"LIVE work with no pointer to where it went.\n"
             f"    line {at}: {short}\n"
             f"    line {n}: {line.strip()[:96]}\n"
             f"    Either the claim is stale — strike it with its resolution — "
             f"or the work is real: promote it to its own entry and say so "
             f"here (PROMOTED <date> / its own entry / a docs/ path). A live "
             f"claim inside a closed entry is invisible to every skim.")
    else:
        last = f"{at}-{n}" if n and n != at else f"{at}"
        how = ("struck through or marked SOLVED:" if kind == "section entry"
               else "struck through")
        fail(f"{who} {kind} at line {at} is {how} with no "
             f"resolution note — nothing in it says where the work went.\n"
             f"    line {at}: {short}\n"
             f"    entry-level text at {last} carries no closing verdict with a "
             f"date (LANDED/CLOSED/FIXED/COMPLETE/… <date>).\n"
             f"    A closed entry with no record is a closed entry nobody can "
             f"audit.")


# ---------------------------------------------------- 0. the self-tests
#
# A pattern that never matched agrees with everything, so each clause is
# watched failing FIRST against the real bytes of the real ledger,
# doctored in memory, with the count printed (docs/traps.md).

if not target.is_file():
    sys.exit(f"check-ledger: {target} does not exist")
text = target.read_text(encoding="utf-8")
all_entries = entries(text)
all_sections = sections(text)
struck = [e for e in all_entries if STRUCK.match(e["lines"][0][1])]
open_ = [e for e in all_entries if not STRUCK.match(e["lines"][0][1])]
sec_closed = [s for s in all_sections if closed_head(s["lines"][0][1])]
sec_open = [s for s in all_sections if not closed_head(s["lines"][0][1])]

# N1 — CLAUSE A: an unstruck present-tense headline over a body that
# says the work is done. Appended to a COPY, never to the file.
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

# N1b — THE DISCRIMINATOR from the other side: a landed depth slice
# with the entry's own remainder open. If this fires the gate is about
# to flag half the ledger and will be turned off rather than heeded.
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

# N4 — CLAUSE A, SECTION SYNTAX: the same shape as a heading over a
# body that records the work finished.
SYNTH_SEC_A = """
## GAP — the selftest widget cannot be constructed (selftest)
KEY: selftest widget, section census

As found, nothing in crates/ builds one, so an app asking for it gets
nothing at all. COMPLETE 2026-08-17, matrix ALL PASS at 999 legs.
"""
sec_doctored = text + SYNTH_SEC_A
sec_grew = len(sections(sec_doctored)) - len(all_sections)
print(f"check-ledger: self-test N4 appended 1 unstruck-heading SECTION entry "
      f"with a terminal body to a copy, parser saw {sec_grew} new section(s)")
if sec_grew != 1:
    fail("self-test N4: the appended section was not parsed as one new section "
         "entry — the section parser is not reading what this gate thinks")
else:
    hits = [f for f in findings(sec_doctored) if f[0] == "A"]
    if not any("selftest widget" in f[2] for f in hits):
        fail("self-test N4: a section heading over a COMPLETE body was not "
             "flagged — clause A does not reach the section syntax")

# N4b — THE SECTION DISCRIMINATOR: an open section whose SUB-BULLETS
# carry landed slices and whole-matrix results. If section level leaked
# one sub-bullet, three real sections would go red at once.
SYNTH_SEC_NOT_A = """
## Selftest scene's depth stubs (mid-flight, closes with the fan-out)

The depth landed 2026-08-17: spec + the core + the Rust binding + the
scene, mac only. Two backends refuse through the depth-stub helper:

- **DEPTH STUB: selftest on winui** — the windows runner wires no legs.
- ~~**DEPTH STUB: selftest on gtk**~~ — CLOSED 2026-08-17, matrix ALL PASS.
"""
sec_mixed = text + SYNTH_SEC_NOT_A
print("check-ledger: self-test N4b appended 1 open section over a struck "
      "sub-bullet carrying a whole-matrix result, parser saw "
      f"{len(sections(sec_mixed)) - len(all_sections)} new section(s)")
if any("Selftest scene" in f[2] for f in findings(sec_mixed)):
    fail("self-test N4b: an open section whose SUB-BULLET records a closed "
         "depth stub was flagged — section level is leaking sub-bullets, and "
         "every depth-stub section in the ledger is about to go red")

# N5 — CLAUSE B, SECTION SYNTAX. A real closed section heading (struck,
# or the ledger's `SOLVED:` spelling) with its resolution note deleted
# from the section's own lines.
if not sec_closed:
    fail("self-test N5 impossible: the ledger has no closed section heading, so "
         "clause B is measuring nothing over the section syntax")
else:
    s_victim = sec_closed[0]
    s_at, s_head = s_victim["lines"][0]
    lines = text.split("\n")
    span = [n for n, _ in section_level(s_victim)]
    subs = 0
    for n in span:
        stripped, k = RESOLUTION.subn("<resolution note deleted by selftest>",
                                      lines[n - 1])
        lines[n - 1] = stripped
        subs += k
    print(f"check-ledger: self-test N5 deleted the resolution note from the "
          f"closed section at line {s_at}, {subs} substitution(s)")
    if subs < 1:
        fail(f"self-test N5 applied NO substitution — the closed section at "
             f"line {s_at} has no resolution note as written, so clause B is "
             f"not reading what it thinks over sections")
    else:
        hits = [f for f in findings("\n".join(lines))
                if f[0] == "B" and f[1] == s_at]
        if not hits:
            fail(f"self-test N5: the closed section at line {s_at} lost its "
                 f"resolution note and was not flagged — clause B does not "
                 f"reach the section syntax")

# N3/N6 — THE CENSUS REFUSALS. A reader that parsed almost nothing must
# refuse a verdict rather than agree with everything, and so must a pair
# of readers that stopped agreeing about what is in the file.
FLOOR_ENTRIES, FLOOR_STRUCK, FLOOR_OPEN = 40, 5, 5
FLOOR_SECTIONS, FLOOR_SEC_CLOSED = 10, 2


def lexical(text):
    """The SECOND reader. Deliberately not the parser above: it counts
    entry heads straight off the lines with no state at all, so a
    stateful walk that swallowed an entry — or a syntax one reader
    learns and the other does not — shows up as a disagreement instead
    of as a quietly smaller census."""
    lines = text.split("\n")
    bullets = sum(1 for l in lines if re.match(r"^- ", l))
    heads = [l for l in lines if HEADING.match(l)]
    return bullets, sum(1 for l in heads if not organizing(l))


def census(es, secs, text):
    s = [e for e in es if STRUCK.match(e["lines"][0][1])]
    o = [e for e in es if not STRUCK.match(e["lines"][0][1])]
    sc = [x for x in secs if closed_head(x["lines"][0][1])]
    if len(es) < FLOOR_ENTRIES or len(s) < FLOOR_STRUCK or len(o) < FLOOR_OPEN:
        return (f"read {len(es)} top-level entries ({len(s)} struck, {len(o)} "
                f"open) — below the floor of {FLOOR_ENTRIES}/{FLOOR_STRUCK}/"
                f"{FLOOR_OPEN}. A census that read almost nothing agrees with "
                f"everything, so this is a REFUSAL, not a pass: either the "
                f"ledger's bullet shape moved and this parser went blind, or "
                f"the file handed to it is not the ledger.")
    if len(secs) < FLOOR_SECTIONS or len(sc) < FLOOR_SEC_CLOSED:
        return (f"read {len(secs)} section entries ({len(sc)} closed in their "
                f"heading) — below the floor of {FLOOR_SECTIONS}/"
                f"{FLOOR_SEC_CLOSED}. The section syntax is where this gate was "
                f"blind once already, so reading too few of them is a REFUSAL: "
                f"either the heading shape moved, or ORGANIZING below has grown "
                f"to swallow real entries.")
    missing = [name for name in ORGANIZING
               if not any(organizing(l) and HEADING.match(l).group(2)
                          .startswith(name) for l in text.split("\n")
                          if HEADING.match(l))]
    if missing:
        return (f"the organizing headings {missing} are named as NOT entries "
                f"and are not in the file. A named exemption that has rotted is "
                f"worse than none — it skips whatever now sits at that heading. "
                f"Either the taxonomy was renamed (fix ORGANIZING), or this is "
                f"not the ledger.")
    lex_bullets, lex_secs = lexical(text)
    if (lex_bullets, lex_secs) != (len(es), len(secs)):
        return (f"the two readers disagree: the parser found {len(es)} bullet "
                f"entries and {len(secs)} section entries, the line-oriented "
                f"reader found {lex_bullets} and {lex_secs}. One of them has "
                f"learned a shape the other has not, which is exactly how the "
                f"section syntax went unread for a day — so this is a REFUSAL "
                f"until they are put back in step.")
    return None


tiny_text = "\n".join(text.split("\n")[:30])
tiny = entries(tiny_text)
tiny_secs = sections(tiny_text)
refusal = census(tiny, tiny_secs, tiny_text)
print(f"check-ledger: self-test N3 ran the census over the ledger's first 30 "
      f"lines, {len(tiny)} entr(y|ies) and {len(tiny_secs)} section(s) parsed "
      f"-> {refusal.split(' — ')[0] if refusal else 'ACCEPTED'}")
if refusal is None:
    fail("self-test N3: the census accepted a 30-line fragment — the floor "
         "refusal is decorative")

# N3b — the SECTION floor, which N3 can never reach: a fragment small
# enough to fail the bullet floor fails it first. So: the real file with
# every non-organizing heading LINE deleted.
headless = "\n".join(l for l in text.split("\n")
                     if not (HEADING.match(l) and not organizing(l)))
h_entries, h_secs = entries(headless), sections(headless)
h_refusal = census(h_entries, h_secs, headless)
print(f"check-ledger: self-test N3b deleted every section heading, "
      f"{len(all_sections)} -> {len(h_secs)} section(s) with "
      f"{len(h_entries)} bullet entries left standing -> "
      f"{h_refusal.split(' — ')[0] if h_refusal else 'ACCEPTED'}")
if len(h_secs) >= len(all_sections):
    fail("self-test N3b removed no section — the perturbation did not apply")
elif h_refusal is None or "section entries" not in h_refusal:
    fail("self-test N3b: a ledger with no section entries at all was accepted "
         "(or refused for some other reason) — the section floor is decorative")

# N6 — the two-reader refusal, driven once. The structural counts are
# the REAL ones; the text handed to the second reader has one section
# heading deleted, so the two disagree by exactly one.
sec_heads = [n for n, l in enumerate(text.split("\n"), 1)
             if HEADING.match(l) and not organizing(l)]
if not sec_heads:
    fail("self-test N6 impossible: no section heading to delete")
else:
    lines = text.split("\n")
    cut = sec_heads[0]
    thinned = "\n".join(lines[:cut - 1] + lines[cut:])
    before = lexical(text)[1]
    after = lexical(thinned)[1]
    print(f"check-ledger: self-test N6 deleted the section heading at line "
          f"{cut}, second reader went {before} -> {after} section(s)")
    if after != before - 1:
        fail(f"self-test N6 removed no section from the second reader's count "
             f"({before} -> {after}) — the perturbation did not apply and the "
             f"agreement refusal is measuring nothing")
    elif census(all_entries, all_sections, thinned) is None:
        fail("self-test N6: the census accepted two readers that disagree by a "
             "whole entry — the agreement refusal is decorative")

# N6b — the same for the named exemption: a rename must refuse rather
# than turn four headings into unread entries.
renamed = text.replace("\n## Protocol / core\n", "\n## Protocol and core\n", 1)
print(f"check-ledger: self-test N6b renamed one organizing heading, "
      f"{1 if renamed != text else 0} substitution(s)")
if renamed == text:
    fail("self-test N6b applied NO substitution — `## Protocol / core` is not "
         "in the file as written, so ORGANIZING is not naming what it thinks")
elif census(entries(renamed), sections(renamed), renamed) is None:
    fail("self-test N6b: the census accepted a file in which a named "
         "organizing heading is absent — the exemption can rot in silence")

# N7 — CLAUSE C, both directions: a closed entry whose body claims live
# work must be flagged when the claim has no pointer, and must NOT be
# when it points at where the work went.
SYNTH_C_HOT = """
## ~~The selftest pane collapsed correctly~~ (found 2026-08-17)
CLOSED 2026-08-17 with the depth slice. The breadth half is STILL OPEN
and nothing here says where it lives.
"""
SYNTH_C_COLD = """
## ~~The selftest pane collapsed on cue~~ (found 2026-08-17)
CLOSED 2026-08-17 with the depth slice. The breadth half is STILL OPEN
— PROMOTED 2026-08-17 to its own entry below.
"""
hot_hits = [f for f in findings(text + SYNTH_C_HOT) if f[0] == "C"]
cold_hits = [f for f in findings(text + SYNTH_C_COLD) if f[0] == "C"]
base_hits = [f for f in findings(text) if f[0] == "C"]
print(f"check-ledger: self-test N7 appended a closed entry claiming live work, "
      f"hot and behind a pointer -> {len(hot_hits) - len(base_hits)} and "
      f"{len(cold_hits) - len(base_hits)} new finding(s)")
if len(hot_hits) - len(base_hits) != 1:
    fail("self-test N7: a live claim with no pointer inside a closed entry was "
         "not flagged — clause C is vacuous")
if len(cold_hits) != len(base_hits):
    fail("self-test N7: a POINTED live claim was flagged anyway — the honest "
         "pointer form is being punished, and the clause will be turned off "
         "rather than heeded")

# ------------------------------------------------------- 1. the clauses

problem = census(all_entries, all_sections, text)
if problem:
    fail(problem)
else:
    for clause, at, head, n, line in findings(text):
        report(clause, at, head, n, line)

if status == 0:
    shown = "docs/deferred.md" if target == root / "docs/deferred.md" else target
    print(f"check-ledger: OK ({shown}: {len(all_entries)} bullet entries, "
          f"{len(struck)} struck with a resolution note, {len(open_)} open with "
          f"no terminal resolution; {len(all_sections)} section entries, "
          f"{len(sec_closed)} closed in their heading with a resolution note, "
          f"{len(sec_open)} open with no terminal resolution; "
          f"{len(ORGANIZING)} organizing headings skipped by name)")
else:
    print("check-ledger: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)
PY
