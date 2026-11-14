#!/usr/bin/env python3
"""Removes the cargo units no build has read in UNIT_DAYS and the incremental
caches idle for INCREMENTAL_DAYS from every cargo profile under the given
directories. Stdlib only: the linux lane runs it inside its container over the
target volume. Why it arms atimes and keeps a ledger: docs/traps.md, the host's
atime is not last use.

  python3 tools/lib/target_sweep.py [--dry-run] DIR...    self-test, then sweep each DIR
"""
import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

UNIT_DAYS = 14
INCREMENTAL_DAYS = 3
LOCK_WAIT = 5
DAY = 86400
HASH = re.compile(r"-([0-9a-f]{16})(?=\.|$)")
UNIT_DIRS = ("deps", "build", "examples")
LEDGER = ".kaya-target-sweep.json"


def profiles(root, depth=4):
    """Every directory under `root` holding a cargo `.fingerprint`."""
    out = []
    try:
        entries = list(os.scandir(root))
    except OSError:
        return out
    if any(e.name == ".fingerprint" and e.is_dir(follow_symlinks=False) for e in entries):
        return [root]
    if depth:
        for e in sorted(entries, key=lambda e: e.name):
            if e.is_dir(follow_symlinks=False) and not e.name.startswith("."):
                out += profiles(e.path, depth - 1)
    return out


def last_use(path):
    """The newest atime or mtime of any file at or under `path`. A directory's
    atime is left out: listing it, as this sweep and du do, moves it."""
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode):
        return max(st.st_atime, st.st_mtime)
    newest = st.st_mtime
    for root, dirs, files in os.walk(path):
        for name in dirs:
            newest = max(newest, os.lstat(os.path.join(root, name)).st_mtime)
        for name in files:
            s = os.lstat(os.path.join(root, name))
            newest = max(newest, s.st_atime, s.st_mtime)
    return newest


def arm(fp):
    """Every file's atime just under its mtime, so the next read moves it."""
    for name in os.listdir(fp):
        p = os.path.join(fp, name)
        st = os.lstat(p)
        if stat.S_ISREG(st.st_mode) and st.st_mtime >= 1 and st.st_atime >= st.st_mtime:
            os.utime(p, (st.st_mtime - 1, st.st_mtime))


def size(path):
    seen, total = set(), 0
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            st = os.lstat(os.path.join(root, name))
            if (st.st_dev, st.st_ino) not in seen:
                seen.add((st.st_dev, st.st_ino))
                total += st.st_blocks * 512
    return total


def unshared(paths):
    """The bytes removing `paths` would free: files no other link holds."""
    total = 0
    for path in paths:
        for root, _dirs, files in os.walk(path) if os.path.isdir(path) else [("", [], [path])]:
            for name in files:
                st = os.lstat(os.path.join(root, name))
                total += st.st_blocks * 512 if st.st_nlink == 1 else 0
    return total


def units(profile):
    """{hash: (fingerprint dir or None, [the unit's deps/build/examples paths])}."""
    out = {}
    for e in os.scandir(os.path.join(profile, ".fingerprint")):
        m = HASH.search(e.name)
        if m and e.is_dir(follow_symlinks=False):
            out[m.group(1)] = (e.path, [])
    for leaf in UNIT_DIRS:
        d = os.path.join(profile, leaf)
        if not os.path.isdir(d):
            continue
        for e in os.scandir(d):
            m = HASH.search(e.name)
            if m:
                out.setdefault(m.group(1), (None, []))[1].append(e.path)
    return out


def load_ledger(profile):
    try:
        with open(os.path.join(profile, LEDGER), encoding="utf-8") as f:
            got = json.load(f)
        return got if isinstance(got, dict) else None
    except (OSError, ValueError):
        return None


