#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# The gate for the gate cache (tools/keyed.py): what would make it skip
# something it shouldn't, asked seven ways.

import atexit
import contextlib
import json
import os
import subprocess

FIXTURE = "keyed-selftest"
STORE = ROOT / "target/.kaya-gates"
INSIDE = ROOT / "tools/.keyed-probe"  # tools/ rides every gate key
# target/ is NOT in the fixture's set
OUTSIDE = ROOT / "target/.keyed-probe-outside"

# docs/traps.md, "A cache self-test outside its own key can still
# invalidate Cargo".
if not str(OUTSIDE).startswith(str(ROOT / "target") + os.sep):
    print(f"check-keyed: OUTSIDE probe has 1 unsafe target: {OUTSIDE}.",
          file=sys.stderr)
    print(f"  Keep it under {ROOT}/target/ — outside keyed-selftest's "
          f"inputs and Cargo's source inputs.", file=sys.stderr)
    sys.exit(1)


def cleanup():
    for p in (INSIDE, OUTSIDE, STORE / FIXTURE):
        with contextlib.suppress(FileNotFoundError):
            p.unlink()


atexit.register(cleanup)
cleanup()

status = 0


def fail(msg):
    global status
    print(f"check-keyed: {msg}", file=sys.stderr)
    status = 1


def keyed(*cmd, fast=True):
    """tools/keyed.py on the fixture; (rc, combined-output). `true`/
    `false` rather than a real gate: what is under test is the wrapper's
    decision."""
    env = dict(os.environ)
    if fast:
        env["KAYA_FAST"] = "1"
    else:
        env.pop("KAYA_FAST", None)
    run = subprocess.run(["tools/keyed.py", FIXTURE, "--", *cmd], cwd=ROOT,
                         env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, check=False)
    return run.returncode, run.stdout


# 1. First run executes; second run skips.
_, out = keyed("true")
if "CACHED" in out:
    fail("a gate with no stored key was reported CACHED")
_, out = keyed("false")
if "CACHED" not in out:
    fail(f"an unchanged tree re-ran the gate (no cutoff at all): {out}")

# 2. A change INSIDE the input set must re-run it. `false` as the
# command makes a re-run visible as a non-zero exit.
INSIDE.touch()
rc, _ = keyed("false")
if rc == 0:
    fail("a change under tools/ did not invalidate the key")
INSIDE.unlink()

# 3. A change OUTSIDE the input set must NOT re-run it — without this
# the keys are one global dirty bit.
keyed("true")
OUTSIDE.touch()
_, out = keyed("false")
if "CACHED" not in out:
    fail(f"a change outside the input set busted the key — no cutoff: {out}")
OUTSIDE.unlink()

# 4. A FAILING gate must never be stored.
with contextlib.suppress(FileNotFoundError):
    (STORE / FIXTURE).unlink()
keyed("false")
_, out = keyed("true")
if "CACHED" in out:
    fail("a FAILED gate was cached — the next run would skip it green")
with contextlib.suppress(FileNotFoundError):
    (STORE / FIXTURE).unlink()

# 5. Without KAYA_FAST the cache is never CONSULTED. The variable is
# REMOVED from the child's environment, not merely unset here: this gate
# runs inside lanes that may have exported KAYA_FAST=1, and a clause
# that inherits the variable it claims to have unset tests the opposite
# of what it says.
keyed("true")
_, out = keyed("echo", "ran", fast=False)
if out.strip() != "ran":
    fail(f"KAYA_FAST unset still consulted the cache (matrix runs must be "
         f"clean): {out}")

# 5b. ...but an unset run's PASS is RECORDED, so the first fast run
# after a full sweep is warm — and an unset run's FAILURE clears any
# stamp, the never-cache-a-failure rule on the recording path too.
with contextlib.suppress(FileNotFoundError):
    (STORE / FIXTURE).unlink()
keyed("true", fast=False)
_, out = keyed("echo", "ran")
if "CACHED" not in out:
    fail(f"a full run's pass was not recorded — the first fast run after "
         f"every full sweep starts cold: {out}")
keyed("false", fast=False)
_, out = keyed("echo", "ran")
if out.strip() != "ran":
    fail(f"a full run's FAILURE left a stamp behind — the next fast run "
         f"would skip a red gate: {out}")

# 5c. THE ARTIFACT HALF OF A KEY FOLLOWS THE EMBEDDED BUILD-ID. Two
# staged roots whose artifact carries a DIFFERENT marker must yield
# different keys; the SAME marker with different surrounding bytes must
# yield the same key (that is the point — every relink mints a new
# LC_UUID, and the marker is what says which sources the artifact came
# from); and no marker at all must differ from both. Proven through the
# KAYA_GATE_ARTIFACT_ROOT seam, which exists for exactly this clause.
def gate_key(root):
    return subprocess.run(
        ["tools/build-id.py", "--gate", "check-abort"], cwd=ROOT,
        env=dict(os.environ, KAYA_GATE_ARTIFACT_ROOT=str(root)),
        stdout=subprocess.PIPE, text=True, check=False).stdout


