#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# The whole matrix, one invocation; the five lanes run CONCURRENTLY by
# default. --serial is for single-lane benchmarking, debugging under
# contention, and recording mode (one screen, one recorder).
#
# Usage: validate-all.py [--serial] [windows-host]
#
# tools/check-gates.py pins the parallel launch block.

import atexit
import os
import shutil
import subprocess
import tempfile
import threading
import time

os.chdir(ROOT)

MODE = "parallel"
HOST = "akhil@192.168.64.2"
for arg in sys.argv[1:]:
    if arg == "--serial":
        MODE = "serial"
    else:
        HOST = arg

LANES_DIR = pathlib.Path(tempfile.mkdtemp())
# A FAILING LANE OR DURATION ANOMALY'S LOG OUTLIVES THE RUN: a
# transient nobody can look at is indistinguishable from a bug nobody
# found. Ordinary passing lanes leave nothing behind.
KEEP_DIR = ROOT / "target/validate-failures"
atexit.register(lambda: shutil.rmtree(LANES_DIR, ignore_errors=True))

lane_names = []
lane_procs = []
lane_waiters = []
lane_done = {}
status = 0


def keep_lane_log(name):
    try:
        KEEP_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copy2(LANES_DIR / f"{name}.log", KEEP_DIR / f"{name}.log")
    except OSError:
        print(f"== {name} log could not be kept at "
              f"target/validate-failures/{name}.log ==", file=sys.stderr)
        return False
    print(f"== {name} log kept at target/validate-failures/{name}.log "
          f"==")
    return True


def run_lane(name, argv, env=None):
    """One matrix unit. Parallel mode BACKGROUNDS it and records the
    process — the collection below waits on exactly these."""
    global status
    lane_env = dict(os.environ, **(env or {}))
    if MODE == "serial":
        print(f"== {name} ==")
        t0 = time.monotonic()
        with open(LANES_DIR / f"{name}.log", "w", encoding="utf-8",
                  errors="replace") as lf:
            rc = subprocess.run(argv, env=lane_env, stdout=lf,
                                stderr=lf, check=False).returncode
        secs = int(time.monotonic() - t0)
        if rc == 0:
            print(f"{name}: PASS ({secs}s)")
        else:
            print((LANES_DIR / f"{name}.log").read_text(
                encoding="utf-8", errors="replace"), end="")
            print(f"{name}: FAIL ({secs}s)")
            status = 1
            if not keep_lane_log(name):
                status = 1
        return
    lf = open(LANES_DIR / f"{name}.log", "w", encoding="utf-8",
              errors="replace")
    proc = subprocess.Popen(argv, env=lane_env, stdout=lf, stderr=lf)
    lf.close()
    t0 = time.monotonic()

    # The lane's own duration, stamped WHEN IT EXITS: a collection that
    # waited in queue order would bill an early finisher for its slower
    # siblings' time.
    def _wait(name=name, proc=proc, t0=t0):
        rc = proc.wait()
        lane_done[name] = ("PASS" if rc == 0 else "FAIL",
                           int(time.monotonic() - t0))

    waiter = threading.Thread(target=_wait)
    waiter.start()
    lane_waiters.append(waiter)
    lane_procs.append(proc)
    lane_names.append(name)


T0 = time.monotonic()
# THE HOST'S LOAD RIDES THE RECORD (2026-09-01: three ceilings fired in
# one contended evening). WITH THE TOP CONSUMERS, because the load figure
# alone cannot tell the host from the lanes — a quiet matrix's own
# fifteen-minute figure reaches ~135 by its end. A top consumer that is
# no lane's process is the host; the pools are expected there.
LOAD_AT_LAUNCH = os.getloadavg()


def top_consumers(n=4):
    """The n busiest processes by CPU share, as `pcpu name`."""
    got = subprocess.run(["ps", "-Ao", "pcpu=,comm="], stdout=subprocess.PIPE,
                         text=True, encoding="utf-8", errors="replace",
                         check=False)
    rows = []
    for line in got.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            try:
                rows.append((float(parts[0]), pathlib.Path(parts[1]).name))
            except ValueError:
                continue
    rows.sort(reverse=True)
    return ", ".join(f"{name} {cpu:.0f}%" for cpu, name in rows[:n])


print(f"host load at launch: {LOAD_AT_LAUNCH[0]:.1f} {LOAD_AT_LAUNCH[1]:.1f} "
      f"{LOAD_AT_LAUNCH[2]:.1f} (1, 5, 15 min); top consumers: "
      f"{top_consumers()}", flush=True)
if MODE == "parallel":
    # ALL FIVE PLATFORM LANES START TOGETHER; the gate sweep waits for
    # Android's process, then runs niced. THE WALL IS ANDROID PLUS THE
    # SWEEP, IN SERIES (619s, 2026-08-24).
    #
    # The token is a t0 fingerprint of every keyed gate's inputs, so the
    # mac lane can skip its own sweep; a hand-run has none and sweeps.
    # BUILT BEFORE THE TOKEN IS TAKEN, since the keys carry the
    # artifacts' REAL BYTES — a token over the previous build's made the
    # mac lane sweep twice (791s against 620, 2026-09-01).
    # tools/check-gates.py holds the order.
    if subprocess.run(["tools/gates.py", "--build"]).returncode != 0:
        sys.exit(1)
    got = subprocess.run(["tools/gates.py", "--fingerprint"],
                         stdout=subprocess.PIPE, text=True,
                         encoding="utf-8", errors="replace",
                         check=False)
    if got.returncode != 0:
        sys.exit(1)
    os.environ["KAYA_MATRIX_GATES_TOKEN"] = got.stdout.strip()
    run_lane("mac", ["tools/validate-mac.py"])
    # KAYA_LINUX_JOBS scopes a leg-pool width to the linux lane alone —
    # bare KAYA_JOBS would resize the mac pool too. Empty means the
    # lane's own default. Measured under the full matrix 2026-08-20 and 8
    # STAYS: 6 was 431s, 8 was 401s, 10 was 358s for this lane but flaked
    # an android stall leg and an iOS picker leg in the same run, moving
    # the wall only 403 -> 394.
    run_lane("linux", ["tools/validate-linux.py"],
             env={"KAYA_JOBS": os.environ.get("KAYA_LINUX_JOBS", "")})
    run_lane("windows", ["tools/deploy-win.py", HOST, "all"])
    run_lane("ios", ["tools/ios/run-sim.py"])
    run_lane("android", ["tools/android/run-emulator.py"])
    android_lane_proc = lane_procs[-1]
    android_lane_proc.wait()
    run_lane("gates", ["nice", "-n", "10", "tools/gates.py"])