def save_ledger(profile, seen):
    tmp = os.path.join(profile, LEDGER + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(seen, f)
    os.replace(tmp, os.path.join(profile, LEDGER))


READS = {"every": "atime moves on a read", "lax": "atime moves only below mtime, armed",
         "never": "atime never moves, no unit judged"}


def atime_mode(profile):
    """How this filesystem's atime answers a read: "every" (strictatime, or
    relatime past a day), "lax" (only an atime below mtime moves, APFS's
    default) or "never" (noatime)."""
    probe = os.path.join(profile, ".kaya-atime-probe")
    moved = []
    for atime, mtime in ((2, 3), (3, 2)):
        with open(probe, "w", encoding="utf-8") as f:
            f.write("x")
        now = time.time()
        os.utime(probe, (now - atime * DAY, now - mtime * DAY))
        with open(probe, encoding="utf-8") as f:
            f.read()
        moved.append(os.stat(probe).st_atime > now - DAY)
    os.unlink(probe)
    return "every" if moved[0] else "lax" if moved[1] else "never"


def judge(profile, now, mode):
    """(the stale units, fingerprint first in each; {hash: last use} for the rest;
    whether the profile had a ledger). A unit's last use is its ledger entry or
    its fingerprint's file times, whichever is newer, and one whose fingerprint
    is gone is judged by its own files. Where atime is lax a profile with no
    ledger has never been armed, so its units start their UNIT_DAYS from now."""
    ledger = load_ledger(profile)
    judged = mode == "every" or (mode == "lax" and ledger is not None)
    doomed, seen = [], {}
    for h, (fp, files) in units(profile).items():
        if fp is None:
            if now - max(last_use(p) for p in files) > UNIT_DAYS * DAY:
                doomed.append(files)
            continue
        used = max(float((ledger or {}).get(h, 0)), last_use(fp))
        if judged and now - used > UNIT_DAYS * DAY:
            doomed.append([fp] + files)
        else:
            seen[h] = used if judged else now
    return doomed, seen, ledger is not None


def remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)


def stale_incremental(profile, now):
    d = os.path.join(profile, "incremental")
    if not os.path.isdir(d):
        return []
    out = []
    for e in os.scandir(d):
        if not e.is_dir(follow_symlinks=False):
            continue
        sessions = [os.lstat(s.path).st_mtime for s in os.scandir(e.path)]
        if now - max(sessions, default=0) > INCREMENTAL_DAYS * DAY:
            out.append(e.path)
    return out


def cargo_lock(profile, wait):
    """Cargo's own lock on this profile, which every build holds; None after `wait` seconds."""
    f = open(os.path.join(profile, ".cargo-lock"), "a", encoding="utf-8")  # noqa: SIM115
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return f
        except BlockingIOError:
            if time.monotonic() >= deadline:
                f.close()
                return None
            time.sleep(0.5)


def gb(n):
    return f"{n / 1e9:.2f} GB"


def note(mode, had, seen):
    return f"; {READS[mode]}" + ("" if had or mode != "lax" else
                                 f"; FIRST SWEEP of this profile: {len(seen)} units "
                                 f"recorded, none judged before {UNIT_DAYS} days")


def dry_profile(profile, say, now):
    mode = atime_mode(profile)
    doomed, seen, had = judge(profile, now, mode)
    idle = stale_incremental(profile, now)
    say(f"target-sweep: {profile}: DRY RUN, would remove {len(doomed)} units unread for "
        f"{UNIT_DAYS} days ({gb(unshared(p for u in doomed for p in u))}) and {len(idle)} "
        f"incremental caches idle for {INCREMENTAL_DAYS} days ({gb(unshared(idle))}); "
        f"{gb(size(profile))} now" + note(mode, had, seen))
    return 0


