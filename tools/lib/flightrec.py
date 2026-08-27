"""The flight recorder's journal: an append-only JSONL record of what the
lanes ran and how it went.

WHY IT LIVES OUTSIDE THE BUILD TREE. docs/deferred.md's storage-cleanup
entry names the sweep that eats build output: target/ (including
target/validate-failures), .claude/worktrees "and their targets", docker,
the nix store, android build dirs, /private/tmp scratchpads. A recorder
filed under any of those is erased by a routine cleanup, and a dot-dir
under the repo root is worse than it looks — agents work inside
.claude/worktrees/<id>/, so it would resolve INSIDE a worktree the sweep
deletes, and fragment one journal into one per checkout. XDG_STATE_HOME is
the category the spec keeps for exactly this (persistent-but-not-precious
history), it is named by no candidate in that entry, and one home per
machine is what lets two lanes from two worktrees show up in one journal.

Retention is enforced HERE, at run start, and the cap is printed: bundles
live inside the run directory, so dropping the oldest run drops its
bundles with it and a bundle can never outlive its journal record.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

KEEP_DEFAULT = 20


def home():
    if os.environ.get("KAYA_FLIGHTREC_DIR"):
        return pathlib.Path(os.environ["KAYA_FLIGHTREC_DIR"])
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return pathlib.Path(state) / "kaya" / "flightrec"


def keep():
    try:
        n = int(os.environ.get("KAYA_FLIGHTREC_KEEP", KEEP_DEFAULT))
    except ValueError:
        return KEEP_DEFAULT
    return n if n > 0 else KEEP_DEFAULT


def run_dir(run_id):
    return home() / "runs" / run_id


def _cmd(argv, timeout=10):
    """Best effort: a metric no tool on this host can answer is null, never
    a crash and never a guess (invariant 3 — a diagnostic prints what it
    measured)."""
    try:
        out = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 else None


def host_metrics():
    m = {"load1": None, "free_disk_bytes": None, "mem_pressure_pct": None}
    try:
        m["load1"] = round(os.getloadavg()[0], 2)
    except OSError:
        pass
    try:
        st = os.statvfs(str(home().parent if home().exists() else pathlib.Path.home()))
        m["free_disk_bytes"] = st.f_bavail * st.f_frsize
    except OSError:
        pass
    # macOS names free memory as a percentage; linux has MemAvailable.
    text = _cmd(["memory_pressure"])
    if text:
        for line in text.splitlines():
            if "percentage" in line.lower() and "free" in line.lower():
                digits = "".join(c for c in line if c.isdigit())
                if digits:
                    m["mem_pressure_pct"] = 100 - int(digits)
                break
    elif pathlib.Path("/proc/meminfo").exists():
        info = {}
        for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                info[parts[0].rstrip(":")] = int(parts[1])
        total, avail = info.get("MemTotal"), info.get("MemAvailable")
        if total and avail is not None:
            m["mem_pressure_pct"] = round(100 * (total - avail) / total)
    return m


def tree_ids(root):
    ids = {}
    script = pathlib.Path(root) / "tools" / "build-id.sh"
    if not script.is_file():
        return ids
    for component in ("core", "swiftui", "compose"):
        text = _cmd([str(script), component], timeout=120)
        if text and text.strip():
            ids[component] = text.strip().splitlines()[-1].strip()
    return ids


def append(path, record):
    """One record, one line, ONE write: O_APPEND plus a single write keeps a
    line whole against the concurrent leg pools both runners use (the
    simdrive log's rule, tools/ios/simdrive/main.swift)."""
    line = json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
    data = line.encode("utf-8")
    fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def prune(cap):
    """Newest `cap` run directories survive. Returns (pruned, remaining)."""
    runs = home() / "runs"
    if not runs.is_dir():
        return 0, 0
    dirs = sorted((d for d in runs.iterdir() if d.is_dir()), key=lambda d: d.name)
    doomed = dirs[: max(0, len(dirs) - cap)]
    pruned = 0
    for d in doomed:
        try:
            shutil.rmtree(d)
            pruned += 1
        except OSError:
            pass
    return pruned, len(dirs) - pruned


def cmd_start(argv):
    lane, root = argv[0], argv[1]
    run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid():06d}"
    cap = keep()
    (home() / "runs").mkdir(parents=True, exist_ok=True)
    # BEFORE the new run's directory exists, so the cap counts what is kept
    # rather than silently keeping cap+1.
    pruned, remaining = prune(max(0, cap - 1))
    d = run_dir(run_id)
    (d / "bundles").mkdir(parents=True, exist_ok=True)
    append(
        d / "journal.jsonl",
        {
            "rec": "run",
            "run": run_id,
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "lane": lane,
            "tree": tree_ids(root),
            "host": host_metrics(),
            "keep": cap,
            "pruned": pruned,
        },
    )
    # id AND directory on one line: the runner needs the directory to spool
    # into and must not pay a second process to ask for it.
    print(f"{run_id}\t{d}")
    print(
        f"flightrec: journal {d}/journal.jsonl "
        f"(retention: newest {cap} runs, {pruned} pruned, {remaining + 1} kept)",
        file=sys.stderr,
    )
    return 0


