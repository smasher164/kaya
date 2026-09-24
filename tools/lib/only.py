"""ONE FILTER ON THE MATRIX (the maintainer, 2026-09-24: "you only need one
filter on the matrix"): `KAYA_ONLY` is a comma-separated list of leg-name
PREFIXES, and every lane runs exactly the legs whose name starts with one
of them. `tools/validate-all.py --only clock24,tasksrtl` hands it to all
five lanes; each lane reads it through this module (the container's shell
runner spells the same loop in tools/linux/run-suites.sh, and
tools/check-gates.py holds the two equal).

A filtered run is a DEBUGGING TOOL, never the record: a lane whose roster
has no matching leg is not launched, a lane that finds none at run time
leaves with `REFUSED` (exit 3) rather than a verdict over nothing, the gate
sweep is not run, and the matrix's own verdict line says FILTERED. The
commit's record is still one plain run on the frozen tree.
"""
import os
import sys

REFUSED = 3
PREFIXES = [p for p in os.environ.get("KAYA_ONLY", "").split(",") if p]


def active():
    return bool(PREFIXES)


def wanted(name):
    """Whether a leg of this name runs under the filter (every leg with no
    filter)."""
    return not PREFIXES or any(name.startswith(p) for p in PREFIXES)


def matches(names):
    return [n for n in names if wanted(n)]


def summary(runner, selected):
    """Print the filtered run's line, or the refusal and leave with
    REFUSED. `selected` is how many legs this runner queued."""
    if not PREFIXES:
        return
    spelled = ",".join(PREFIXES)
    if selected == 0:
        print(f"{runner}: KAYA_ONLY={spelled!r} matched no leg of this runner "
              f"— no verdict", file=sys.stderr)
        sys.exit(REFUSED)
    print(f"{runner}: filtered run — KAYA_ONLY={spelled}, {selected} leg(s)")
