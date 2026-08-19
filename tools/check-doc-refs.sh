#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# A PATH THE DOCS NAME MUST BE A PATH THE TREE HAS.
#
#   tools/check-doc-refs.sh                 every tracked .md in the tree
#   tools/check-doc-refs.sh --also PATH     scan one more file BESIDE the
#                                           real set — THE TEST SEAM, so
#                                           the watched negatives plant
#                                           their dead reference in a
#                                           COPY and the real docs are
#                                           never edited to prove a gate
#                                           red.
#
# WHAT COUNTS AS A REFERENCE: a word starting with one of the repo's
# source roots — tools/ crates/ guests/ docs/ swift/ android/ bindings/ —
# backticked or bare. Trailing punctuation and a possessive `'s` end the
# token; a `<placeholder>` right after it makes it a FAMILY name, and
# families are not checked.
#
# A `:123` OR `:123-456` SUFFIX ENDS THE TOKEN AND IS THEN READ: the file
# must exist AND be long enough for the line the sentence points at.
# WHAT IT CATCHES IS THE FILE THAT SHRANK, and only that — an in-range
# line number whose content moved is not catchable this way, and the gate
# does not pretend otherwise.
#
# THREE SHAPES BEYOND THE PLAIN PATH:
#
#   GLOBS — required to match AT LEAST ONE path: a glob that has stopped
#     matching is exactly as dead as a missing file.
#   BRACE GROUPS — `guests/{go/undo/undo.go:309, rust/undo.rs:207, …}`.
#     Expanded and checked member by member. Left alone, the tokenizer
#     would read `swift/undo.swift` out of the middle of one and report a
#     file that was never claimed to exist.
#   ELISIONS — `android/kaya/.../KayaCompose.kt`. NOT exempt: write the
#     path out.
#
# THE HISTORICAL-MENTION CONVENTION, and nothing else — every exemption
# is a place a dead reference can hide:
#
#   1. Inside ~~strikethrough~~ (a struck sentence claims nothing).
#   2. Inside a ``` fenced block (a quote may not be edited to suit a
#      gate).
#   3. Followed by the literal marker `(gone)`, for a live sentence that
#      must name a file the tree no longer has.
#
# In particular a reference is not exempted for being in a "historical"
# document: every doc in docs/ records something that already happened.
#
# THE EXEMPTIONS ARE COUNTED AND PRINTED on every run, and the gate
# REFUSES A VERDICT if the exempt references outnumber the checked ones.
#
# AND ONE CLAUSE OVER EVERY TRACKED FILE, not just the .md set: nothing
# tracked may cite scratchpad/ — a session scratch directory dies on
# reboot, so a comment pointing there points at nothing, sooner or
# later. Measured 2026-08-19: 47 tracked files carried such citations
# and 19 of the cited documents were already dead, replayed out of
# session transcripts to land them (docs/chrome/, docs/styling/,
# docs/probes/). The one legal spelling of a dead scratch path is the
# same `(gone)` marker as above.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

exec python3 - "$ROOT" "$@" <<'PY'
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]

extra = []
while args:
    if args[0] == "--also" and len(args) > 1:
        extra.append(pathlib.Path(args[1]))
        args = args[2:]
    else:
        sys.exit("usage: check-doc-refs.sh [--also PATH]...")
for p in extra:
    # A mistyped seam path would otherwise be SKIPPED and the run would
    # go green about a file it never opened.
    if not p.is_file():
        sys.exit(f"check-doc-refs: --also {p} is not a file")

status = 0


def fail(msg):
    global status
    print(f"check-doc-refs: {msg}", file=sys.stderr)
    status = 1