def cmd_flush(argv):
    """Turn the runner's spool into journal records, once.

    THE PASS PATH MAY NOT SPAWN A PROCESS. One python3 per leg measured
    27ms on the mac host, and the three ssh round trips beside it took the
    windows lane 110s over its ceiling on the recorder's first matrix
    (docs/deferred.md). A leg now appends one TAB-separated line to a
    spool with a shell `printf` — no subprocess at all — and this runs
    once, at lane end and again from the EXIT trap, so an interrupted lane
    still lands its records.
    """
    run_id, spool = argv[0], pathlib.Path(argv[1])
    d = run_dir(run_id)
    if not d.is_dir() or not spool.is_file():
        return 0
    written = 0
    for line in spool.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        lane, leg, verdict, secs, at_epoch, bundle, fail = parts[:7]
        try:
            seconds = int(secs)
        except ValueError:
            seconds = None
        # The leg's OWN end time, taken by the runner from bash's
        # $EPOCHSECONDS (no subprocess), not the time this flush ran —
        # otherwise every leg in a run shares one timestamp.
        try:
            at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(at_epoch)))
        except ValueError:
            at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        append(
            d / "journal.jsonl",
            {
                "rec": "leg",
                "run": run_id,
                "at": at,
                "lane": lane,
                "leg": leg,
                "verdict": verdict,
                "secs": seconds,
                "fail": fail or None,
                "bundle": bundle or None,
            },
        )
        written += 1
    # Truncated, not deleted: a second flush (the EXIT trap after a normal
    # one) must not write every record twice.
    spool.write_text("", encoding="utf-8")
    print(written)
    return 0


def cmd_leg(argv):
    run_id, lane, leg, verdict, secs = argv[0], argv[1], argv[2], argv[3], argv[4]
    fail = argv[5] if len(argv) > 5 else ""
    bundle = argv[6] if len(argv) > 6 else ""
    d = run_dir(run_id)
    if not d.is_dir():
        print(f"flightrec: no run directory {d}", file=sys.stderr)
        return 1
    try:
        seconds = int(secs)
    except ValueError:
        seconds = None
    append(
        d / "journal.jsonl",
        {
            "rec": "leg",
            "run": run_id,
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "lane": lane,
            "leg": leg,
            "verdict": verdict,
            "secs": seconds,
            "fail": fail or None,
            "bundle": bundle or None,
        },
    )
    return 0


def cmd_bundle(argv):
    run_id, lane, leg = argv[0], argv[1], argv[2]
    d = run_dir(run_id) / "bundles" / f"{lane}-{leg}"
    d.mkdir(parents=True, exist_ok=True)
    print(d)
    return 0


def cmd_size(argv):
    """The bundle's own size, printed by the runner so a bundle that grew
    past its bound is visible at the point it was written."""
    total = 0
    for p in pathlib.Path(argv[0]).rglob("*"):
        if p.is_file():
            total += p.stat().st_size
    print(total)
    return 0


def cmd_home(_argv):
    print(home())
    return 0


COMMANDS = {
    "start": cmd_start,
    "flush": cmd_flush,
    "leg": cmd_leg,
    "bundle": cmd_bundle,
    "size": cmd_size,
    "home": cmd_home,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(f"usage: flightrec.py {{{'|'.join(COMMANDS)}}} ...")
    return COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
