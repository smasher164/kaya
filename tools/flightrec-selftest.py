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
# worse, its delegation clause forbids tools/validate-mac.sh from
# invoking anything gate-shaped at all, and the mac runner is exactly
# who needs to run this. What it proves is a RUNTIME property of a host
# — that the capture commands on THIS machine actually answer — which a
# static gate cannot see anyway.
#
# It drives the REAL run() cut out of tools/validate-mac.sh, the shape
# tools/check-harness-ceiling.sh uses when it cuts the watchdog out of
# KayaSwiftUI.swift and compiles it: a paraphrase of the runner would
# prove only that the paraphrase works.
#
# The tree is never modified. Every perturbation lands on a COPY, the
# substitution count is printed, and the real files' hashes are
# compared before and after — an unchanged copy is a failed test, not a
# passed one. The DRIVERS it writes are bash on purpose: run() and
# tools/lib/flightrec.sh are runner-side shell (the conversion ruling's
# boundary), so the thing under test is sourced, not paraphrased.

import hashlib
import os
import re
import shutil
import subprocess

g = Gate("flightrec-selftest")


def fail(msg):
    print(f"flightrec-selftest: {msg}", file=sys.stderr)
    raise SystemExit(1)


# The real run() function, cut out of the real runner by brace depth.
def extract_run(src, dest):
    lines = pathlib.Path(src).read_text(encoding="utf-8") \
        .splitlines(keepends=True)
    start = None
    for i, line in enumerate(lines):
        if line.startswith("run() {"):
            start = i
            break
    if start is None:
        fail("no run() in the runner — the extraction anchor moved")
    depth = 0
    end = None
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0 and i > start:
            end = i
            break
    if end is None:
        fail("run() never closed")
    pathlib.Path(dest).write_text("".join(lines[start:end + 1]),
                                  encoding="utf-8")
    return end - start + 1


# A harness that gives the extracted run() the handful of names the
# runner would have given it, and nothing else.
def write_driver(dest, lib, run_body, leg_name="alwaysfail",
                 leg_cmd="/usr/bin/false"):
    dest.write_text(f'''#!/usr/bin/env bash
set -uo pipefail
FLIGHTREC_ROOT="{ROOT}"
export FLIGHTREC_ROOT
# The runner has this sourced, and without it kaya_swiftc is undefined,
# the window list cannot be built and two sections skip for a reason
# belonging to the harness rather than to the host.
source "{ROOT}/tools/lib/swift-toolchain.sh"
source "{lib}"
flightrec_start mac
JOBS=1
status=0
LEGS_DIR="$(mktemp -d)"
FLIGHTREC_SCRATCH="$(mktemp -d)"
leg_names=()
leg_pids=()
running_legs() {{ echo 0; }}
source "{run_body}"
run {leg_name} {leg_cmd}
# The journal is SPOOLED on the leg path and turned into records once,
# exactly as the runner's lane end and EXIT trap do it.
flightrec_flush
echo "driver: status=$status"
echo "driver: run=$FLIGHTREC_RUN"
rm -rf "$LEGS_DIR" "$FLIGHTREC_SCRATCH"
''', encoding="utf-8")
    dest.chmod(0o755)


def drive(driver, journal_home):
    r = subprocess.run(["bash", str(driver)], capture_output=True,
                       text=True, check=False,
                       env=dict(os.environ,
                                KAYA_FLIGHTREC_DIR=str(journal_home)))
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
REAL_MAC = ROOT / "tools" / "validate-mac.sh"
REAL_PY = ROOT / "tools" / "lib" / "flightrec.py"


def tree_sha():
    inner = "".join(
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p}\n"
        for p in (REAL_LIB, REAL_MAC, REAL_PY))
    return f"{hashlib.sha256(inner.encode('utf-8')).hexdigest()}  -"


before_sha = tree_sha()

T = g.scratch()
run_body = T / "run.sh"
lines = extract_run(REAL_MAC, run_body)
print(f"flightrec-selftest: cut run() out of tools/validate-mac.sh "
      f"({lines} lines)")

