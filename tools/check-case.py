#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# EVERY TRACKED PATH MUST MATCH THE FILESYSTEM'S CASE EXACTLY
# (CLAUDE.md's gate list for the defect it exists for). macOS is
# case-insensitive and Linux is not, and every build manifest here names
# files as strings — cabal `main-is`, dune `modules`, Cargo `path`,
# csproj globs, gradle sources, the Makefile's SCENES.

import os
import subprocess


def lint(paths, cwd):
    """Offender lines — a name present only under a different case."""
    bad = []
    # One listing per directory, reused: a repo-wide walk otherwise costs
    # a stat per path per component.
    listings = {}
    for path in paths:
        if not path:
            continue
        parent, name = os.path.split(path)
        key = parent or "."
        if key not in listings:
            try:
                listings[key] = set(os.listdir(os.path.join(cwd, key)))
            except OSError:
                listings[key] = set()
        entries = listings[key]
        if name in entries:
            continue
        # Present only under a different case is THE defect; absent
        # entirely is someone else's problem.
        lower = {e.lower(): e for e in entries}
        actual = lower.get(name.lower())
        if actual is not None:
            bad.append(f"{path}: git says {name!r}, "
                       f"the filesystem says {actual!r}")
    return bad


# Self-test, both directions: a case-only mismatch caught, an exact
# match not. A REAL fixture on the real filesystem — the case behavior
# under test is the filesystem's, not python's.
with scratch_dir("check-case-") as tmp:
    (tmp / "case").mkdir()
    (tmp / "case/background.hs").touch()
    if not lint([str(tmp / "case/Background.hs")], "/"):
        print("check-case: SELF-TEST FAIL (a case-only mismatch passed)",
              file=sys.stderr)
        sys.exit(1)
    if lint([str(tmp / "case/background.hs")], "/"):
        print("check-case: SELF-TEST FAIL (an exact match was rejected)",
              file=sys.stderr)
        sys.exit(1)

tracked = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT,
                         stdout=subprocess.PIPE, text=True, check=False)
bad = lint(tracked.stdout.split("\0"), str(ROOT))
# The old body printed lint's joined output unconditionally, blank line
# included on a clean run; kept for byte parity with the shell gate.
print("\n".join(bad))
if bad:
    print("check-case: a tracked path disagrees with the filesystem in CASE.",
          file=sys.stderr)
    print("check-case: macOS will not notice; Linux will fail the lane. "
          "Rename", file=sys.stderr)
    print("check-case: THROUGH A TEMP PATH — a case-only mv is a no-op here.",
          file=sys.stderr)
    sys.exit(1)
print("check-case: OK")
