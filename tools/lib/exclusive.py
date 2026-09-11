"""ONE INPUT-DRIVING LEG ON THE HOST AT A TIME (the third robustness pass,
2026-09-06). The legs that drive a platform's own input, dialog, drag or
clipboard machinery from outside the process fail only under a matrix and
pass alone — twenty-four such legs across the five lanes on the ledger
that day (docs/deferred.md). Each lane already runs them ALONE inside its
own pool; nothing isolated them from the other four lanes. This is that
isolation: one directory lock in the state home every lane already writes
to, `$XDG_STATE_HOME/kaya/exclusive`, which the linux container already sees
at `/flightrec-state/kaya/exclusive` (tools/validate-linux.py mounts it for
the flight recorder).

THE PROTOCOL, spelled here and once in shell for the container
(tools/linux/exclusive.sh; tools/check-exclusive.py holds the two equal):
- the lock is a DIRECTORY, `<dir>/lock`, made atomically with mkdir; a
  `holder` file inside names the lane, the leg, the pid and its scope
  (host or container — a container pid means nothing on the host), and
  the second it was taken;
- a lane about to START ANY LEG calls `wait()` first: while another lane
  holds, it starts nothing (legs already in flight finish), prints who it
  waits for once, and how long it waited;
- a lane about to run one of ITS OWN exclusive legs empties its pool, takes
  the lock with `hold()`, runs the leg INLINE and releases it;
- a lock older than STALE_S is broken by whoever meets it, in a sentence
  naming the holder: the longest per-leg bound in the tree is the windows
  waiter's 290s and the longest exclusive leg on record 118s, so a lock past
  300s is a dead holder, not a slow leg;
- every wait is BOUNDED by WAIT_S: a waiter that runs out proceeds and
  says so, since a stuck lane must not stop the other four from ever
  running a leg.

EXCLUSION NEVER REDDENS A LANE (tools/lib/flightrec.sh's rule for the
recorder): a missing directory, a permission refusal, an expired wait or
a broken lock each print ONE sentence and the leg runs. Each lane prints
`exclusive: <lane> held N legs for Xs; waited M times for Ys` at its end, so
the wall cost of exclusion stands beside the lane's duration.
"""

import contextlib
import os
import re
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

WAIT_S = 360.0
STALE_S = 300.0
POLL_S = 0.25

# The sentences, one spelling shared with tools/linux/exclusive.sh (the gate
# compares them flattened). `{}` slots are filled positionally.
SENTENCES = {
    "waiting": "exclusive: {lane} waits to admit {leg} — {holder} holds",
    "waited": "exclusive: {lane} waited {secs}s to admit {leg}",
    "expired": "exclusive: {lane} waited {limit}s to admit {leg}; {holder} still holds — proceeding without exclusion",
    "hold_waits": "exclusive: {lane} waits to hold for {leg} — {holder} holds",
    "held": "exclusive: {lane} holds for {leg}",
    "held_late": "exclusive: {lane} holds for {leg} after {secs}s",
    "hold_expired": "exclusive: {lane} waited {limit}s to hold for {leg}; {holder} still holds — running it beside them",
    "released": "exclusive: {lane} released after {leg} ({secs}s held)",
    "broke": "exclusive: {lane} broke a lock {age}s old held by {holder} — an exclusive leg's own ceiling is far shorter, so its lane is gone",
    "unusable": "exclusive: {lane} cannot use {dir} ({why}) — running without exclusion",
    "summary": "exclusive: {lane} held {held_n} legs for {held_s}s; waited {waited_n} times for {waited_s}s",
}

_tally = {"held_n": 0, "held_s": 0.0, "waited_n": 0, "waited_s": 0.0}


def exclusive_dir():
    """The lock's directory: KAYA_EXCLUSIVE_DIR, else the state home's."""
    raw = os.environ.get("KAYA_EXCLUSIVE_DIR", "")
    if raw:
        return pathlib.Path(raw)
    state = os.environ.get("XDG_STATE_HOME", "") or str(pathlib.Path.home() / ".local/state")
    return pathlib.Path(state) / "kaya" / "exclusive"


def _say(text):
    print(text, file=sys.stderr, flush=True)


def _holder(lock):
    try:
        return (lock / "holder").read_text(encoding="utf-8").strip()
    except OSError:
        return "<holder unknown>"


