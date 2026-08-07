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

# THE THREE LISTS OF GATES MUST BE ONE LIST.
#
#   what tools/gates.sh RUNS   — the executable list
#   what tools/validate-mac.sh RUNS — which must be exactly the above,
#                              by delegation and not by copy
#   what CLAUDE.md DOCUMENTS   — rung 2 of the validation ladder, the
#                              list a session with no context reads and
#                              believes
#
# THE DEFECT THIS EXISTS FOR, measured at 0dae894 before the sweep
# landed. validate-mac.sh ran 26 gate scripts; CLAUDE.md's rung 2 named
# 23, and omitted FOUR that the lane actually ran — check-case.sh,
# check-jni.sh, check-native-undo.sh, check-roles.sh. So an agent that
# "ran the fast gates" out of CLAUDE.md ran 22 of 26 and reported a
# sweep. That is an under-run with a paper trail, in the file whose
# mirror-drift is itself guarded: check-mirror.sh cannot see it, because
# it compares CLAUDE.md to AGENTS.md and both mirrors were equally
# stale.
#
# Plus the census clause, which is the one that would have caught those
# four: every gate script ON DISK is either in the list or in
# gates.sh's EXCLUDED table WITH A REASON. A gate that exists and is in
# neither is a gate nobody runs, and nothing else in the tree can see
# that.
#
# check-gates reads CLAUDE.md alone and not AGENTS.md: the two are true
# mirrors and check-mirror.sh is what holds that. Checking both here
# would report the same drift twice and would not catch anything the
# pair of gates does not already catch.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - "$ROOT" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])

status = 0


def fail(msg):
    global status
    print(f"check-gates: {msg}", file=sys.stderr)
    status = 1


# A GATE'S SCRIPT PATH IS ITS NAME EVERYWHERE — in gates.sh's list, in
# CLAUDE.md's prose, and on disk — so one pattern serves all three
# readers. The naming clause below then FORCES every gate into a shape
# this pattern can see, which is what stops the prose scan from going
# quietly blind the day someone adds tools/verify-something.sh.
SHELL_GATE = r"tools/(?:check-[a-z0-9-]+|gen-[a-z0-9-]+|swift-typecheck|java-typecheck)\.sh"
PY_GATE = r"bindings/python/[a-z0-9_]+\.py"
TOKEN = re.compile(f"{SHELL_GATE}|{PY_GATE}")


def rung2(text):
    """CLAUDE.md's fast-gate block. Anchored on the ladder's numbering,
    and a moved anchor is a loud failure rather than an empty set — an
    empty set would agree with nothing and pass nothing, but it would
    also be the shape a vacuous scan takes."""
    try:
        start = text.index("2. Fast gates")
        end = text.index("3. `tools/validate-mac.sh`", start)
    except ValueError:
        return None
    return text[start:end]


def documented(block):
    return set(TOKEN.findall(block))


def script_of(cmd):
    """The gate script inside an argv — `tools/x.sh` or the .py an
    interpreter is pointed at."""
    for word in cmd:
        if TOKEN.fullmatch(word):
            return word
    return None


def drift(listed, doc):
    """The two directions of disagreement, in that order. Kept as one
    function because the message has to name BOTH lists: 'check-roles is
    missing' is useless without 'missing from WHICH'."""
    return sorted(set(listed) - set(doc)), sorted(set(doc) - set(listed))


def drift_lines(only_listed, only_doc):
    out = []
    if only_listed:
        out.append("in tools/gates.sh's list (run or excluded) but NOT named in "
                   "CLAUDE.md rung 2: " + " ".join(only_listed))
    if only_doc:
        out.append("named in CLAUDE.md rung 2 but NOT in tools/gates.sh's list: "
                   + " ".join(only_doc))
    return out


def code_lines(text):
    """Shell lines that are not whole-line comments. A gate NAMED in a
    comment is a citation; a gate INVOKED is a second list."""
    return [ln for ln in text.splitlines() if not ln.strip().startswith("#")]


def direct_invocations(text):
    """Gate scripts validate-mac runs itself, plus any keyed.sh call.
    Both are the same defect: a second place that decides what the
    sweep is."""
    hits = set()
    for line in code_lines(text):
        hits.update(TOKEN.findall(line))
        if re.search(r"(?:^|[\s;&|(])tools/keyed\.sh\b", line):
            hits.add("tools/keyed.sh")
    return hits