else:
    run_lane("mac", ["tools/validate-mac.py"])
    run_lane("linux", ["tools/validate-linux.py"])
    run_lane("windows", ["tools/deploy-win.py", HOST, "all"])
    run_lane("ios", ["tools/ios/run-sim.py"])
    run_lane("android", ["tools/android/run-emulator.py"])

# DURATION IS A CORRECTNESS SIGNAL (CLAUDE.md invariant 8): a lane can
# get six times slower and still report ALL PASS. Measured 2026-07-25:
# exporting GTK_A11Y=atspi lane-wide took linux from 65s to 393s — a
# change in blast radius, not in any assertion.
#
# EACH CEILING CARRIES THE MEASUREMENT THAT SET IT (docs/HACKING.md
# delegates the live numbers to this table), and a lane that grows raises
# its number in the SAME COMMIT that makes it bigger. The band each was
# calibrated against, and the readings deliberately NOT covered — the
# environmental windows — are docs/traps.md, "Per-lane duration ceilings,
# and the measurements that set them".
BUDGETS = {
    # 620 since 2026-09-01: the ninth binding took the roster 349 -> 391
    # legs; quiet-contended matrices sit near 500 and this keeps the
    # ~1.25x headroom the other lanes have.
    "mac": 620,
    # 600 since 2026-09-01: the ninth binding took the roster 604 -> 684
    # legs (one js leg per python leg on both protocols); the first
    # contended matrix after read 459s.
    "linux": 600,
    # 600 since 2026-09-02: the roster grew 201 -> 239 legs with the JS
    # column and the four quiet matrices since read 498, 442, 488 and
    # 559s. 600 is 1.2x over that band's top.
    "windows": 600,
    # 600 since 2026-09-01: the lane ran 113 legs from 2026-08-31, five
    # accepted matrices measuring 452-491s. 600 is 1.22x over that band's
    # top. HELD at 600 on 2026-09-03 with the roster at 116 (the dnd leg
    # joined the rust-swiftui suite and cost 1s; the lane standalone read
    # 302s that day), because the growth is inside the headroom rather
    # than beside it. run-sim.py prints the LocalStorage admission's
    # per-device time and the join's wait, so the next anomaly says
    # whether the admission reached the critical path.
    "ios": 600,
    # 310 since 2026-08-20: the pool-degradation trap's remedy is a COLD
    # BOOT (docs/traps.md), and a reboot run carries ~60-90s of emulator
    # startup a warm-pool ceiling read as an anomaly; a measured cold-boot
    # run is 267s.
    "android": 310,
    # 490 since 2026-08-23. What it guards is the DELAYED-plus-NICED band
    # (the launch block above), which has ONE accepted sample: 348s
    # (2026-08-24). It deliberately does not cover the 467s reading from
    # the from-t0 schedule this file no longer runs. A second
    # delayed-and-niced sample is the number this arm most needs.
    "gates": 490,
}

if MODE == "parallel":
    for waiter in lane_waiters:
        waiter.join()
    for name in lane_names:
        verdict, secs = lane_done.get(name, ("FAIL", 0))
        log = LANES_DIR / f"{name}.log"
        log_text = (log.read_text(encoding="utf-8", errors="replace")
                    if log.is_file() else "")
        if verdict != "PASS":
            print(f"== {name} (log) ==")
            print(log_text, end="")
            if not keep_lane_log(name):
                status = 1
            status = 1
        legs = sum(1 for line in log_text.splitlines()
                   if ": PASS" in line)
        print(f"{name}: {verdict} ({secs}s, {legs} legs)")
        budget = BUDGETS.get(name, 0)
        if budget > 0 and secs > budget:
            now = os.getloadavg()
            print(f"{name}: DURATION ANOMALY — {secs}s exceeds the "
                  f"{budget}s ceiling. A lane that slows down by this "
                  f"much changed in kind, not in degree: look for work "
                  f"added to EVERY leg (an env export, a per-leg wait, "
                  f"a rebuild that stopped caching) before assuming it "
                  f"is load. Host load was {LOAD_AT_LAUNCH[0]:.1f} at "
                  f"launch and reads {now[0]:.1f} / {now[1]:.1f} / "
                  f"{now[2]:.1f} (1, 5, 15 min) now; top consumers: "
                  f"{top_consumers()} — a consumer there that is not "
                  f"a lane's process is the host, the pools are "
                  f"expected.")
            if verdict == "PASS" and not keep_lane_log(name):
                status = 1
            status = 1

print(f"TIMING matrix {int(time.monotonic() - T0)}s ({MODE})",
      flush=True)
if status == 0:
    print("validate-all: ALL PASS")
else:
    print("validate-all: FAILURES ABOVE")
sys.exit(status)