def _age(lock):
    try:
        return time.time() - lock.stat().st_mtime
    except OSError:
        return 0.0


def _remove(lock):
    try:
        (lock / "holder").unlink(missing_ok=True)
        lock.rmdir()
        return True
    except OSError:
        return False


def _break_if_stale(lane, lock, stale_s=None):
    age = _age(lock)
    if age <= (STALE_S if stale_s is None else stale_s):
        return False
    holder = _holder(lock)
    if not _remove(lock):
        return False
    _say(SENTENCES["broke"].format(lane=lane, age=int(age), holder=holder))
    return True


def _mine(lane, holder):
    return holder.startswith(f"lane={lane} ")


def wait(lane, leg, *, wait_s=None, stale_s=None, exclusive_dir_=None):
    """Block while ANOTHER lane holds the token. Returns the seconds waited."""
    d = exclusive_dir_ or exclusive_dir()
    lock = d / "lock"
    limit = WAIT_S if wait_s is None else wait_s
    started = time.monotonic()
    told = False
    while lock.is_dir():
        holder = _holder(lock)
        if _mine(lane, holder):
            break
        if _break_if_stale(lane, lock, stale_s):
            continue
        if not told:
            _say(SENTENCES["waiting"].format(lane=lane, leg=leg, holder=holder))
            told = True
        if time.monotonic() - started > limit:
            _say(SENTENCES["expired"].format(lane=lane, limit=int(limit), leg=leg,
                                             holder=holder))
            break
        time.sleep(POLL_S)
    waited = time.monotonic() - started
    if told:
        _tally["waited_n"] += 1
        _tally["waited_s"] += waited
        _say(SENTENCES["waited"].format(lane=lane, secs=f"{waited:.1f}", leg=leg))
    return waited


def _take(lane, leg, lock, scope):
    """One mkdir, then the holder written and READ BACK — the bind mount is a
    file-server boundary, so the atomicity is confirmed, not assumed."""
    try:
        lock.mkdir()
    except FileExistsError:
        return False
    stamp = (f"lane={lane} leg={leg} pid={os.getpid()} scope={scope} "
             f"host={socket.gethostname()} start={int(time.time())}")
    (lock / "holder").write_text(stamp + "\n", encoding="utf-8")
    return _holder(lock) == stamp


@contextlib.contextmanager
def hold(lane, leg, *, wait_s=None, stale_s=None, exclusive_dir_=None, scope="host"):
    """Run one exclusive leg as the only input-driving leg on the host."""
    d = exclusive_dir_ or exclusive_dir()
    lock = d / "lock"
    limit = WAIT_S if wait_s is None else wait_s
    try:
        d.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        _say(SENTENCES["unusable"].format(lane=lane, dir=d, why=e.strerror or e))
        yield 0.0
        return
    started = time.monotonic()
    told = False
    taken = False
    while True:
        if _take(lane, leg, lock, scope):
            taken = True
            break
        holder = _holder(lock)
        if _mine(lane, holder):
            # A lock this lane took and never released is this lane's own
            # dead leg: reclaimed rather than waited on.
            _remove(lock)
            continue
        if _break_if_stale(lane, lock, stale_s):
            continue
        if not told:
            _say(SENTENCES["hold_waits"].format(lane=lane, leg=leg, holder=holder))
            told = True
        if time.monotonic() - started > limit:
            _say(SENTENCES["hold_expired"].format(lane=lane, limit=int(limit), leg=leg,
                                                  holder=holder))
            break
        time.sleep(POLL_S)
    waited = time.monotonic() - started
    if taken:
        if told:
            _say(SENTENCES["held_late"].format(lane=lane, leg=leg, secs=f"{waited:.1f}"))
        else:
            _say(SENTENCES["held"].format(lane=lane, leg=leg))
    t0 = time.monotonic()
    try:
        yield waited
    finally:
        held = time.monotonic() - t0
        if taken:
            _tally["held_n"] += 1
            _tally["held_s"] += held
            if not _remove(lock):
                _say(SENTENCES["unusable"].format(lane=lane, dir=d,
                                                  why="the lock would not release"))
            _say(SENTENCES["released"].format(lane=lane, leg=leg, secs=f"{held:.1f}"))


def summary(lane):
    """The wall cost of exclusion, printed at the lane's end."""
    _say(SENTENCES["summary"].format(
        lane=lane, held_n=_tally["held_n"], held_s=f"{_tally['held_s']:.0f}",
        waited_n=_tally["waited_n"], waited_s=f"{_tally['waited_s']:.0f}"))