ROOTS = "tools|crates|guests|docs|swift|android|bindings"
# A repo-relative path token. The leading lookbehind keeps it from
# starting in the middle of a longer path or word; the final class ends
# it before a period, comma, apostrophe or colon, which is how these
# docs actually punctuate a citation.
TOKEN = re.compile(rf"(?<![A-Za-z0-9_/.-])(?:{ROOTS})/[A-Za-z0-9_./*?-]*[A-Za-z0-9_*?]")
BRACE = re.compile(rf"((?:{ROOTS})/)\{{([^}}]*)\}}", re.S)
# The line anchor that follows a path: `:1007` or `:1007-1013`. Read
# immediately after the token, before the exemption markers are looked
# for, so `docs/x.md:12 (gone)` still finds its marker.
LINEREF = re.compile(r":(\d+)(?:-(\d+))?")
FENCE = re.compile(r"^\s*```")
STRIKE = re.compile(r"~~.+?~~", re.S)
GONE = "(gone)"
# The line clause's verdict, named once: the printer below tells the two
# failures apart by it, because they want DIFFERENT fixes — a missing
# file wants the path corrected or struck, an over-length line wants the
# NUMBER corrected.
SHRANK = "the file SHRANK past this citation"


def anchor(text):
    """`:1007-1013` at the head of TEXT -> (suffix, highest line, rest).

    THE HIGHEST of the two, not the first: a range whose END is past the
    file is exactly as dead as one whose start is, and the reader who
    opens it lands somewhere the sentence never meant."""
    m = LINEREF.match(text)
    if not m:
        return None, None, text
    want = max(int(g) for g in m.groups() if g)
    return m.group(0), want, text[m.end():]


def docs():
    """Every tracked .md in the tree — docs/, the two doctrine mirrors,
    DESIGN.md, README.md and the per-directory READMEs (27 files, 502
    references today).

    FOUND, NOT ENUMERATED, which is check-shell's lesson about a listed
    set of directories: a doc in a new place is covered the day it lands
    rather than the day someone remembers this list. git is the tree's
    own answer to what is tracked; the fallback is the doc set proper,
    and if it ever fires the census floor below is what notices."""
    out = subprocess.run(["git", "ls-files", "-z", "*.md"], cwd=root,
                         stdout=subprocess.PIPE, text=True, check=False)
    if out.returncode == 0 and out.stdout.strip("\0"):
        return sorted(root / p for p in out.stdout.split("\0") if p)
    return sorted((root / "docs").glob("*.md")) + sorted(root.glob("*.md"))


def expand_braces(text):
    """`guests/{a/x.go:12, b/y.rs:4}` -> its real member paths.

    Returns (text, groups, members) where members is
    [(line, path, suffix, want)] and the group itself has been BLANKED
    OUT of the text — the tokenizer would otherwise read
    `swift/undo.swift` out of the middle of one and report a file nobody
    ever claimed existed.

    THE MEMBERS CARRY THEIR LINE ANCHORS. 25 of the corpus's 31
    line-anchored references live inside brace groups today, so dropping
    the `:207` here would leave the line clause reading six.

    The blanking keeps the group's newlines. A replacement that swallowed
    them would shift every line number below it in that file, and a
    finding naming the wrong line is worse than no finding at all — the
    reader goes to the line, sees nothing wrong, and stops believing the
    gate."""
    groups = 0
    members = []

    def sub(m):
        nonlocal groups
        groups += 1
        line = text.count("\n", 0, m.start()) + 1
        for item in m.group(2).split(","):
            item = item.strip()
            if not item:
                continue
            head = item.split(":")[0].strip()
            suffix, want, _ = anchor(item[len(head):])
            if head:
                members.append((line, m.group(1) + head, suffix, want))
        return re.sub(r"[^\n]", " ", m.group(0))

    return BRACE.sub(sub, text), groups, members