def census(on_disk, listed, excluded):
    """Gate scripts that exist and are in neither list."""
    return sorted(set(on_disk) - set(listed) - set(excluded))


# ---------------------------------------------------------------- data

out = subprocess.run([str(root / "tools" / "gates.sh"), "--list"],
                     cwd=root, stdout=subprocess.PIPE, text=True, check=False)
if out.returncode != 0:
    print("check-gates: tools/gates.sh --list failed — the list is unreadable, "
          "so nothing below could be checked", file=sys.stderr)
    sys.exit(1)
listing = json.loads(out.stdout)
GATES = listing["gates"]
EXCLUDED = listing["excluded"]

claude_text = (root / "CLAUDE.md").read_text(encoding="utf-8")
mac_text = (root / "tools" / "validate-mac.sh").read_text(encoding="utf-8")
block = rung2(claude_text)
if block is None:
    print("check-gates: could not find CLAUDE.md's rung-2 block (the anchors "
          "'2. Fast gates' and '3. `tools/validate-mac.sh`' moved). Fix the "
          "anchors here or the ladder there — do not let this gate go quiet.",
          file=sys.stderr)
    sys.exit(1)

on_disk = sorted(
    f"tools/{p.name}" for p in (root / "tools").glob("*.sh")
    if re.fullmatch(SHELL_GATE, f"tools/{p.name}")
)

# --------------------------------------------------- 0. the self-tests
#
# Every clause below is a set comparison, and a set comparison that
# parsed nothing agrees with everything. So each one is watched failing
# FIRST, against the real bytes of the real files — CLAUDE.md's actual
# rung-2 block and validate-mac.sh's actual text — doctored in memory,
# with the substitution count printed. Zero substitutions is a FAILED
# self-test, never a passed one: this is the rule check-tx-liveness and
# the wayland seat guard both learned the hard way (three clauses passed
# with the guard deleted; a pattern that never matched passed twice).

listed_scripts = [script_of(g["cmd"]) for g in GATES]
if None in listed_scripts:
    for g in GATES:
        if script_of(g["cmd"]) is None:
            fail(f"gate {g['name']!r} runs {' '.join(g['cmd'])}, which names no "
                 f"gate-shaped script. Every gate must be spelled so the prose "
                 f"scan can see it (tools/check-*.sh, tools/gen-*.sh, "
                 f"tools/*-typecheck.sh, or bindings/python/*.py) — or teach "
                 f"this gate's TOKEN the new shape, deliberately.")
    print("check-gates: FINDINGS ABOVE", file=sys.stderr)
    sys.exit(1)

# CLAUDE.md documents the EXCLUDED gates too — check-gtk.sh is named
# there precisely so a reader knows it exists and why the lane does not
# run it — so the prose is compared against run-plus-excluded. Leaving
# the excluded ones out would have made rung 2 the one list allowed to
# forget a gate, which is the drift this gate is for.
known = listed_scripts + sorted(EXCLUDED)
doc_names = documented(block)
shared = sorted(set(known) & doc_names)
if not shared:
    fail("self-test impossible: the list and CLAUDE.md have NO gate in common, "
         "so the scan below is measuring nothing")
else:
    victim = shared[0]
    # N1 — a gate dropped from the PROSE must be reported, naming both
    # lists. The perturbation is applied to CLAUDE.md's real bytes.
    doctored, n = re.subn(re.escape(victim), "tools/check-REMOVED-BY-SELFTEST.sh", block)
    print(f"check-gates: self-test N1 removed {victim} from CLAUDE.md's rung-2 "
          f"block, {n} substitution(s)")
    if n < 1:
        fail(f"self-test N1 applied NO substitution — {victim} is not in the "
             f"block as written, so the prose scan is not reading what it thinks")
    else:
        only_listed, only_doc = drift(known, documented(doctored))
        if victim not in only_listed:
            fail(f"self-test N1: {victim} was deleted from the prose and the "
                 f"comparison did not report it — the prose scan is vacuous")
        lines = drift_lines(only_listed, only_doc)
        if not any("CLAUDE.md" in ln and "gates.sh" in ln for ln in lines):
            fail("self-test N1: the drift message does not name both lists")

    # N2 — the same drift from the other side: a gate dropped from the
    # EXECUTABLE list must be reported as documented-but-not-run.
    shrunk = [s for s in known if s != victim]
    print(f"check-gates: self-test N2 removed {victim} from the executable "
          f"list, {len(known) - len(shrunk)} entr(y|ies)")
    if len(shrunk) == len(known):
        fail("self-test N2 removed nothing — the executable list is not what "
             "this scan is reading")
    else:
        only_listed, only_doc = drift(shrunk, doc_names)
        if victim not in only_doc:
            fail(f"self-test N2: {victim} was dropped from the list and the "
                 f"comparison did not report it")