with scratch_dir("check-keyed-art-") as art:
    (art / "a/target/debug").mkdir(parents=True)
    (art / "b/target/debug").mkdir(parents=True)
    lib_a = art / "a/target/debug/libkaya.dylib"
    lib_b = art / "b/target/debug/libkaya.dylib"
    lib_a.write_text("xx kaya-build-id:aaaaaaaaaaaaaaaa yy", encoding="utf-8")
    lib_b.write_text("xx kaya-build-id:bbbbbbbbbbbbbbbb yy", encoding="utf-8")
    ka = gate_key(art / "a")
    if ka == gate_key(art / "b"):
        fail("two different embedded build-ids produced ONE key — the "
             "artifact half of the key is not being read")
    lib_b.write_text("DIFFERENT BYTES kaya-build-id:aaaaaaaaaaaaaaaa other "
                     "tail", encoding="utf-8")
    if ka != gate_key(art / "b"):
        fail("one embedded build-id produced two keys — the key is hashing "
             "relink noise and will never hit")
    lib_b.write_text("no marker here at all", encoding="utf-8")
    if ka == gate_key(art / "b"):
        fail("an artifact with NO build-id marker keyed like a marked one")


# 6 and 7 read tools/gates.py's list, with a vacuity floor inside — a
# census that finds almost nothing is a broken census, not a clean tree.
#
#   6. The gates that read a BUILT ARTIFACT must be keyed WITH that
#      artifact's bytes in their key (build-id.py's ARTIFACT_GATES;
#      ratified 2026-08-20) — sources can sit unchanged while target/
#      holds something else, and the bytes are what close that gap.
#      check-build-id alone stays unkeyed forever: caching the
#      staleness gate's answer is the defect it exists to find.
#   7. Everything that IS wrapped must have an input set, or keyed.py
#      dies at run time inside a lane instead of here.
def keyed_census():
    census_status = 0
    listed = subprocess.run(["tools/gates.py", "--list"], cwd=ROOT,
                            stdout=subprocess.PIPE, text=True, check=False)
    if listed.returncode != 0:
        print("check-keyed: tools/gates.py --list failed — the "
              "wrapped/unwrapped census could not be read, so nothing was "
              "checked", file=sys.stderr)
        return 1, None
    gates = {g["name"]: g for g in json.loads(listed.stdout)["gates"]}
    if len(gates) < 10:
        print(f"check-keyed: only {len(gates)} gates in tools/gates.py's "
              f"list — the list or its format moved and this census went "
              f"vacuous", file=sys.stderr)
        return 1, None

    artifact_gates = ("check-abort", "check-wheel", "check-empty-child",
                      "check-pane-ladder", "check-table-tier")
    for name in artifact_gates:
        g = gates.get(name)
        if g is None:
            print(f"check-keyed: {name} is not in the sweep at all, so the "
                  f"artifact-key rule is checking nothing", file=sys.stderr)
            census_status = 1
            continue
        if not g["keyed"]:
            print(f"check-keyed: {name} reads a built artifact and is not "
                  f"keyed — key it on its sources plus the artifact's bytes "
                  f"(build-id.py's ARTIFACT_GATES)", file=sys.stderr)
            census_status = 1
        arts = subprocess.run(
            ["tools/build-id.py", "--gate-artifacts", name], cwd=ROOT,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            check=False).stdout.strip()
        if arts == "":
            print(f"check-keyed: {name} has no ARTIFACT_GATES entry in "
                  f"build-id.py — its key would be sources alone, which is "
                  f"the stale-PASS loophole the artifact half exists to "
                  f"close", file=sys.stderr)
            census_status = 1
    g = gates.get("check-build-id")
    if g is None:
        print("check-keyed: check-build-id is not in the sweep at all",
              file=sys.stderr)
        census_status = 1
    elif g["keyed"]:
        print("check-keyed: check-build-id is keyed — caching the staleness "
              "gate's answer is the defect it exists to find",
              file=sys.stderr)
        census_status = 1

    wrapped = sorted(n for n, g in gates.items() if g["keyed"])
    for name in wrapped:
        if subprocess.run(["tools/build-id.py", "--gate", name], cwd=ROOT,
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL,
                          check=False).returncode != 0:
            print(f"check-keyed: {name} is wrapped by keyed.py but has no "
                  f"entry in build-id.py's GATES", file=sys.stderr)
            census_status = 1

    # An UNKEYED gate must say why, in the list, beside itself.
    for name, g in sorted(gates.items()):
        if not g["keyed"] and len(g["unkeyed_because"].strip()) < 20:
            print(f"check-keyed: {name} is not keyed and gives no reason — "
                  f"state it in tools/gates.py's list, next to the gate",
                  file=sys.stderr)
            census_status = 1
    return census_status, len(wrapped)


census_status, keyedcount = keyed_census()
if census_status != 0:
    status = 1

# A gate that READS a file it does not DECLARE is a false-PASS machine
# under KAYA_FAST, and it misfires exactly when the undeclared file is
# what changed.
if subprocess.run([sys.executable, "tools/lib/keyed-inputs.py"], cwd=ROOT,
                  check=False).returncode != 0:
    status = 1

if status == 0:
    print(f"check-keyed: OK ({keyedcount} gates keyed)")
else:
    print("check-keyed: FINDINGS ABOVE")
sys.exit(status)