def waited_seconds(lane, text):
    """The seconds `lane` spent waiting for the token, read off its own
    summary line in `text` — through the template, so the reader and the
    sentence cannot drift apart. 0 when the lane printed no summary."""
    pattern = re.escape(SENTENCES["summary"])
    for key, group in (("lane", re.escape(lane)), ("held_n", r"\d+"), ("held_s", r"\d+"),
                       ("waited_n", r"\d+"), ("waited_s", r"(\d+)")):
        pattern = pattern.replace(re.escape("{" + key + "}"), group)
    m = re.search("^" + pattern + "$", text, re.M)
    return int(m.group(1)) if m else 0


def selftest(where=None):
    """The protocol watched before a lane trusts it: two processes race the
    mkdir and exactly one wins; a lock past STALE_S is broken and one under
    it is not; an expired wait proceeds and says so; the holder round-trips.
    Counts printed; a failure is a sentence and a nonzero return, never an
    exception up the lane."""
    out = []
    with tempfile.TemporaryDirectory(prefix="kaya-exclusive-") as td:
        d = pathlib.Path(where or td)
        lock = d / "lock"
        # 1. THE RACE: two processes, one mkdir each, one winner.
        script = ("import os,sys\n"
                  "try:\n    os.mkdir(sys.argv[1]); print('won')\n"
                  "except FileExistsError:\n    print('lost')\n")
        procs = [subprocess.Popen([sys.executable, "-c", script, str(lock)],
                                  stdout=subprocess.PIPE, text=True, encoding="utf-8")
                 for _ in range(2)]
        outcome = sorted(p.communicate()[0].strip() for p in procs)
        out.append(("two processes race the mkdir", outcome == ["lost", "won"], outcome))
        _remove(lock)
        # 2. THE STALE BREAK: 301s old breaks, 299s old does not.
        for age, expect in ((STALE_S + 1, True), (STALE_S - 1, False)):
            lock.mkdir()
            (lock / "holder").write_text("lane=ghost leg=x pid=1 scope=host host=h start=0\n",
                                         encoding="utf-8")
            then = time.time() - age
            os.utime(lock, (then, then))
            broke = _break_if_stale("selftest", lock)
            out.append((f"a lock {int(age)}s old is {'broken' if expect else 'kept'}",
                        broke == expect, broke))
            _remove(lock)
        # 3. AN EXPIRED WAIT PROCEEDS.
        lock.mkdir()
        (lock / "holder").write_text("lane=other leg=y pid=1 scope=host host=h start=0\n",
                                     encoding="utf-8")
        waited = wait("selftest", "z", wait_s=0.3, exclusive_dir_=d)
        out.append(("an expired wait proceeds", 0.3 <= waited < 5.0, round(waited, 2)))
        _remove(lock)
        _tally["waited_n"] -= 1
        # 4. THE HOLDER ROUND-TRIPS THROUGH hold().
        with hold("selftest", "w", exclusive_dir_=d):
            holder = _holder(lock)
            out.append(("the holder names its taker", holder.startswith("lane=selftest leg=w "),
                        holder))
        out.append(("the release removes the lock", not lock.exists(), lock.exists()))
        _tally["held_n"] -= 1
        # 5. THE SUMMARY IS READ BACK THROUGH ITS OWN TEMPLATE, for the
        # matrix's duration ceilings (validate-all nets the waits out):
        # this lane's line answers its seconds, another lane's answers 0.
        line = SENTENCES["summary"].format(lane="android", held_n=5, held_s="202",
                                           waited_n=4, waited_s="294")
        got = waited_seconds("android", "noise\n" + line + "\nmore\n")
        out.append(("the summary's waited seconds read back", got == 294, got))
        other = waited_seconds("ios", line)
        out.append(("another lane's summary reads as no wait", other == 0, other))
    bad = [o for o in out if not o[1]]
    print(f"exclusive: self-test {len(out)} watched, {len(bad)} failed", file=sys.stderr,
          flush=True)
    for label, ok, got in bad:
        print(f"exclusive: SELF-TEST FAILED — {label}: got {got!r}", file=sys.stderr, flush=True)
    return not bad


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(0 if selftest() else 1)
    print("usage: exclusive.py --selftest", file=sys.stderr)
    sys.exit(2)