def scan(path, text):
    """Every reference in one file, as
    (line, token, why-exempt-or-None, suffix-or-None, want-or-None).

    Brace members come back carrying the LINE OF THEIR GROUP, so a dead
    path inside one is reported where a reader will find it."""
    text, groups, members = expand_braces(text)
    struck = [(m.start(), m.end()) for m in STRIKE.finditer(text)]
    out = []
    at = 0
    in_fence = False
    for n, line in enumerate(text.split("\n"), 1):
        start, at = at, at + len(line) + 1
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        for m in TOKEN.finditer(line):
            token = m.group(0)
            # The anchor is consumed BEFORE the exemption markers are
            # looked for, so `tools/gone.sh:40 (gone)` still reads as
            # exempt.
            suffix, want, rest = anchor(line[m.end():])
            why = None
            if in_fence:
                why = "fenced"
            elif any(a <= start + m.start() < b for a, b in struck):
                why = "struck"
            elif GONE in rest[:12]:
                why = "gone-marker"
            elif rest[:1] == "<":
                why = "placeholder"
            out.append((n, token, why, suffix, want))
    # A brace group's members are checked but never exempted: the group
    # is a compact citation, not a quotation.
    out.extend((line, p, None, suffix, want) for line, p, suffix, want in members)
    return out, groups, len(members)


def resolve(token, want=None):
    """None if the reference is good, else the reason it is not."""
    if "..." in token:
        return ("names an ELISION rather than a path — write it out. A `...` "
                "is an abbreviation the reader cannot open")
    if "*" in token or "?" in token:
        try:
            if next(root.glob(token), None) is not None:
                return None
        except (ValueError, IndexError):
            return "is not a glob this gate can resolve"
        return ("is a glob that matches NOTHING in the tree — it named "
                "something once")
    target = root / token
    if not target.exists():
        return "does not exist"
    if want is None:
        return None
    # THE LINE CLAUSE. Only a regular file has lines: a brace member can
    # name a directory, and a `:12` on one is a citation shape this gate
    # cannot read rather than a finding it can make.
    if not target.is_file():
        return None
    try:
        length = len(target.read_text(encoding="utf-8", errors="replace")
                     .splitlines())
    except OSError as exc:
        return f"cannot be read to check its length ({exc})"
    if want > length:
        return (f"exists but has only {length} lines — {SHRANK}, so the "
                f"sentence points at nothing")
    return None


# ------------------------------------------------------ the scan itself

def run(files):
    """(findings, checked, exempt, groups, members, anchored) over a file
    list. `anchored` is how many of the checked references carried a
    `:NNN` the line clause could read."""
    findings, checked, exempt = [], 0, {}
    groups = members = anchored = 0
    for path in files:
        if not path.is_file():
            continue
        refs, g, mem = scan(path, path.read_text(encoding="utf-8"))
        groups += g
        members += mem
        for n, token, why, suffix, want in refs:
            if why:
                exempt[why] = exempt.get(why, 0) + 1
                continue
            checked += 1
            if want is not None:
                anchored += 1
            bad = resolve(token, want)
            if bad:
                try:
                    rel = path.relative_to(root)
                except ValueError:
                    rel = path
                findings.append((str(rel), n, token + (suffix or ""), bad))
    return findings, checked, exempt, groups, members, anchored


# ---------------------------------------------------- 0. the self-tests
#
# Each clause is watched failing against the real bytes of a real doc,
# doctored IN MEMORY, with the substitution count printed. Zero
# substitutions is a failed self-test, never a passed one.

sample = root / "docs" / "HACKING.md"
if not sample.is_file():
    sys.exit("check-doc-refs: docs/HACKING.md is missing — the self-tests below "
             "read it, so nothing here could be trusted")
sample_text = sample.read_text(encoding="utf-8")


def findings_in(text, name="<doctored>"):
    refs, _, _ = scan(pathlib.Path(name), text)
    return [(n, t + (s or ""), resolve(t, want))
            for n, t, w, s, want in refs if not w and resolve(t, want)]


# N1 — a dead path must be reported. Planted into a real doc's real text.
planted = sample_text + "\nSee tools/check-there-is-no-such-file.sh for this.\n"
print(f"check-doc-refs: self-test N1 planted 1 dead path in a copy of "
      f"docs/HACKING.md, {len(findings_in(planted)) - len(findings_in(sample_text))} "
      f"new finding(s)")
if not any("check-there-is-no-such-file" in t for _, t, _ in findings_in(planted)):
    fail("self-test N1: a planted dead path was not reported — the existence "
         "clause is vacuous")