def sweep_profile(profile, say, wait=LOCK_WAIT, now=None, mode=None):
    """Sweeps one profile; returns the bytes it freed."""
    t0 = time.monotonic()
    lock = cargo_lock(profile, wait)
    if lock is None:
        say(f"target-sweep: {profile}: SKIPPED, a cargo build held its lock for {wait}s; "
            f"nothing removed, {gb(size(profile))} as it stands")
        return 0
    with lock:
        now = time.time() if now is None else now
        mode = mode or atime_mode(profile)
        before = size(profile)
        doomed, seen, had = judge(profile, now, mode)
        for unit in doomed:
            for path in unit:
                remove(path)
        for h, (fp, _files) in units(profile).items():
            if fp is not None and h in seen:
                arm(fp)
        save_ledger(profile, seen)
        mid = size(profile)
        idle = stale_incremental(profile, now)
        for path in idle:
            shutil.rmtree(path)
        after = size(profile)
    say(f"target-sweep: {profile}: removed {len(doomed)} units unread for {UNIT_DAYS} days "
        f"({gb(max(0, before - mid))}) and {len(idle)} incremental caches idle for "
        f"{INCREMENTAL_DAYS} days ({gb(mid - after)}); {gb(after)} after, "
        f"{time.monotonic() - t0:.1f}s" + note(mode, had, seen))
    return max(0, before - after)


def sweep(roots, say=print, wait=LOCK_WAIT, dry=False):
    freed = 0
    for root in roots:
        found = profiles(root)
        if not found:
            say(f"target-sweep: {root}: no cargo profile (no .fingerprint) within four levels")
        for profile in found:
            try:
                freed += (dry_profile(profile, say, time.time()) if dry
                          else sweep_profile(profile, say, wait))
            except OSError as error:
                say(f"target-sweep: {profile}: FAILED, {error}")
    return freed


# ---------------------------------------------------------------- self-test

A, B, C, D, E = ("a" * 16, "b" * 16, "c" * 16, "d" * 16, "e" * 16)


