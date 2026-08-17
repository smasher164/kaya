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

# A PATH THE DOCS NAME MUST BE A PATH THE TREE HAS.
#
#   tools/check-doc-refs.sh                 every tracked .md in the tree
#   tools/check-doc-refs.sh --also PATH     scan one more file BESIDE the
#                                           real set — THE TEST SEAM. The
#                                           watched negatives plant their
#                                           dead reference in a COPY and
#                                           point this at the copy, so the
#                                           real docs are never edited to
#                                           prove a gate red, and the
#                                           census below still measures
#                                           the whole set.
#
# WHY, measured 2026-08-17 alongside the ledger gate. docs/traps.md
# claimed "the modern generation has no dedicated leg yet" after it had
# one; comments pointed at scenes and behaviours that had moved. The
# ledger half of that failure is tools/check-ledger.sh; this is the other
# half — a citation that names a file. Prose rots quietly, but a PATH is
# the one part of prose a machine can hold to the tree, and a reader who
# opens a cited path and finds nothing there stops trusting the document
# rather than the sentence.
#
# WHAT COUNTS AS A REFERENCE: a word starting with one of the repo's
# source roots — tools/ crates/ guests/ docs/ swift/ android/ bindings/ —
# wherever it appears, backticked or bare. Trailing punctuation, a `:123`
# line suffix and a possessive `'s` all end the token; a `<placeholder>`
# right after it (`tools/guest/run_<scene>_<lang>.cmd`) makes it a FAMILY
# name rather than a file, and families are not checked.
#
# THREE SHAPES BEYOND THE PLAIN PATH, each measured in the tree rather
# than imagined:
#
#   GLOBS — `tools/scenes/*.steps`, `tools/check-*.sh`. Resolved by
#     globbing and required to match AT LEAST ONE path, which is strictly
#     better than exempting them: a glob that has stopped matching is
#     exactly as dead as a missing file.
#   BRACE GROUPS — `guests/{go/undo/undo.go:309, rust/undo.rs:207, …}`,
#     `tools/{win,mac,ios,android}`. Expanded and checked member by
#     member (11 real paths behind 2 groups today). Left alone, the
#     tokenizer would read `swift/undo.swift` out of the middle of one
#     and report a file that was never claimed to exist.
#   ELISIONS — `android/kaya/.../KayaCompose.kt`. NOT exempt: a `...`
#     inside a path is an abbreviation the reader cannot follow, and the
#     fix is to write the path out.
#
# THE HISTORICAL-MENTION CONVENTION, kept as small as it can honestly
# be, because every exemption is a place a dead reference can hide:
#
#   1. Inside ~~strikethrough~~. The ledger already strikes what is no
#      longer true, and a struck sentence is not making a claim.
#   2. Inside a ``` fenced block. Those quote OLD output and old
#      commands verbatim, and a quote may not be edited to suit a gate.
#   3. Followed by the literal marker `(gone)`. That is the escape for a
#      live sentence that must name a file the tree no longer has — one
#      marker, spelled one way, so a reader and this gate see the same
#      thing.
#
# Nothing else. In particular a reference is not exempted for being in a
# "historical" document: every doc in docs/ is a record of something that
# already happened, so that rule would exempt the whole corpus.
#
# THE EXEMPTIONS ARE COUNTED AND PRINTED on every run, and the gate
# REFUSES A VERDICT if the exempt references outnumber the checked ones.
# An exemption nobody is watching grows until the gate reads nothing,
# which is the census failure one directory over (check-gates,
# tpl-surfaces): a reader that checked almost nothing agrees with
# everything.
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
    # go green about a file it never opened — the negative test's own
    # false pass.
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
FENCE = re.compile(r"^\s*```")
STRIKE = re.compile(r"~~.+?~~", re.S)
GONE = "(gone)"


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

    Returns (text, groups, members) where members is [(line, path)] and
    the group itself has been BLANKED OUT of the text — the tokenizer
    would otherwise read `swift/undo.swift` out of the middle of one and
    report a file nobody ever claimed existed.

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
            item = item.strip().split(":")[0].strip()
            if item:
                members.append((line, m.group(1) + item))
        return re.sub(r"[^\n]", " ", m.group(0))

    return BRACE.sub(sub, text), groups, members