# N2 — a glob that matches nothing must be reported. Perturbed from a
# glob the docs really carry.
globbed, n2 = re.subn(r"tools/scenes/\*\.steps", "tools/scenes/*.stepz",
                      sample_text)
print(f"check-doc-refs: self-test N2 broke a real glob in a copy of "
      f"docs/HACKING.md, {n2} substitution(s)")
if n2 < 1:
    fail("self-test N2 applied NO substitution — docs/HACKING.md does not carry "
         "tools/scenes/*.steps as written, so the glob clause is measuring "
         "nothing")
elif not any("stepz" in t for _, t, _ in findings_in(globbed)):
    fail("self-test N2: a glob matching nothing was not reported — the glob "
         "clause is vacuous")

# N3 — the brace expansion must be LIVE. A member of a real brace group
# is perturbed to a dead path; if the expansion silently stopped
# happening, this comes back green and the paths behind today's groups
# are checked by nobody.
plan = root / "docs" / "sugar-pass-plan.md"
if not plan.is_file():
    fail("self-test N3 impossible: docs/sugar-pass-plan.md is gone and it is "
         "the file carrying a brace group — re-point this self-test")
else:
    plan_text = plan.read_text(encoding="utf-8")
    _, g0, m0 = scan(plan, plan_text)
    broken, n3 = re.subn(r"rust/undo\.rs:135", "rust/undo-NO-SUCH.rs:135",
                         plan_text)
    print(f"check-doc-refs: self-test N3 broke 1 member of a real brace group "
          f"({g0} group(s), {m0} member(s) expanded), {n3} substitution(s)")
    if n3 < 1:
        fail("self-test N3 applied NO substitution — the brace group in "
             "docs/sugar-pass-plan.md is not spelled as this self-test expects")
    elif m0 < 2:
        fail("self-test N3: the expansion produced fewer than 2 members — brace "
             "groups are not being expanded at all")
    elif not any("undo-NO-SUCH" in t for _, t, _ in findings_in(broken)):
        fail("self-test N3: a dead path INSIDE a brace group was not reported — "
             "the expansion is not feeding the existence clause")

# N4 — the exemptions must be exemptions and nothing more. A dead path
# inside ~~strikes~~ and one inside a fence must both be silent; the same
# dead path outside them must not be.
quiet = sample_text + (
    "\n~~tools/check-was-deleted.sh drove this~~\n"
    "\n```\ntools/check-also-deleted.sh --check\n```\n"
    "\ntools/check-third-deleted.sh (gone) drove the old lane.\n")
loud = [t for _, t, _ in findings_in(quiet)]
PLANTED = ("check-was-deleted", "check-also-deleted", "check-third-deleted")
print(f"check-doc-refs: self-test N4 planted 3 dead paths behind the three "
      f"exemptions (struck, fenced, {GONE}), "
      f"{sum(1 for t in loud if any(p in t for p in PLANTED))} of them reported")
for token in PLANTED:
    if any(token in t for t in loud):
        fail(f"self-test N4: {token} is exempt by the convention and was "
             f"reported anyway — the exemption is not being applied")

# N6 — THE LINE CLAUSE, in both of the places a citation can carry a
# line number, and in both directions. A reference past the end of a real
# file must be reported; one INSIDE the file must not, or the clause
# would be an existence check with extra noise.
over = sample_text + "\nSee tools/check-doc-refs.sh:999999 for this.\n"
under = sample_text + "\nSee tools/check-doc-refs.sh:10 for this.\n"
own_len = len((root / "tools" / "check-doc-refs.sh")
              .read_text(encoding="utf-8").splitlines())
print(f"check-doc-refs: self-test N6 cited line 999999 and line 10 of "
      f"tools/check-doc-refs.sh, which has {own_len} lines -> "
      f"{len(findings_in(over)) - len(findings_in(sample_text))} and "
      f"{len(findings_in(under)) - len(findings_in(sample_text))} new finding(s)")
if not any("999999" in t for _, t, _ in findings_in(over)):
    fail("self-test N6: a citation past the end of a real file was not reported "
         "— the line clause is vacuous")
