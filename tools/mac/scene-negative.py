#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# A SCENE NEGATIVE THAT CANNOT PASS VACUOUSLY (docs/traps.md, the capture
# rate cut that read green once): one cut in the tree, one mac leg, and a
# verdict only when the leg went red WITH THE NAMED SENTENCE out of THIS
# run's own output, from artifacts that carried the doctored tree's id
# before AND after the leg, with no host sleep inside the window. The cut
# is restored from a saved copy and its sha256 compared.
#
#   tools/mac/scene-negative.py <scene> <lang> <file> <pattern> <repl> <red>
#
# Exit 0: watched red. Exit 1: the negative proved nothing (it says why).
# The tree is doctored while the leg runs: nothing else may build then.

import datetime
import hashlib
import re
import shutil
import subprocess

ARTIFACTS = (("libkaya", "target/debug/libkaya.dylib", []),
             ("swiftui", "target/swiftui/libkaya_swiftui.dylib", ["--component", "swiftui"]))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stale_artifacts():
    """The artifacts that do NOT carry the tree's id right now."""
    bad = []
    for what, rel, extra in ARTIFACTS:
        verify = [str(ROOT / "tools/build-id.py"), "--verify", *extra, str(ROOT / rel)]
        got = subprocess.run(verify, cwd=ROOT, capture_output=True, text=True,
                             encoding="utf-8", check=False)
        if got.returncode != 0:
            bad.append(f"{what} ({rel}): {(got.stdout + got.stderr).strip()}")
    return bad


def sleeps_between(start, end):
    """pmset's Sleep entries inside the window, as their log lines."""
    log = subprocess.run(["pmset", "-g", "log"], capture_output=True, text=True, encoding="utf-8",
                         errors="replace", check=False).stdout
    hits = []
    for line in log.splitlines():
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) [+-]\d{4} (Sleep|Wake)\s", line)
        if not m:
            continue
        at = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
        if start <= at <= end:
            hits.append(line.strip())
    return hits


def main(argv):
    if len(argv) != 7:
        print("usage: tools/mac/scene-negative.py <scene> <lang> <file> <pattern> <repl> "
              "<red sentence>", file=sys.stderr)
        return 2
    scene, lang, rel, pattern, repl, red = argv[1:]
    target = ROOT / rel
    # KEPT OUTSIDE ANY SCRATCH THAT CLEANS ITSELF: it is deleted only after
    # a restore whose sha256 matched.
    saved = ROOT / "target/scene-negative" / (target.name + ".saved")
    saved.parent.mkdir(parents=True, exist_ok=True)
    if saved.exists():
        print(f"scene-negative: REFUSED — {saved} exists: an earlier run did not restore. "
              f"Compare it with {rel} and put the right one back first", file=sys.stderr)
        return 1
    shutil.copy2(target, saved)
    before = sha(saved)
    text = target.read_text(encoding="utf-8")
    doctored = Gate("scene-negative").doctor(rel, text, pattern, repl)
    findings = []
    start = datetime.datetime.now()
    try:
        target.write_text(doctored, encoding="utf-8")
        run = subprocess.run([str(ROOT / "tools/run-leg.py"), scene, lang, "--build"], cwd=ROOT,
                             capture_output=True, text=True, encoding="utf-8", errors="replace",
                             check=False)
        out = run.stdout + run.stderr
        print(f"scene-negative: the leg exited {run.returncode}; its last lines:")
        for line in out.splitlines()[-12:]:
            print(f"  | {line}")
        if run.returncode == 0:
            findings.append("the leg went GREEN with the cut in the tree")
        if "run-leg: build failed" in out or "guest build failed" in out:
            findings.append("the build failed, so no leg read the cut "
                            "(a red build is not a red leg)")
        if red not in out:
            findings.append(f"the leg's own output never says {red!r}")
        stale = stale_artifacts()
        if stale:
            findings.append("after the leg, an artifact no longer carries the doctored tree's id — "
                            "something rebuilt it while the leg ran: " + "; ".join(stale))
    finally:
        shutil.copy2(saved, target)
        after = sha(target)
        print(f"scene-negative: restored {rel} from {saved}, sha256 {after[:16]} "
              f"{'==' if after == before else '!='} {before[:16]}")
        if after != before:
            findings.append(f"THE RESTORE FAILED: {rel} differs from its saved copy {saved}")
        else:
            saved.unlink()
    slept = sleeps_between(start, datetime.datetime.now())
    if slept:
        findings.append("the host slept inside the window, so the run is discarded: "
                        + " | ".join(slept))
    if findings:
        print("scene-negative: NOT WATCHED — " + "; ".join(findings), file=sys.stderr)
        return 1
    print(f"scene-negative: WATCHED RED — {scene}-{lang} said {red!r} from the doctored build")
    return None


raise SystemExit(main(sys.argv))
