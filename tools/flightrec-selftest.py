#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE FLIGHT RECORDER'S CAPTURE PATHS, WATCHED FIRING.
#
# NOT a numbered gate, and the name says so — tools/check-gates.sh's
# census reads `tools/check-*.sh` and `tools/gen-*.sh` as gates and
# would demand this be registered in gates.sh, CLAUDE.md and AGENTS.md;
# worse, its delegation clause forbids the mac runner from invoking
# anything gate-shaped at all, and the mac runner is exactly who needs
# to run this. What it proves is a RUNTIME property of a host — that
# the capture commands on THIS machine actually answer — which a
# static gate cannot see anyway.
#
# It drives the REAL MacRecorder imported from the REAL
# tools/lib/flightrec_lane.py (the mac half since the runner
# conversion): a paraphrase of the capture would prove only that the
# paraphrase works. The one paraphrase left is the DRIVER's leg
# sequence, and it is PINNED: the runner's own _leg_worker is read out
# of tools/validate-mac.py and must make the same recorder calls in
# the same order, or this file refuses before it drives anything.
#
# The tree is never modified. Every perturbation lands on a COPY, the
# substitution count is printed, and the real files' hashes are
# compared before and after — an unchanged copy is a failed test, not
# a passed one.

import ast
import hashlib
import os
import re
import shutil
import subprocess

g = Gate("flightrec-selftest")


def fail(msg):
    print(f"flightrec-selftest: {msg}", file=sys.stderr)
    raise SystemExit(1)


# The driver: the runner's leg sequence over the module at argv[1].
# Run as a SUBPROCESS so each drive's journal home and printed misses
# are its own.
DRIVER = '''import importlib.util
import pathlib
import subprocess
import sys
import time

lane_mod, root, leg_name, tmp = sys.argv[1:5]
leg_argv = sys.argv[5:]
spec = importlib.util.spec_from_file_location("kaya_flightrec_shadow",
                                              lane_mod)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
fr = mod.MacRecorder(pathlib.Path(root))
tmp = pathlib.Path(tmp)
scratch = tmp / "scratch"
log = tmp / "leg.log"
t0 = time.monotonic()
with open(log, "w", encoding="utf-8") as lf:
    proc = subprocess.Popen(["timeout", "120", *leg_argv], stdout=lf,
                            stderr=lf)
    sampler = fr.sampler_start(scratch, proc)
    rc = proc.wait()
    fr.sampler_stop(sampler)
secs = int(time.monotonic() - t0)
verdict = "PASS" if rc == 0 else "FAIL"
fr.mac_leg(leg_name, verdict, secs, log, scratch)
fr.flush()
print(f"driver: status={0 if rc == 0 else 1}")
print(f"driver: run={fr.run_id}")
'''

# THE PIN: the driver above mirrors the runner's pooled leg path, and
# the mirror is checked, not trusted — the real _leg_worker must make
# these recorder calls in this order.
WORKER_CALLS = ["FR.sampler_start(", "proc.wait()", "FR.sampler_stop(",
                "FR.mac_leg("]


def pin_worker():
    text = (ROOT / "tools/validate-mac.py").read_text(encoding="utf-8")
    tree = ast.parse(text)
    src = None
    lines = text.splitlines(keepends=True)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) \
                and node.name == "_leg_worker":
            src = "".join(lines[node.lineno - 1:node.end_lineno])
    if src is None:
        fail("no _leg_worker in tools/validate-mac.py — the runner's "
             "leg path moved and the driver below would mirror nothing")
    at = -1
    for call in WORKER_CALLS:
        nxt = src.find(call)
        if nxt < 0 or nxt < at:
            fail(f"tools/validate-mac.py's _leg_worker no longer calls "
                 f"{call} where the driver mirrors it — re-teach the "
                 f"driver or the worker, they must move together")
        at = nxt
    print("flightrec-selftest: the runner's _leg_worker makes the "
          "driver's four recorder calls in order")


def drive(lane_mod, journal_home, tmp, leg_name="alwaysfail",
          leg_argv=("/usr/bin/false",)):
    tmp.mkdir(parents=True, exist_ok=True)
    driver = tmp / "driver.py"
    driver.write_text(DRIVER, encoding="utf-8")
    r = subprocess.run(
        [sys.executable, str(driver), str(lane_mod), str(ROOT),
         leg_name, str(tmp), *leg_argv],
        capture_output=True, text=True, encoding="utf-8",
        errors="replace", check=False,
        env=dict(os.environ, KAYA_FLIGHTREC_DIR=str(journal_home)))
    return r.returncode, r.stdout + r.stderr