# N3 — a gate invoked DIRECTLY by validate-mac must be reported. The
# perturbation plants one back into validate-mac.sh's real text, which
# is exactly the edit this clause exists to refuse.
planted, n = re.subn(r"(?m)^tools/gates\.sh\b",
                     "tools/check-mirror.sh || exit 1\ntools/gates.sh", mac_text)
print(f"check-gates: self-test N3 planted a direct gate call in "
      f"validate-mac.sh, {n} substitution(s)")
if n < 1:
    fail("self-test N3 applied NO substitution — validate-mac.sh does not "
         "invoke tools/gates.sh at the start of a line, so the delegation "
         "clause below is measuring nothing")
elif "tools/check-mirror.sh" not in direct_invocations(planted):
    fail("self-test N3: a planted direct gate call was not seen — the "
         "delegation clause is vacuous")

# N4 — a gate script on disk that is in neither list must be reported.
if not census(on_disk + ["tools/check-invented-by-selftest.sh"],
              listed_scripts, EXCLUDED):
    fail("self-test N4: a gate script in neither list was not reported — the "
         "census clause is vacuous")

# ------------------------------------------------------- 1. the clauses

only_listed, only_doc = drift(known, doc_names)
for line in drift_lines(only_listed, only_doc):
    fail(line)
if only_listed or only_doc:
    fail("the three lists must be one list — add the gate to tools/gates.sh's "
         "GATES (or its EXCLUDED table, with a reason) and name it in rung 2 "
         "of BOTH CLAUDE.md and AGENTS.md")

for script in census(on_disk, listed_scripts, EXCLUDED):
    fail(f"{script} exists but is in no list — tools/gates.sh neither runs it "
         f"nor excludes it, so nothing in this repo runs it and nothing says "
         f"why not")

for script, why in sorted(EXCLUDED.items()):
    if not (root / script).is_file():
        fail(f"{script} is excluded from the sweep but does not exist — delete "
             f"the exclusion")
    if len(why.strip()) < 20:
        fail(f"{script} is excluded with no real reason given ({why!r}); an "
             f"exclusion nobody justified is how four gates went unnamed")
    if script in listed_scripts:
        fail(f"{script} is both run and excluded")

direct = direct_invocations(mac_text)
if direct:
    fail("tools/validate-mac.sh invokes gates itself: "
         + " ".join(sorted(direct))
         + " — the lane must DELEGATE to tools/gates.sh, or the sweep has two "
           "lists again and the count in one of them means nothing")
if not re.search(r"(?m)^tools/gates\.sh\b", mac_text):
    fail("tools/validate-mac.sh does not call tools/gates.sh — the lane runs "
         "no gate sweep at all")

# The driver's own arithmetic: an under-run, a failing gate and a missing
# script must each come back red. This is the count-in/count-out clause,
# watched failing on every run of this gate rather than the day someone
# remembers to check.
proof = subprocess.run([str(root / "tools" / "gates.sh"), "--selftest"],
                       cwd=root, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, check=False)
if proof.returncode != 0:
    fail("tools/gates.sh --selftest FAILED — the sweep's count does not refuse "
         "an under-run, so a sweep that ran nothing could print OK:\n"
         + proof.stdout)

if status == 0:
    print(f"check-gates: OK ({len(GATES)} gates in one list, "
          f"{len(EXCLUDED)} excluded with a reason)")
else:
    print("check-gates: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)
PY