def plant(profile, now, ledger, judged):
    """old: last seen 20 days ago, its fingerprint DIRECTORY just listed; fresh:
    last seen 20 days ago, its fingerprint read since (atime past mtime); reread:
    its files 20 days old, last seen yesterday; gone: an old unit whose
    fingerprint was deleted; young: a new one likewise; an unhashed artifact;
    an incremental cache idle 5 days and one with a session from yesterday."""
    old, day = now - 20 * DAY, now - DAY

    def put(rel, at=old, atime=None):
        p = os.path.join(profile, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write("x")
        os.utime(p, (atime if atime is not None else at - 1, at))

    for name, h, fp_atime in (("old", A, None), ("fresh", B, now), ("reread", C, None)):
        put(f".fingerprint/{name}-{h}/lib-{name}", atime=fp_atime)
        put(f".fingerprint/{name}-{h}/dep-lib-{name}", atime=fp_atime)
        put(f"deps/lib{name}-{h}.rlib")
        put(f"deps/{name}-{h}.d")
        put(f"build/{name}-{h}/out/gen.rs")
        put(f"examples/{name}-{h}")
        for d in (f".fingerprint/{name}-{h}", f"build/{name}-{h}/out", f"build/{name}-{h}"):
            os.utime(os.path.join(profile, d), (now, old))
    put(f"deps/libgone-{D}.rlib")
    put(f"deps/gone-{D}.0abc.rcgu.o")
    put(f"deps/libyoung-{E}.rlib", at=day)
    put("deps/libkaya.dylib")
    for crate, sessions in (("idle-1aaaa", (5, 6)), ("busy-1bbbb", (9, 1))):
        for n, age in enumerate(sessions):
            s = os.path.join(profile, "incremental", crate, f"s-{n}")
            os.makedirs(s)
            os.utime(s, (now - age * DAY, now - age * DAY))
    if ledger:
        save_ledger(profile, {A: old, B: old, C: day})
    gone = {f"deps/libgone-{D}.rlib", f"deps/gone-{D}.0abc.rcgu.o", "incremental/idle-1aaaa"}
    for name, h in (("old", A), ("reread", C)) if judged else ():
        if name == "old" or not ledger:
            gone |= {f".fingerprint/{name}-{h}", f"deps/lib{name}-{h}.rlib",
                     f"deps/{name}-{h}.d", f"build/{name}-{h}", f"examples/{name}-{h}"}
    return gone


def listing(profile):
    out = set()
    for leaf in (".fingerprint", *UNIT_DIRS, "incremental"):
        d = os.path.join(profile, leaf)
        if os.path.isdir(d):
            out.update(f"{leaf}/{n}" for n in os.listdir(d))
    return out


def findings(sweep_fn, scratch, label, held=False, ledger=True, mode="lax"):
    profile = os.path.join(scratch, label, "debug")
    now = time.time()
    judged = mode in ("every", "lax" if ledger else "every")
    gone = plant(profile, now, ledger, judged)
    planted = listing(profile)
    want_gone = set() if held else gone
    said = []
    blocker = open(os.path.join(profile, ".cargo-lock"), "a", encoding="utf-8")  # noqa: SIM115
    if held:
        fcntl.flock(blocker, fcntl.LOCK_EX)
    try:
        sweep_fn(profile, said.append, wait=1, now=now, mode=mode)
    finally:
        blocker.close()
    left = listing(profile)
    out = []
    if (planted - left) - want_gone:
        out.append(f"removed what was in use: {sorted((planted - left) - want_gone)}")
    if want_gone & left:
        out.append(f"kept what was stale: {sorted(want_gone & left)}")
    if held:
        if not any("SKIPPED" in s for s in said):
            out.append("a held cargo lock was not reported")
        return out
    first = not ledger and mode == "lax"
    count = sum(1 for g in gone if g.startswith("deps/lib"))
    if not any(f"removed {count} units" in s and "1 incremental caches" in s
               and READS[mode] in s and ("FIRST SWEEP" in s) == first for s in said):
        out.append(f"the sweep did not say what it removed: {said}")
    recorded = load_ledger(profile) or {}
    if set(recorded) != {B, C, A} - {h for h in (A, C) if any(h in g for g in gone)}:
        out.append(f"the ledger records {sorted(recorded)}, not the kept units")
    for name in os.listdir(os.path.join(profile, ".fingerprint")):
        for f in os.listdir(os.path.join(profile, ".fingerprint", name)):
            st = os.lstat(os.path.join(profile, ".fingerprint", name, f))
            if st.st_atime >= st.st_mtime:
                out.append(f"a kept fingerprint was not armed: {name}/{f}")
    return out


CASES = {"real": (False, True, "lax"), "first": (False, False, "lax"),
         "every-first": (False, False, "every"), "never": (False, True, "never"),
         "held": (True, True, "lax")}

NEGATIVES = (
    ("N1 judges a fingerprint by its directory's atime",
     "    newest = st.st_mtime\n", "    newest = max(st.st_atime, st.st_mtime)\n",
     "real", "kept what was stale"),
    ("N2 judges a unit by its outputs, not its fingerprint",
     "used = max(float((ledger or {}).get(h, 0)), last_use(fp))",
     "used = max(float((ledger or {}).get(h, 0)), *map(last_use, files))",
     "real", "removed what was in use"),
    ("N3 deletes half a unit, the fingerprint alone",
     "doomed.append([fp] + files)", "doomed.append([fp])",
     "real", "kept what was stale"),
    ("N4 reads mtime alone",
     "newest = max(newest, s.st_atime, s.st_mtime)", "newest = max(newest, s.st_mtime)",
     "real", "removed what was in use"),
    ("N5 judges an incremental cache by its oldest session",
     "max(sessions, default=0)", "min(sessions, default=0)",
     "real", "removed what was in use"),
    ("N6 ignores cargo's lock",
     "fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)", "pass",
     "held", "removed what was in use"),
    ("N7 says nothing",
     '    say(f"target-sweep: {profile}: removed', '    (f"target-sweep: {profile}: removed',
     "real", "did not say"),
    ("N8 ignores the ledger",
     "float((ledger or {}).get(h, 0))", "0.0",
     "real", "removed what was in use"),
    ("N9 judges a lax profile it has never armed",
     '(mode == "lax" and ledger is not None)', 'mode == "lax"',
     "first", "removed what was in use"),
    ("N10 never arms",
     "                arm(fp)\n", "                pass\n",
     "real", "was not armed"),
    ("N11 keeps no ledger",
     "        save_ledger(profile, seen)\n", "        pass\n",
     "real", "the ledger records"),
    ("N12 judges units where a read never moves atime",
     'judged = mode == "every" or (', 'judged = mode != "lax" or (',
     "never", "removed what was in use"),
    ("N13 trusts no atime it has not probed",
     'judged = mode == "every" or (', 'judged = (',
     "every-first", "kept what was stale"),
)


def selftest():
    """(problems with the sweep or with a negative that failed to fail, the
    negatives seen failing)."""
    out, seen = [], []
    own = open(os.path.abspath(__file__), encoding="utf-8").read()
    body, rest = own.split("\nCASES = {", 1)
    rest = "\nCASES = {" + rest
    scratch = tempfile.mkdtemp(prefix="target-sweep-selftest-")
    try:
        for label, case in CASES.items():
            out += [f"the sweep itself ({label}): {f}" for f in
                    findings(sweep_profile, scratch, label, *case)]
        for i, (label, old, new, case, want) in enumerate(NEGATIVES):
            n = body.count(old)
            if n != 1:
                out.append(f"negative {label}: its pattern matched {n} times, not once")
                continue
            space = {"__name__": f"target_sweep_negative_{i}"}
            exec(compile(body.replace(old, new) + rest, f"<{label}>", "exec"), space)  # noqa: S102
            got = findings(space["sweep_profile"], scratch, f"neg{i}", *CASES[case])
            if not any(want in f for f in got):
                out.append(f"negative {label} (1 substitution) did not fail with "
                           f"{want!r}: {got}")
            else:
                seen.append(f"{label.split()[0]} 1 substitution, {want!r}")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return out, seen


def after_matrix(root, volume, image, timeout=600):
    """The host's target/ and the linux lane's target volume, through the lane's
    own image. Prints why when either half fails; returns nothing a verdict reads."""
    here = os.path.dirname(os.path.abspath(__file__))
    for what, argv in (
            ("the host's target/", [sys.executable, os.path.join(here, "target_sweep.py"),
                                    "target"]),
            (f"the {volume} volume", ["docker", "run", "--rm", "-v", f"{volume}:/work/target-linux",
                                      "-v", f"{here}:/sweep:ro", image, "python3",
                                      "/sweep/target_sweep.py", "/work/target-linux"])):
        print(f"target-sweep: {what}", flush=True)
        try:
            rc = subprocess.run(argv, cwd=root, timeout=timeout, check=False).returncode
        except subprocess.TimeoutExpired:
            rc = f"killed at its {timeout}s timeout"
        except OSError as error:
            rc = f"did not start ({error})"
        if rc != 0:
            print(f"target-sweep: {what}: NOT SWEPT, "
                  + (f"exited {rc}" if isinstance(rc, int) else rc)
                  + "; the verdict is unchanged", flush=True)


def main(argv):
    roots = [a for a in argv if not a.startswith("-")]
    if not roots:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2
    problems, seen = selftest()
    if problems:
        for p in problems:
            print(f"target-sweep: SELF-TEST FAILED, nothing swept: {p}")
        return 1
    print(f"target-sweep: self-test passed; {len(seen)} of {len(NEGATIVES)} negatives seen "
          f"failing: " + "; ".join(seen))
    t0 = time.monotonic()
    freed = sweep(roots, dry="--dry-run" in argv)
    print(f"target-sweep: freed {gb(freed)} under {', '.join(roots)} in "
          f"{time.monotonic() - t0:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