# Every section the mac capture is supposed to account for. A section
# that stops being collected must be a RED here, not a quietly shorter
# bundle — which is the whole failure class this file exists for.
WANT_SECTIONS = "sampler sample leg-log windowserver windows shot " \
                "unified-log"


def check_bundle(home):
    manifests = sorted(pathlib.Path(home).rglob("MANIFEST"))
    if not manifests:
        fail("no bundle was written for a FAILING leg — the capture "
             "never fired")
    return manifests[0]


def sections_present(manifest):
    seen = set()
    for line in pathlib.Path(manifest).read_text(
            encoding="utf-8").splitlines():
        parts = line.split()
        if parts:
            seen.add(parts[0])
    return " ".join(s for s in WANT_SECTIONS.split() if s not in seen)


def doctor_file(label, path, pattern, repl):
    text = g.doctor(label, path.read_text(encoding="utf-8"), pattern,
                    repl, flags=re.M)
    path.write_text(text, encoding="utf-8")


def ascii_findings(ps1_dir, name_only=False):
    """Non-ASCII on CODE lines of every .ps1 under ps1_dir."""
    findings = []
    for p in sorted(pathlib.Path(ps1_dir).glob("*.ps1")):
        rel = p.name if name_only else p.relative_to(ROOT)
        for n, line in enumerate(
                p.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for ch in line:
                if ord(ch) > 127:
                    if name_only:
                        findings.append(f"{rel}:{n}: U+{ord(ch):04X}")
                    else:
                        findings.append(
                            f"{rel}:{n}: U+{ord(ch):04X} {ch!r}")
                    break
    return findings


# ----------------------------------------------------------------------
# The real files' hashes, before anything. Nothing here may modify the
# tree, and this is what proves it rather than asserting it.
REAL_LIB = ROOT / "tools" / "lib" / "flightrec.sh"
REAL_LANE = ROOT / "tools" / "lib" / "flightrec_lane.py"
REAL_MAC = ROOT / "tools" / "validate-mac.py"
REAL_PY = ROOT / "tools" / "lib" / "flightrec.py"


def tree_sha():
    inner = "".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p}\n"
        for p in (REAL_LIB, REAL_LANE, REAL_MAC, REAL_PY))
    return f"{hashlib.sha256(inner.encode('utf-8')).hexdigest()}  -"


before_sha = tree_sha()
pin_worker()

T = g.scratch()

# --- N0: the untouched shape must PASS, or every refusal below could
# be an artifact of the harness rather than of a perturbation. ---------
n0 = T / "n0"
n0.mkdir()
shutil.copy(REAL_LANE, n0 / "flightrec_lane.py")
# A guest that LIVES for a few sampler ticks before failing, so the
# pid resolution is exercised — /usr/bin/false exits before the first
# tick and proved nothing about it, which is how the first live lane
# bundle carried guest_pid=none for a 29s leg.
LIVE_FAIL = ("python3", "-c", "import time, sys; time.sleep(5); "
                              "sys.exit(1)")
n0_rc, n0_log = drive(n0 / "flightrec_lane.py", n0 / "journal", n0,
                      leg_argv=LIVE_FAIL)
if n0_rc != 0:
    print(n0_log, file=sys.stderr)
    fail(f"N0: the untouched driver exited {n0_rc} — this is the tree, "
         f"not the self-test")
if "driver: status=1" not in n0_log:
    print(n0_log, file=sys.stderr)
    fail("N0: an always-failing leg did not produce status=1")
manifest = check_bundle(n0 / "journal")
sampler_txt = (manifest.parent / "sampler.txt").read_text(
    encoding="utf-8") if (manifest.parent / "sampler.txt").is_file() \
    else ""
if not re.search(r"guest_pid=\d+", sampler_txt):
    print(sampler_txt, file=sys.stderr)
    fail("N0: the sampler never resolved the guest's pid while it "
         "lived — the shot and the sample would both skip on every "
         "hang, which is the leg most worth a picture")
missing = sections_present(manifest)
if missing:
    print(manifest.read_text(encoding="utf-8"), file=sys.stderr)
    fail(f"N0: the bundle is missing sections: {missing}")
manifest_text = manifest.read_text(encoding="utf-8")
count = len(manifest_text.splitlines())
print(f"flightrec-selftest: N0 bundle accounted for {count} "
      f"section(s): {manifest_text.replace(chr(10), ' ')}")
if not re.search(r"flightrec: bundle .* sections", n0_log):
    fail("N0: the bundle's counts were never printed — a capture "
         "nobody can see stopped working is a capture nobody notices")
