"""Hard walls on the matrix's moving parts: a gate, a lane, a lane that
printed its verdict and did not leave, a leg worker, one ssh call. Every
bound is read on time.monotonic, which stops while the Mac sleeps, so a
host sleep never fires a wall; `slept_seconds` reports the sleep instead
(docs/traps.md, the matrix that slept 22 hours on battery).
tools/check-gates.py holds the call sites and runs every wall against a
hung stand-in."""
import os
import re
import signal
import subprocess
import threading
import time

GATE_WALL_FLOOR_S = 1200
GATE_WALL_PER_WEIGHT = 10
LANE_WALL_FACTOR = 2
LANE_WALL_FLOOR_S = 2400
VERDICT_GRACE_S = 300
SLEEP_NOTICE_S = 60

LANE_RUNNERS = {"mac": "validate-mac", "linux": "run-suites", "linux-quiet": "run-suites",
                "windows": "deploy-win", "ios": "run-sim", "android": "run-emulator",
                "android-quiet": "run-emulator"}

_live = {}
_live_lock = threading.Lock()


def gate_wall(weight):
    return max(GATE_WALL_FLOOR_S, GATE_WALL_PER_WEIGHT * weight)


def lane_wall(budget):
    return max(LANE_WALL_FLOOR_S, LANE_WALL_FACTOR * budget)


def verdict_line(lane, text):
    """The lane's own final verdict line in `text`, or None."""
    if lane == "gates":
        pattern = r"^gates: declared \d+, ran \d+, passed \d+$"
    else:
        runner = LANE_RUNNERS.get(lane, lane)
        pattern = rf"^{re.escape(runner)}: (?:ALL PASS|FAILURES ABOVE)$"
    found = re.findall(pattern, text, re.M)
    return found[-1] if found else None


def last_lines(text, n=1):
    lines = [line for line in text.splitlines() if line.strip()]
    return lines[-n:] if lines else ["(it printed nothing)"]


def members(pgid):
    """The processes still in group `pgid`, read from ps: (pid, command)."""
    out = subprocess.run(["ps", "-Ao", "pid=,pgid=,stat=,command="], stdout=subprocess.PIPE,
                         text=True, encoding="utf-8", errors="replace", check=False).stdout
    found = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[1] == str(pgid) and not parts[2].startswith("Z"):
            found.append((int(parts[0]), parts[3]))
    return found


def _gone(pgid, proc, seconds):
    end = time.monotonic() + seconds
    while True:
        if proc is not None:
            proc.poll()
        if not members(pgid):
            return True
        if time.monotonic() >= end:
            return False
        time.sleep(0.2)


def kill_group(pgid, proc=None, first=signal.SIGINT, grace=(20, 10)):
    """SIGINT (a python lane runs its finally and atexit), then SIGTERM, then
    SIGKILL, each to the whole group; returns the members ps still lists."""
    for sig, wait in ((first, grace[0]), (signal.SIGTERM, grace[1]), (signal.SIGKILL, 5)):
        try:
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        if _gone(pgid, proc, wait):
            break
    if proc is not None:
        proc.poll()
    return members(pgid)


def track(proc):
    with _live_lock:
        _live[proc.pid] = proc


def untrack(proc):
    with _live_lock:
        _live.pop(proc.pid, None)


def kill_tracked():
    with _live_lock:
        procs = list(_live.values())
    for proc in procs:
        if proc.poll() is None:
            kill_group(proc.pid, proc, first=signal.SIGTERM, grace=(5, 5))


def forward_signals():
    """A child in a group of its own no longer hears the terminal's ^C, so
    this process passes SIGINT and SIGTERM on before it goes."""
    def handler(signum, _frame):
        kill_tracked()
        if signum == signal.SIGINT:
            raise KeyboardInterrupt
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, handler)


def run_bounded(argv, wall_s, **popen):
    """Run `argv` in a process group of its own with stdout and stderr
    captured together; past `wall_s` the whole group is killed.
    Returns (returncode, output, walled, survivors)."""
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace",
                            start_new_session=True, **popen)
    track(proc)
    try:
        try:
            out, _ = proc.communicate(timeout=wall_s)
            return proc.returncode, out, False, []
        except subprocess.TimeoutExpired:
            survivors = kill_group(proc.pid, proc, first=signal.SIGTERM, grace=(5, 5))
            try:
                out, _ = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired as late:
                raw = late.stdout or b""
                out = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
                proc.kill()
            return proc.returncode, out or "", True, survivors
    finally:
        untrack(proc)


def join_bounded(workers, bound_s):
    """Join (name, thread, started) triples, each until `bound_s` past its own
    start; returns the names still alive."""
    alive = []
    for name, thread, started in workers:
        thread.join(max(0.0, started + bound_s - time.monotonic()))
        if thread.is_alive():
            alive.append(name)
    return alive


class SleepClock:
    """Wall-clock time the monotonic clock did not see: a host sleep."""

    def __init__(self):
        self.wall0, self.mono0 = time.time(), time.monotonic()

    def slept(self):
        return max(0, int((time.time() - self.wall0) - (time.monotonic() - self.mono0)))


def power_reading():
    """pmset's power source line and charge, or what it could not read."""
    got = subprocess.run(["pmset", "-g", "batt"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, encoding="utf-8", errors="replace", check=False)
    if got.returncode != 0:
        return None, f"pmset -g batt exited {got.returncode}: {got.stderr.strip()[:200]}"
    lines = [line.strip() for line in got.stdout.splitlines() if line.strip()]
    source = re.search(r"Now drawing from '([^']+)'", got.stdout)
    charge = re.search(r"(\d+)%;\s*([^;]+)", got.stdout)
    said = (f"drawing from {source.group(1) if source else 'an unnamed source'}"
            + (f", battery {charge.group(1)}% {charge.group(2).strip()}" if charge else ""))
    on_battery = bool(source) and "Battery" in source.group(1)
    return on_battery, said if lines else "pmset -g batt printed nothing"


def sleeps_since(epoch):
    """pmset's own Sleep and Wake lines at or after `epoch` (seconds)."""
    got = subprocess.run(["pmset", "-g", "log"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, encoding="utf-8", errors="replace", check=False, timeout=30)
    since = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))
    return [line.strip()[:220] for line in got.stdout.splitlines()
            if re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4} (Sleep|Wake) ", line)
            and line[:19] >= since]
