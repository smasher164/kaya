"""The recorded bench file's shape — one source, so two platforms'
records diff against each other and against last month's.

A record is a comment header (what was measured, on what, from which
sources) followed by one `key=value` line per run and one per summary.
Nothing is aligned by padding: a column that moves when a number gets
wider makes every later line a spurious diff.
"""

import datetime
import os
import platform
import subprocess


def _git(root, *args):
    try:
        out = subprocess.run(["git", "-C", root, *args], capture_output=True,
                             text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    rc = out.returncode
    if rc != 0:
        return "unknown"
    return out.stdout.strip() or "unknown"


def line(**fields):
    """One run or summary line: key=value, space separated, insertion order."""
    return " ".join("%s=%s" % (k, v) for k, v in fields.items())


def header(root, bench, argv, extra=None):
    """The provenance block. A number nobody can attribute to a tree, a
    host and a command is not a measurement."""
    rev = _git(root, "rev-parse", "--short", "HEAD")
    dirty = _git(root, "status", "--porcelain")
    tree = "clean" if dirty in ("", "unknown") else "DIRTY (%d path(s))" % len(
        dirty.splitlines())
    uname = platform.uname()
    out = [
        "# kaya table bench — %s" % bench,
        "# recorded %s" % datetime.datetime.now(
            datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "# host: %s %s, %s cpu" % (uname.system, uname.machine,
                                   os.cpu_count()),
        "# repo: %s, working tree %s" % (rev, tree),
        "# command: %s" % " ".join(argv),
    ]
    for k, v in (extra or {}):
        out.append("# %s: %s" % (k, v))
    out.append("#")
    out.append("# What each key means, and what the 2026-08-24 baseline was:")
    out.append("#   docs/measurements/README.md")
    return "\n".join(out)