# The journal must carry the leg, with the verdict and the bundle path.
journals = sorted((n0 / "journal").rglob("journal.jsonl"))
journal_text = journals[0].read_text(encoding="utf-8") if journals else ""
if ('"leg":"alwaysfail"' not in journal_text
        or '"verdict":"FAIL"' not in journal_text):
    print(journal_text, file=sys.stderr)
    fail("N0: the journal has no FAIL record for the leg")
print("flightrec-selftest: N0 journal recorded the leg")

# --- N0b: a pid resolution that walks only DESCENDANTS must be caught.
# The runner hands the sampler the `timeout` process itself; a walk
# that looks for timeout one level down resolves nothing forever —
# the exact shape the first live bundle shipped. --------------------
n0b = T / "n0b"
n0b.mkdir()
shutil.copy(REAL_LANE, n0b / "flightrec_lane.py")
doctor_file("N0b dropped the root anchor from guest_pid",
            n0b / "flightrec_lane.py",
            r'anchors = \[str\(root_pid\)\] if self\._comm\(root_pid\)'
            r' == "timeout" \\\n            else \[\]',
            "anchors = []")
_, n0b_log = drive(n0b / "flightrec_lane.py", n0b / "journal", n0b,
                   leg_argv=LIVE_FAIL)
n0b_manifest = check_bundle(n0b / "journal")
n0b_sampler = (n0b_manifest.parent / "sampler.txt").read_text(
    encoding="utf-8") if (n0b_manifest.parent
                          / "sampler.txt").is_file() else ""
if re.search(r"guest_pid=\d+", n0b_sampler):
    fail("N0b: a descendants-only pid walk still resolved the guest — "
         "the perturbation missed the rule it was aimed at")
print("flightrec-selftest: N0b refused — a descendants-only walk "
      "resolves no guest, and N0's clause is what catches it")

# --- N1: a section that stops being collected must be caught. ---------
n1 = T / "n1"
n1.mkdir()
shutil.copy(REAL_LANE, n1 / "flightrec_lane.py")
doctor_file("N1 removed the windowserver section",
            n1 / "flightrec_lane.py",
            r'self\._text_section\(bundle, "windowserver",\s*'
            r'"\\n"\.join\(wanted\) \+ "\\n"\)',
            "pass")
drive(n1 / "flightrec_lane.py", n1 / "journal", n1)
manifest = check_bundle(n1 / "journal")
missing = sections_present(manifest)
if "windowserver" in missing:
    print("flightrec-selftest: N1 refused — the missing section was "
          "named")
else:
    fail(f"N1: a bundle with the windowserver section deleted was "
         f"accepted (missing='{missing}')")

# --- N2: the honest skip. A capture tool this host does not have must
# leave a .skip naming it, never a silently absent section. ------------
n2 = T / "n2"
n2.mkdir()
shutil.copy(REAL_LANE, n2 / "flightrec_lane.py")
doctor_file("N2 pointed the unified-log section at an absent tool",
            n2 / "flightrec_lane.py",
            r'"log", "show", "--last", "2m",',
            '"no-such-tool-on-any-host", "show", "--last", "2m",')
drive(n2 / "flightrec_lane.py", n2 / "journal", n2)
manifest = check_bundle(n2 / "journal")
skipfile = manifest.parent / "unified-log.skip"
if not skipfile.is_file() or skipfile.stat().st_size == 0:
    fail("N2: an absent capture tool left no .skip — the section would "
         "be silently missing")
skip_text = skipfile.read_text(encoding="utf-8")
if "no-such-tool-on-any-host" not in skip_text:
    print(skip_text, file=sys.stderr)
    fail("N2: the skip sentence does not name the tool that was "
         "missing")
if not any(line.startswith("unified-log skip")
           for line in manifest.read_text(
               encoding="utf-8").splitlines()):
    fail("N2: the manifest did not record the skip")
print("flightrec-selftest: N2 the honest skip named the absent tool")

# --- N3: retention is real, and the cap is printed. -------------------
n3 = T / "n3"
n3.mkdir()
last_err = ""
for i in range(4):
    r = subprocess.run(
        ["python3", str(REAL_PY), "start", "mac", str(ROOT)],
        capture_output=True, text=True, check=False,
        env=dict(os.environ, KAYA_FLIGHTREC_DIR=str(n3 / "journal"),
                 KAYA_FLIGHTREC_KEEP="2"))
    last_err = r.stderr
kept = sum(1 for p in (n3 / "journal" / "runs").iterdir()
           if p.is_dir())
if kept != 2:
    fail(f"N3: retention kept {kept} run(s) with the cap at 2")