# --- N0: the untouched shape must PASS, or every refusal below could
# be an artifact of the extraction rather than of a perturbation. ------
n0 = T / "n0"
n0.mkdir()
shutil.copy(REAL_LIB, n0 / "flightrec.sh")
write_driver(n0 / "driver.sh", n0 / "flightrec.sh", run_body)
n0_rc, n0_log = drive(n0 / "driver.sh", n0 / "journal")
if n0_rc != 0:
    print(n0_log, file=sys.stderr)
    fail(f"N0: the untouched driver exited {n0_rc} — this is the tree, "
         f"not the self-test")
if "driver: status=1" not in n0_log:
    print(n0_log, file=sys.stderr)
    fail("N0: an always-failing leg did not produce status=1")
manifest = check_bundle(n0 / "journal")
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

# --- N1: a section that stops being collected must be caught. ---------
n1 = T / "n1"
n1.mkdir()
shutil.copy(REAL_LIB, n1 / "flightrec.sh")
doctor_file("N1 removed the windowserver section", n1 / "flightrec.sh",
            r'^    flightrec_section "\$bundle" "windowserver" ps \\$',
            "    : \\\\")
write_driver(n1 / "driver.sh", n1 / "flightrec.sh", run_body)
drive(n1 / "driver.sh", n1 / "journal")
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
shutil.copy(REAL_LIB, n2 / "flightrec.sh")
doctor_file("N2 pointed the unified-log section at an absent tool",
            n2 / "flightrec.sh",
            r'^    flightrec_section "\$bundle" "unified-log" log \\$',
            '    flightrec_section "$bundle" "unified-log" '
            'no-such-tool-on-any-host \\\\')
write_driver(n2 / "driver.sh", n2 / "flightrec.sh", run_body)
drive(n2 / "driver.sh", n2 / "journal")
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
shutil.copy(REAL_LIB, n4 / "flightrec.sh")
write_driver(n4 / "driver.sh", n4 / "flightrec.sh", run_body)
# A journal home that cannot be created: a path under a FILE.
(n4 / "blocker").write_text("", encoding="utf-8")
n4_rc, n4_log = drive(n4 / "driver.sh", n4 / "blocker" / "journal")
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
shutil.copy(REAL_LIB, n6 / "flightrec.sh")
write_driver(n6 / "driver.sh", n6 / "flightrec.sh", run_body,
             leg_name="alwayspass", leg_cmd="/usr/bin/true")
n6_rc, n6_log = drive(n6 / "driver.sh", n6 / "journal")
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
# THE STATIC HALF: the leg-record path may not spawn or speak to the VM.
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
print("flightrec-selftest: N6 a passing leg made no bundle, spawned "
      "nothing, and was journalled through the spool")

# --- N5: every shipped .ps1 is pure ASCII. ----------------------------
#
# MEASURED, on the first run against the VM: Windows PowerShell 5.1
# reads a .ps1 as the machine's ANSI CODEPAGE, not as UTF-8. An em-dash
# then arrives as the three bytes CP1252 shows as `a€"` — and that
# sequence CONTAINS A DOUBLE QUOTE. Inside a string literal it closes
# the string early and the file dies with "Unexpected token" before its
# first statement; the scheduled task exits having created nothing, and
# the runner sees only missing files, which is indistinguishable from a
# capture that had nothing to collect.
#
# THE RULE IS CODE LINES, NOT ALL LINES, and the difference is measured
# too: tools/guest/desk-warm.ps1 and wait-exit.ps1 have carried
# em-dashes for months and work, because theirs are in WHOLE-LINE
# COMMENTS, where PowerShell ignores the rest of the line and the stray
# quote never tokenizes. A blanket ASCII rule would redden two files
# that are fine and would be turned off; this refuses non-ASCII only
# where it can bite. Nothing else in the tree looks: check-shell walks
# tools/ for .sh and .cmd and never .ps1.
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
# APPENDED RATHER THAN SUBSTITUTED, deliberately. An anchor onto some
# particular line of flightrec.ps1 goes stale the moment that line is
# reworded — it did, on this very clause, the first time the guest half
# was rewritten, and the `applied 0` check is what caught it. What this
# rule is about is CHARACTERS, not a construct, so there is no spelling
# it needs to be proven against.
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
g.verdict("7 clauses, 4 watched perturbations")