if len(findings_in(under)) != len(findings_in(sample_text)):
    fail("self-test N6: a citation to a line the file HAS was reported — the "
         "line clause fires on references that are fine")

# N6b — and it reaches INSIDE a brace group, where 7 of the corpus's 92
# line anchors live (measured 2026-08-19). Perturbed from the real
# member, so a brace expansion that quietly dropped the anchor would
# show here rather than in six months.
if plan.is_file():
    deep, n6 = re.subn(r"rust/undo\.rs:135", "rust/undo.rs:999999", plan_text)
    print(f"check-doc-refs: self-test N6b pushed a real brace member's line "
          f"anchor past the end of guests/rust/undo.rs, {n6} substitution(s)")
    if n6 < 1:
        fail("self-test N6b applied NO substitution — the brace member it "
             "perturbs is not spelled as expected")
    elif not any("999999" in t for _, t, _ in findings_in(deep)):
        fail("self-test N6b: an over-length citation inside a brace group was "
             "not reported — the members are reaching the line clause without "
             "their anchors")

# N5 — THE CENSUS REFUSAL. A run that read almost nothing must refuse a
# verdict rather than print one. 30 files and 841 checkable references
# today (measured 2026-08-19); the floors below are low enough that
# pruning a plan doc is not a false refusal, high enough that a
# tokenizer which stopped matching cannot report a clean scan.
#
# THE ANCHOR FLOOR IS 1, not a fraction: the corpus carries 92 line
# anchors across five documents, and a doc prune could honestly take
# most of them, but it cannot take all of them by accident. Zero anchors
# beside a full reference count means the SUFFIX stopped being read.
FLOOR_FILES, FLOOR_REFS = 12, 250


def census(nfiles, checked, exempt, anchored):
    total_exempt = sum(exempt.values())
    if nfiles < FLOOR_FILES or checked < FLOOR_REFS:
        return (f"read {nfiles} file(s) and {checked} checkable reference(s) — "
                f"below the floor of {FLOOR_FILES} files / {FLOOR_REFS} "
                f"references. A scan that read almost nothing agrees with "
                f"everything, so this is a REFUSAL, not a pass: either the doc "
                f"set moved or the tokenizer stopped matching.")
    if total_exempt >= checked:
        return (f"{total_exempt} reference(s) were exempted and only {checked} "
                f"checked — the historical-mention convention has eaten the "
                f"gate. REFUSAL, not a pass.")
    if anchored == 0:
        return (f"{checked} reference(s) checked and NOT ONE carried a `:NNN` "
                f"line anchor — the corpus had 31 when the line clause landed, "
                f"so this is the suffix no longer being read rather than the "
                f"docs having dropped every citation. REFUSAL.")
    return None


thin = census(1, 3, {}, 9)
eaten = census(99, 999, {"fenced": 999}, 9)
blind = census(99, 999, {}, 0)
print(f"check-doc-refs: self-test N5 ran the census over 1 file / 3 references "
      f"-> {thin.split(' — ')[0] if thin else 'ACCEPTED'}; over a scan with "
      f"999 exemptions to 999 checks -> "
      f"{eaten.split(' — ')[0] if eaten else 'ACCEPTED'}; and over a scan with "
      f"no line anchor at all -> "
      f"{blind.split(' — ')[0] if blind else 'ACCEPTED'}")
if thin is None:
    fail("self-test N5: the census accepted a 1-file scan — the refusal is "
         "decorative")
if eaten is None:
    fail("self-test N5: the census accepted a scan whose exemptions outnumbered "
         "its checks — the exemption ceiling is decorative")
if blind is None:
    fail("self-test N5: the census accepted a scan that read no line anchor at "
         "all — the anchor floor is decorative")

# The mortal-path clause's own pieces, defined before its self-test.
MORTAL = re.compile(r"scratchpad/[A-Za-z0-9_./{},*?-]*")
MORTAL_SELF = "tools/check-doc-refs.sh"
MORTAL_FLOOR = 400