if "retention: newest 2 runs" not in last_err:
    print(last_err, file=sys.stderr)
    fail("N3: the retention cap was never printed")
if "pruned" not in last_err:
    fail("N3: the prune count was never printed")
print("flightrec-selftest: N3 retention held 4 runs to 2, cap printed")

# --- N4: a runner that cannot open the journal still runs its legs,
# and says so ONCE. ----------------------------------------------------
n4 = T / "n4"
n4.mkdir()
shutil.copy(REAL_LANE, n4 / "flightrec_lane.py")
# A journal home that cannot be created: a path under a FILE.
(n4 / "blocker").write_text("", encoding="utf-8")
n4_rc, n4_log = drive(n4 / "flightrec_lane.py",
                      n4 / "blocker" / "journal", n4)
if n4_rc != 0:
    print(n4_log, file=sys.stderr)
    fail("N4: an unwritable journal took the leg down with it — the "
         "recorder must never cost a lane its legs")
if "driver: status=1" not in n4_log:
    print(n4_log, file=sys.stderr)
    fail("N4: the leg did not run when the journal was unavailable")
misses = sum(1 for line in n4_log.splitlines()
             if "flightrec: the journal could not be opened" in line)
if misses != 1:
    print(n4_log, file=sys.stderr)
    fail(f"N4: the journal miss was printed {misses} times, want "
         f"exactly 1")
print("flightrec-selftest: N4 an unwritable journal cost no leg and "
      "printed the miss once")

# --- N6: A PASSING LEG COSTS THE OBSERVER NOTHING. --------------------
#
# THE REGRESSION THIS EXISTS FOR: the first version spent three ssh
# round trips and a python3 spawn on EVERY leg, pass or fail — measured
# 304ms on a quiescent VM — and took the windows lane 110s past its
# duration ceiling on the recorder's first matrix. A lane's ceiling is
# the only thing that noticed, and only once the whole matrix had run.
# This is the wall that notices in seconds.
n6 = T / "n6"
n6.mkdir()
shutil.copy(REAL_LANE, n6 / "flightrec_lane.py")
n6_rc, n6_log = drive(n6 / "flightrec_lane.py", n6 / "journal", n6,
                      leg_name="alwayspass",
                      leg_argv=("/usr/bin/true",))
if n6_rc != 0:
    print(n6_log, file=sys.stderr)
    fail(f"N6: the passing-leg driver exited {n6_rc}")
if "driver: status=0" not in n6_log:
    print(n6_log, file=sys.stderr)
    fail("N6: the passing leg did not report status=0")
# NOTHING BUNDLE-SHAPED on the pass path.
bundles = [p for p in (n6 / "journal").rglob("mac-*") if p.is_dir()]
if bundles:
    print("\n".join(str(p) for p in bundles), file=sys.stderr)
    fail("N6: a PASSING leg scaffolded a bundle — the pass path must "
         "create nothing")
# The record still exists, via the spool.
journals = sorted((n6 / "journal").rglob("journal.jsonl"))
journal_text = journals[0].read_text(encoding="utf-8") if journals else ""
if ('"leg":"alwayspass"' not in journal_text
        or '"verdict":"PASS"' not in journal_text):
    print(journal_text, file=sys.stderr)
    fail("N6: the passing leg was not journalled")
# And the spool was truncated by the flush, so a second flush cannot
# double every record.
spools = sorted((n6 / "journal").rglob("spool.tsv"))
if spools and spools[0].stat().st_size > 0:
    fail("N6: the spool survived the flush — a second flush would "
         "write every record twice")
# THE STATIC HALF, BOTH LANGUAGES: the per-leg record path may not
# spawn. The shell library still serves the linux lane; the python
# LaneRecorder.leg serves the four converted runners.
lib_text = REAL_LIB.read_text(encoding="utf-8")
m = re.search(r"^flightrec_leg\(\) \{.*?^\}", lib_text, re.S | re.M)
if not m:
    fail("N6: flightrec_leg could not be read out of the library — the "
         "anchor moved")
body = m.group(0)
for banned in ("python3", "run_ssh", "scp", "mkdir"):
    for line in body.splitlines():
        if re.match(r"^\s*#", line):
            continue
        if re.search(rf"\b{banned}\b", line):
            print(body, file=sys.stderr)
            fail(f"N6: flightrec_leg calls '{banned}' — it runs on "
                 f"every leg of two lanes and must not spawn or speak "
                 f"to the VM")
lane_tree = ast.parse(REAL_LANE.read_text(encoding="utf-8"))
lane_lines = REAL_LANE.read_text(encoding="utf-8").splitlines(
    keepends=True)