def scan(path, text):
    """Every reference in one file, as (line, token, why-exempt-or-None).

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
            why = None
            if in_fence:
                why = "fenced"
            elif any(a <= start + m.start() < b for a, b in struck):
                why = "struck"
            elif GONE in line[m.end():m.end() + 12]:
                why = "gone-marker"
            elif line[m.end():m.end() + 1] == "<":
                why = "placeholder"
            out.append((n, token, why))
    # A brace group's members are checked but never exempted: the group
    # is a compact citation, not a quotation.
    out.extend((line, path, None) for line, path in members)
    return out, groups, len(members)


def resolve(token):
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
    if (root / token).exists():
        return None
    return "does not exist"


# ------------------------------------------------------ the scan itself

def run(files):
    """(findings, checked, exempt, groups, members) over a file list."""
    findings, checked, exempt = [], 0, {}
    groups = members = 0
    for path in files:
        if not path.is_file():
            continue
        refs, g, mem = scan(path, path.read_text(encoding="utf-8"))
        groups += g
        members += mem
        for n, token, why in refs:
            if why:
                exempt[why] = exempt.get(why, 0) + 1
                continue
            checked += 1
            bad = resolve(token)
            if bad:
                try:
                    rel = path.relative_to(root)
                except ValueError:
                    rel = path
                findings.append((str(rel), n, token, bad))
    return findings, checked, exempt, groups, members


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
    return [(n, t, resolve(t)) for n, t, w in refs if not w and resolve(t)]


# N1 — a dead path must be reported. Planted into a real doc's real text.
planted = sample_text + "\nSee tools/check-there-is-no-such-file.sh for this.\n"
print(f"check-doc-refs: self-test N1 planted 1 dead path in a copy of "
      f"docs/HACKING.md, {len(findings_in(planted)) - len(findings_in(sample_text))} "
      f"new finding(s)")
if not any("check-there-is-no-such-file" in t for _, t, _ in findings_in(planted)):
    fail("self-test N1: a planted dead path was not reported — the existence "
         "clause is vacuous")

# N2 — a glob that matches nothing must be reported. Perturbed from a
# glob the docs really carry, so the clause is proven against the real
# spelling rather than an invented one.
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
# happening, this comes back green and the eleven paths behind today's
# two groups are checked by nobody.
plan = root / "docs" / "sugar-pass-plan.md"
if not plan.is_file():
    fail("self-test N3 impossible: docs/sugar-pass-plan.md is gone and it is "
         "the file carrying a brace group — re-point this self-test")
else:
    plan_text = plan.read_text(encoding="utf-8")
    _, g0, m0 = scan(plan, plan_text)
    broken, n3 = re.subn(r"rust/undo\.rs:207", "rust/undo-NO-SUCH.rs:207",
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

# N5 — THE CENSUS REFUSAL. A run that read almost nothing must refuse a
# verdict rather than print one.
# 27 files and 510 checkable references today, so the floors sit at
# roughly half of each: low enough that pruning a plan doc is not a false
# refusal, high enough that a tokenizer which stopped matching cannot
# report a clean scan.
FLOOR_FILES, FLOOR_REFS = 12, 250


def census(nfiles, checked, exempt):
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
    return None


thin = census(1, 3, {})
eaten = census(99, 999, {"fenced": 999})
print(f"check-doc-refs: self-test N5 ran the census over 1 file / 3 references "
      f"-> {thin.split(' — ')[0] if thin else 'ACCEPTED'}; and over a scan with "
      f"999 exemptions to 999 checks -> "
      f"{eaten.split(' — ')[0] if eaten else 'ACCEPTED'}")
if thin is None:
    fail("self-test N5: the census accepted a 1-file scan — the refusal is "
         "decorative")
if eaten is None:
    fail("self-test N5: the census accepted a scan whose exemptions outnumbered "
         "its checks — the exemption ceiling is decorative")

# ------------------------------------------------------- 1. the clauses

files = docs() + extra
findings, checked, exempt, groups, members = run(files)

problem = census(len([f for f in files if f.is_file()]), checked, exempt)
if problem:
    fail(problem)
else:
    for where, n, token, why in findings:
        fail(f"{where}:{n} cites {token}, which {why}.\n"
             f"    Fix the path, or — if the sentence must name something the "
             f"tree no longer has — strike it, quote it inside a fenced block, "
             f"or mark it `{token} {GONE}`.")

detail = ", ".join(f"{k} {v}" for k, v in sorted(exempt.items())) or "none"
if status == 0:
    print(f"check-doc-refs: OK ({len(files)} files, {checked} references "
          f"checked, {groups} brace group(s) expanded to {members} member(s); "
          f"exempt: {detail})")
else:
    print("check-doc-refs: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)
PY
