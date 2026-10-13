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

Retention is enforced HERE, at run start, and printed. The newest
KAYA_FLIGHTREC_KEEP runs stay whole. A pruned run's red bundles move to
red/<run>/bundles/ with a copy of the run's journal, and stay there for
KAYA_FLIGHTREC_RED_DAYS, oldest removed first past KAYA_FLIGHTREC_RED_BYTES
(docs/HACKING.md, "read a failed leg"; check-flightrec runs it).
"""

import calendar
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

KEEP_DEFAULT = 20
RED_DAYS_DEFAULT = 90
RED_BYTES_DEFAULT = 2 * 1024 ** 3


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


def _positive(name, default):
    try:
        n = int(os.environ.get(name, default))
    except ValueError:
        return default
    return n if n > 0 else default


def red_days():
    return _positive("KAYA_FLIGHTREC_RED_DAYS", RED_DAYS_DEFAULT)


def red_bytes():
    return _positive("KAYA_FLIGHTREC_RED_BYTES", RED_BYTES_DEFAULT)


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
    script = pathlib.Path(root) / "tools" / "build-id.py"
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
    iOS watcher log's rule, tools/ios/run-sim.py's simdrive_watch)."""
    line = json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
    data = line.encode("utf-8")
    fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def _run_epoch(name, fallback):
    try:
        return calendar.timegm(time.strptime(name[:16], "%Y%m%dT%H%M%SZ"))
    except ValueError:
        return fallback


def _bytes(path):
    total = 0
    for p in path.rglob("*"):
        try:
            if p.is_file() and not p.is_symlink():
                total += p.stat().st_size
        except OSError:
            pass
    return total


def _mb(n):
    if n >= 1024 ** 3:
        return f"{n / 1024 ** 3:.1f} GB"
    return f"{n / 1024 ** 2:.1f} MB" if n >= 1024 ** 2 else f"{n} bytes"


def _journal_copy(src, dest, run_id):
    """The run's journal beside its kept bundles, each leg's `bundle` field
    pointed at where the bundle now lives."""
    out = []
    for line in src.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            out.append(line)
            continue
        if isinstance(rec, dict) and isinstance(rec.get("bundle"), str):
            rec["bundle"] = rec["bundle"].replace(f"/runs/{run_id}/bundles/",
                                                  f"/red/{run_id}/bundles/")
        out.append(json.dumps(rec, sort_keys=True, separators=(",", ":")))
    dest.write_text("".join(f"{line}\n" for line in out), encoding="utf-8")


def prune(cap, *, now=None, days=None, limit=None, dry=False, every=False,
          say=None):
    """Newest `cap` run directories survive whole; an older run's red bundles
    move to red/ before the run goes; red/ is then held to `days` and
    `limit` bytes, oldest bundle first. Every move and removal is printed,
    and the kept bundles as a total (each one too with `every`).
    Returns (pruned, remaining)."""
    now = time.time() if now is None else now
    days = red_days() if days is None else days
    limit = red_bytes() if limit is None else limit
    if say is None:
        def say(line):
            print(f"flightrec: {line}", file=sys.stderr)
    would = "would " if dry else ""
    runs, red = home() / "runs", home() / "red"
    dirs = sorted((d for d in runs.iterdir() if d.is_dir()),
                  key=lambda d: d.name) if runs.is_dir() else []
    doomed = dirs[: max(0, len(dirs) - cap)]
    kept = []
    if red.is_dir():
        for run in sorted(d for d in red.iterdir() if d.is_dir()):
            if (run / "bundles").is_dir():
                kept += [(run.name, b) for b in sorted((run / "bundles").iterdir())
                         if b.is_dir()]
    pruned = 0
    for d in doomed:
        bundles = (sorted(b for b in (d / "bundles").iterdir() if b.is_dir())
                   if (d / "bundles").is_dir() else [])
        stuck = 0
        for b in bundles:
            dest = red / d.name / "bundles" / b.name
            if dry:
                say(f"would move red bundle {b} -> {dest}")
                kept.append((d.name, b))
                continue
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                journal = red / d.name / "journal.jsonl"
                if (d / "journal.jsonl").is_file() and not journal.exists():
                    _journal_copy(d / "journal.jsonl", journal, d.name)
                os.rename(b, dest)
            except OSError as e:
                if b.exists():
                    stuck += 1
                    say(f"could not move red bundle {b} to {dest} ({e}); "
                        f"run {d.name} is kept whole")
                continue
            say(f"moved red bundle {b} -> {dest}")
            kept.append((d.name, dest))
        if stuck:
            continue
        what = f"{len(bundles)} red bundle(s) moved out" if bundles else "no red bundle"
        if dry:
            say(f"would remove run {d} ({what})")
            pruned += 1
            continue
        try:
            shutil.rmtree(d)
        except FileNotFoundError:
            continue
        except OSError as e:
            say(f"could not remove run {d} ({e})")
            continue
        say(f"removed run {d} ({what})")
        pruned += 1
    sized = sorted(((run, path, _bytes(path)) for run, path in kept),
                   key=lambda k: (k[0], k[1].name))
    horizon = now - days * 86400
    expired = [k for k in sized
               if _run_epoch(k[0], k[1].stat().st_mtime if k[1].exists() else now)
               < horizon]
    sized = [k for k in sized if k not in expired]
    total = sum(k[2] for k in sized)
    over = []
    while sized and total > limit:
        over.append(sized.pop(0))
        total -= over[-1][2]
    for why, gone in ((f"older than {days} days", expired),
                      (f"oldest past the {_mb(limit)} bound", over)):
        for run, path, size in gone:
            target = red / run / "bundles" / path.name
            if dry:
                say(f"would remove red bundle {target} ({_mb(size)}, {why})")
                continue
            shutil.rmtree(target, ignore_errors=True)
            say(f"removed red bundle {target} ({_mb(size)}, {why})")
            left = red / run / "bundles"
            try:
                if not any(left.iterdir()):
                    shutil.rmtree(red / run, ignore_errors=True)
            except OSError:
                pass
    if every:
        for run, path, size in sized:
            say(f"{would}keep red bundle {red / run / 'bundles' / path.name} "
                f"({_mb(size)})")
    oldest = f", oldest from run {sized[0][0]}" if sized else ""
    say(f"red bundles {'that would be ' if dry else ''}kept under {red}: "
        f"{len(sized)}, {_mb(total)} of {_mb(limit)}, {days} days{oldest}; "
        f"{len(expired)} {'would be ' if dry else ''}removed by age, {len(over)} by size")
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


def cmd_prune(argv):
    """By hand: `flightrec.py prune [--dry-run]` prints the whole plan, every
    kept red bundle included; with --dry-run nothing is moved or removed."""
    dry = argv == ["--dry-run"]
    if argv and not dry:
        print("usage: flightrec.py prune [--dry-run]", file=sys.stderr)
        return 2
    pruned, remaining = prune(keep(), dry=dry, every=True,
                              say=lambda line: print(f"flightrec: {line}"))
    print(f"flightrec: runs: newest {keep()} kept whole, {pruned} "
          f"{'would be ' if dry else ''}pruned, {remaining} "
          f"{'would ' if dry else ''}remain")
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
    "prune": cmd_prune,
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