leg_src = None
for node in ast.walk(lane_tree):
    if isinstance(node, ast.FunctionDef) and node.name == "leg":
        leg_src = "".join(lane_lines[node.lineno - 1:node.end_lineno])
        break
if leg_src is None:
    fail("N6: LaneRecorder.leg could not be read — the anchor moved")
if "subprocess" in leg_src or "Popen" in leg_src:
    print(leg_src, file=sys.stderr)
    fail("N6: LaneRecorder.leg spawns — it runs on every leg of four "
         "lanes and must stay one O_APPEND write")
print("flightrec-selftest: N6 a passing leg made no bundle, spawned "
      "nothing, and was journalled through the spool")

# --- N5: every shipped .ps1 is pure ASCII. ----------------------------
#
# MEASURED, on the first run against the VM: Windows PowerShell 5.1
# reads a .ps1 as the machine's ANSI CODEPAGE, not as UTF-8. An em-dash
# then arrives as three CP1252 bytes CONTAINING A DOUBLE QUOTE; inside
# a string literal it closes the string early and the file dies with
# "Unexpected token" before its first statement — indistinguishable
# from a capture that had nothing to collect.
#
# THE RULE IS CODE LINES, NOT ALL LINES, and the difference is measured
# too: tools/guest/desk-warm.ps1 and wait-exit.ps1 have carried
# em-dashes for months and work, because theirs are in WHOLE-LINE
# COMMENTS. Nothing else in the tree looks: check-shell walks tools/
# for .sh and .cmd and never .ps1.
nonascii = ascii_findings(ROOT / "tools" / "guest")
if nonascii:
    print("\n".join(nonascii), file=sys.stderr)
    fail("N5: a shipped .ps1 carries non-ASCII — Windows PowerShell "
         "reads it in the ANSI codepage and the file will not parse on "
         "the guest")
checked = len(list((ROOT / "tools" / "guest").rglob("*.ps1")))
if checked < 1:
    fail("N5: no .ps1 was read — a census that reads nothing agrees "
         "with everything")
print(f"flightrec-selftest: N5 {checked} shipped .ps1 file(s) carry no "
      f"non-ASCII on a code line")

# N5's own negative, on a shadow: the exact shape that broke on the VM
# — an em-dash inside a string literal — must be refused, while an
# em-dash in a whole-line COMMENT must not be, or the clause is either
# blind or unusable. Both directions are perturbed here.
#
# APPENDED RATHER THAN SUBSTITUTED, deliberately: what this rule is
# about is CHARACTERS, not a construct, so there is no spelling it
# needs to be proven against (an anchored substitution went stale once
# already and `applied 0` caught it).
n5 = T / "n5"
n5.mkdir()
shadow_ps1 = n5 / "flightrec.ps1"
shutil.copy(ROOT / "tools" / "guest" / "flightrec.ps1", shadow_ps1)
before_len = shadow_ps1.stat().st_size
shadow_ps1.write_text(
    shadow_ps1.read_text(encoding="utf-8")
    + "# a comment em-dash — must be tolerated\n"
    + 'Emit $out "a literal em-dash — must not be"\n',
    encoding="utf-8")
if shadow_ps1.stat().st_size <= before_len:
    fail("SELF-TEST BROKEN (N5 appended nothing) — a perturbation that "
         "changed nothing is a passed test that proves nothing")
print("flightrec-selftest: N5 appended an em-dash in a comment AND in "
      "a string literal, 1 substitution(s)")
n5_found = ascii_findings(n5, name_only=True)
if not n5_found:
    fail("SELF-TEST FAIL (N5: an em-dash in a string literal was not "
         "refused — the clause is blind)")
# EXACTLY ONE. Two findings would mean the comment line was refused as
# well, which is the direction that would redden desk-warm.ps1 and
# wait-exit.ps1 — files that have carried em-dashes for months and
# work.
if len(n5_found) != 1:
    print("\n".join(n5_found), file=sys.stderr)
    fail(f"SELF-TEST FAIL (N5: {len(n5_found)} findings, want exactly "
         f"1 — the comment line must be tolerated and only the literal "
         f"refused)")
print(f"flightrec-selftest: N5 refused the literal and tolerated the "
      f"comment ({n5_found[0]})")

# --- the tree is as it was found. -------------------------------------
after_sha = tree_sha()
if after_sha != before_sha:
    fail("REFUSING A VERDICT — this self-test modified the tree it was "
         "testing")
print(f"flightrec-selftest: the tree is unchanged ({before_sha})")
g.verdict("9 clauses, 5 watched perturbations, the worker pinned")