def mortal_scan(text):
    """Every un-exempt scratchpad citation in one file's text. The same
    two escapes as the main scan: the GONE marker, and a `<placeholder>`
    right after the token (a family name, not a path)."""
    hits = []
    for n, line in enumerate(text.split("\n"), 1):
        for m in MORTAL.finditer(line):
            rest = line[m.end():]
            if GONE in rest[:12] or rest[:1] == "<":
                continue
            hits.append((n, m.group(0)))
    return hits


def mortal_run():
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root,
                         stdout=subprocess.PIPE, text=True, check=False)
    paths = [p for p in out.stdout.split("\0") if p]
    findings, scanned = [], 0
    for p in paths:
        if p == MORTAL_SELF:
            continue
        f = root / p
        if not f.is_file():
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        scanned += 1
        if "scratchpad/" in text:
            findings.extend((p, n, token) for n, token in mortal_scan(text))
    return findings, scanned


# N7 — THE MORTAL-PATH CLAUSE, hot and behind the marker. Planted into a
# real doc's real text like the others.
n7_base = len(mortal_scan(sample_text))
n7_hot = len(mortal_scan(
    sample_text + "\nSee scratchpad/foo-was-here.md for this.\n"))
n7_cold = len(mortal_scan(
    sample_text + "\nSee scratchpad/foo-was-here.md (gone) for this.\n"))
print(f"check-doc-refs: self-test N7 planted a scratch path hot and behind "
      f"{GONE} -> {n7_hot - n7_base} and {n7_cold - n7_base} new finding(s)")
if n7_hot - n7_base != 1:
    fail("self-test N7: a planted scratch-path citation was not reported — "
         "the mortal-path clause is vacuous")
if n7_cold != n7_base:
    fail(f"self-test N7: a {GONE}-marked scratch path was reported anyway — "
         f"the exemption is not being applied")

# ------------------------------------------------------- 1. the clauses

files = docs() + extra
findings, checked, exempt, groups, members, anchored = run(files)

problem = census(len([f for f in files if f.is_file()]), checked, exempt,
                 anchored)
if problem:
    fail(problem)
else:
    for where, n, token, why in findings:
        if SHRANK in why:
            advice = ("Fix the LINE NUMBER — the file is there, the line is "
                      "not. Re-read the target and cite where the thing "
                      "moved to, or drop the anchor and name it in prose.")
        else:
            advice = (f"Fix the path, or — if the sentence must name something "
                      f"the tree no longer has — strike it, quote it inside a "
                      f"fenced block, or mark it `{token} {GONE}`.")
        fail(f"{where}:{n} cites {token}, which {why}.\n    {advice}")

# ---------------------------------------- 2. the mortal-path clause

mortal_findings, mortal_scanned = mortal_run()
if mortal_scanned < MORTAL_FLOOR:
    fail(f"mortal-path clause read {mortal_scanned} tracked file(s) — below "
         f"its floor of {MORTAL_FLOOR} (the tree has ~950). A scan that read "
         f"almost nothing agrees with everything: REFUSAL, not a pass.")
else:
    for where, n, token in mortal_findings:
        fail(f"{where}:{n} cites {token}, which lives in a session scratch "
             f"directory — scratch dies on reboot, so nothing tracked may "
             f"point there.\n    Land the file in the repo (docs/chrome/, "
             f"docs/styling/ and docs/probes/ hold the precedents) and "
             f"repoint, or — for a sentence that must name what is already "
             f"lost — mark it `{token} {GONE}`.")

detail = ", ".join(f"{k} {v}" for k, v in sorted(exempt.items())) or "none"
if status == 0:
    print(f"check-doc-refs: OK ({len(files)} files, {checked} references "
          f"checked, {anchored} of them line-anchored and held to the target's "
          f"length, {groups} brace group(s) expanded to {members} member(s); "
          f"exempt: {detail}; mortal-path clause over {mortal_scanned} tracked "
          f"files)")
else:
    print("check-doc-refs: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)
PY
