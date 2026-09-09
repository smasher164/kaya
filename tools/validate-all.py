#!/usr/bin/env python3
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die
import exclusive
from lanes import android as _android, ios as _ios, mac as _mac, win as _win

dev_shell_or_die()

# The whole matrix, one invocation; the five lanes run CONCURRENTLY by
# default. --serial is for single-lane benchmarking, debugging under
# contention, and recording mode (one screen, one recorder).
#
# Usage: validate-all.py [--serial] [--exclusive | --no-exclusive] [windows-host]
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
# --exclusive runs ONLY the exclusive legs (the input-driving ones every
# lane names in its EXCLUSIVE set), --no-exclusive runs everything but them,
# and no flag runs everything (the maintainer, 2026-09-06: a flag filters;
# its absence skips nothing). The choice rides to every lane and to the
# sweep as KAYA_EXCLUSIVE.
for arg in sys.argv[1:]:
    if arg == "--serial":
        MODE = "serial"
    elif arg == "--exclusive":
        os.environ["KAYA_EXCLUSIVE"] = "only"
    elif arg == "--no-exclusive":
        os.environ["KAYA_EXCLUSIVE"] = "skip"
    else:
        HOST = arg

LANES_DIR = pathlib.Path(tempfile.mkdtemp())
# A FAILING LANE OR DURATION ANOMALY'S LOG OUTLIVES THE RUN: a
# transient nobody can look at is indistinguishable from a bug nobody
# found. Ordinary passing lanes leave nothing behind.
KEEP_DIR = ROOT / "target/validate-failures"
RUN_STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
LANES_KEEP_DIR = ROOT / "target/validate-lanes"
atexit.register(lambda: shutil.rmtree(LANES_DIR, ignore_errors=True))

lane_names = []
lane_procs = []
lane_waiters = []
lane_done = {}
status = 0


def keep_lane_log(name, where=None):
    """A failing lane's log goes to target/validate-failures; EVERY lane's
    goes to target/validate-lanes as well (2026-09-07), since the matrix
    deletes its scratch at exit and the phase timings inside are the only
    profile a run leaves behind."""
    where = where or KEEP_DIR
    try:
        where.mkdir(parents=True, exist_ok=True)
        shutil.copy2(LANES_DIR / f"{name}.log", where / f"{name}.log")
        # AND ONE COPY PER RUN (2026-09-09): the per-run copy above is
        # overwritten by the next matrix, so a duration anomaly could not be
        # read per leg against the matrix before it (the S4 windows reading
        # had no baseline). Newest 20 runs kept.
        run_dir = ROOT / "target/validate-lanes/runs" / RUN_STAMP
        run_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(LANES_DIR / f"{name}.log", run_dir / f"{name}.log")
        runs = sorted((ROOT / "target/validate-lanes/runs").iterdir())
        for stale in runs[:-20]:
            shutil.rmtree(stale, ignore_errors=True)
    except OSError:
        print(f"== {name} log could not be kept at "
              f"target/validate-failures/{name}.log ==", file=sys.stderr)
        return False
    print(f"== {name} log kept at target/validate-failures/{name}.log "
          f"==")
    return True


EXCLUSIVE_LEGS = {"mac": _mac.EXCLUSIVE, "windows": _win.EXCLUSIVE,
                  "ios": _ios.EXCLUSIVE, "android": _android.EXCLUSIVE}


def run_lane(name, argv, env=None):
    """One matrix unit. Parallel mode BACKGROUNDS it and records the
    process — the collection below waits on exactly these."""
    global status
    lane_env = dict(os.environ, **(env or {}))
    if (os.environ.get("KAYA_EXCLUSIVE", "") == "only"
            and not EXCLUSIVE_LEGS.get(name, {"linux declares its own"})):
        # An exclusive-only run has nothing for this lane, and launching it
        # would spend its whole setup (the mac lane's 481s for zero legs)
        # loading the host under the lanes that do have legs. The row reads
        # 0 legs, as a launched lane's would.
        print(f"exclusive: {name} names no exclusive legs; not launched",
              flush=True)
        if MODE == "serial":
            print(f"{name}: PASS (0s)")
        else:
            lane_done[name] = ("PASS", 0)
            lane_names.append(name)
        return
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
# THE MATRIX-WIDE EXCLUSIVE TOKEN (tools/lib/exclusive.py): one directory every
# lane reaches, the container through its flight-recorder mount.
EXCLUSIVE_DIR = pathlib.Path(
    os.environ.get("XDG_STATE_HOME", "") or str(pathlib.Path.home() / ".local/state")
) / "kaya" / "exclusive"
EXCLUSIVE_DIR.mkdir(parents=True, exist_ok=True)
os.environ["KAYA_EXCLUSIVE_DIR"] = str(EXCLUSIVE_DIR)
print(f"exclusive: the token lives at {EXCLUSIVE_DIR}", flush=True)
# The protocol watched before the lanes trust it: the mkdir race, the
# stale break both sides of its ceiling, an expired wait, the holder.
if not exclusive.selftest():
    print("exclusive: the self-test failed — the lanes run WITHOUT the token", flush=True)
    del os.environ["KAYA_EXCLUSIVE_DIR"]
if MODE == "parallel":
    # ALL FIVE PLATFORM LANES START TOGETHER; the gate sweep waits for
    # Android's process, then runs niced and FOUR WIDE (tools/gates.py,
    # 2026-09-07), which hides it behind the longer lanes. One gate at a
    # time the wall was Android plus the whole sweep in series (654 +
    # 422 = 1082s); launched at t0 beside the lanes, four wide and niced,
    # it cost every lane 150-200s and every ceiling for a 116s gain
    # (matrix #24, docs/measurements/gate-sweep-2026-09-07.md).
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
    # Line one is the token, line two the per-gate keys behind it, so
    # the lane can say which gate's inputs moved when the handshake misses.
    fp_lines = got.stdout.strip().splitlines()
    os.environ["KAYA_MATRIX_GATES_TOKEN"] = fp_lines[0] if fp_lines else ""
    os.environ["KAYA_MATRIX_GATES_KEYS"] = fp_lines[1] if len(fp_lines) > 1 else "{}"
    run_lane("mac", ["tools/validate-mac.py"])
    # KAYA_LINUX_JOBS scopes a leg-pool width to the linux lane alone —
    # bare KAYA_JOBS would resize the mac pool too. Empty means the
    # lane's own default. Measured under the full matrix 2026-08-20 and 8
    # STAYS: 6 was 431s, 8 was 401s, 10 was 358s for this lane but flaked
    # an android stall leg and an iOS picker leg in the same run, moving
    # the wall only 403 -> 394.
    run_lane("linux", ["tools/validate-linux.py"],
             env={"KAYA_JOBS": os.environ.get("KAYA_LINUX_JOBS", "")})
    # KAYA_WIN_JOBS scopes the VM's leg pool under the matrix: six slots
    # on six vCPUs were measured for a VM with the host to itself, and
    # under the everyday matrix the lane is the wall — 644s at six, 589s
    # at four with every other lane unchanged (matrices #28 and #30,
    # 2026-09-07). Empty means the runner's own default.
    run_lane("windows", ["tools/deploy-win.py", HOST, "all"],
             env={"KAYA_WIN_JOBS": os.environ.get("KAYA_WIN_JOBS", "4")})
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
    # 760 since 2026-09-06: the exclusive token (tools/lib/exclusive.py) has this lane
    # hold still while android drags and linux pastes hold it — eight waits,
    # 226s, on matrix #22 (675s against 620); 485s without them the same day.
    # Re-read on the next quiet matrices.
    # RE-READ 2026-09-07 over four matrices (#24-#27, the four-wide sweep
    # after Android overlapping the tails, every lane log kept) and set
    # ~1.1x over the band: mac 854-932, linux 948-1012, windows 938-1099,
    # ios 911-957, android 770-852, the sweep 193-214.
    "mac": 1000,
    # 600 since 2026-09-01: the ninth binding took the roster 604 -> 684
    # legs (one js leg per python leg on both protocols); the first
    # contended matrix after read 459s. 700 since 2026-09-04: the roster
    # grew 701 -> 719 with EIGHTEEN pickers legs (nine languages on both
    # pools), every one through tools/linux/a11y-leg.sh — the slow kind,
    # since the scene asserts expect_ax — and the first matrix on that
    # roster read 636s where the lane standalone the same day read 574s.
    # 700 is 1.1x over the one contended sample; to be re-read on the next
    # quiet matrices.
    # 820 since 2026-09-06: under the exclusive token this lane waited six times
    # for 202s (android's drags, iOS's saves) and held its own seven legs
    # for 26s on matrix #23 (750s against 700, WindowServer at 52% beside
    # it); 674s the matrix before, 452s on a quiet host. Re-read likewise.
    "linux": 1100,
    # 600 since 2026-09-02: the roster grew 201 -> 239 legs with the JS
    # column and the four quiet matrices since read 498, 442, 488 and
    # 559s. 600 is 1.2x over that band's top. 950 since 2026-09-03: the
    # roster grew 239 -> 247 with EIGHT SERIAL legs — six dnd legs (the
    # verb moves the real mouse, ~31s each under a matrix, 20s alone) and
    # the two cross-app witness legs (9s and 24s) — a change in kind that
    # adds ~220s no pool can hide; the first matrix on that roster read
    # 884s (suites 612) where the previous had read 564, and the lane
    # standalone the same hour read suites 444s. 950 is 1.07x over the one
    # contended sample and 1.2x over 564 + the serial arithmetic; to be
    # re-read on the next quiet matrices. 1050 since 2026-09-04: the roster
    # grew 247 -> 253 with the six pooled pickers legs, and the first
    # matrix on that roster read 998s (host load 4.7 at launch, the VM's
    # qemu the top consumer at 86%) where the lane standalone the same day
    # read 449s. 1050 is 1.05x over the one contended sample; to be
    # re-read on the next quiet matrices. 1200 since 2026-09-09: the
    # 2026-09-07 band's top (1099) sat one second under 1100, and S4 took
    # the roster 275 -> 276 with a two-act leg, a once-per-run platform
    # probe and service restart (desk-warm 3 -> 14) and a per-leg state
    # home reset; the two S4 matrices read 1192 (suites 1067) and 1139
    # (suites 1035; five-minute load 78, the VM's qemu at 113%) with every
    # leg green, and the sum of the 270 pooled leg times was 2166s (median
    # 6s, p90 16s, max 32s). 1200 is 1.05x over the pair; to be re-read on
    # the next quiet matrices.
    "windows": 1200,
    # 600 since 2026-09-01: the lane ran 113 legs from 2026-08-31, five
    # accepted matrices measuring 452-491s. 600 is 1.22x over that band's
    # top. HELD at 600 on 2026-09-03 with the roster at 116 (the dnd leg
    # joined the rust-swiftui suite and cost 1s; the lane standalone read
    # 302s that day), because the growth is inside the headroom rather
    # than beside it. run-sim.py prints the LocalStorage admission's
    # per-device time and the join's wait, so the next anomaly says
    # whether the admission reached the critical path.
    # 640 since 2026-09-06: the roster grew 128 -> 131 legs with the search
    # scene; 538s quiet at 128 (matrix #19), 608s at 131 under a five-minute
    # load of 84 (matrix #21) with no leg slowed in kind.
    # 840 since 2026-09-06: the four exclusive legs empty the pool and run alone
    # (93s held, 89s waiting to hold, 24s admitting on matrix #22, 749s
    # against 640); 608s without them the same day. Re-read likewise.
    "ios": 1050,
    # 310 since 2026-08-20: the pool-degradation trap's remedy is a COLD
    # BOOT (docs/traps.md), and a reboot run carries ~60-90s of emulator
    # startup a warm-pool ceiling read as an anomaly; a measured cold-boot
    # run is 267s. 520 since 2026-09-03: the roster grew 123 -> 126 with
    # the dnd legs, each a SERIAL runner-channel drag (seven injections at
    # 1.5s plus their acks, 22-27s a leg under a matrix), and the first
    # full matrix on that roster read 441s where the previous had read
    # 306; the lane standalone the same hour read ~160s. 520 is 1.18x over
    # the one contended sample, to be re-read on the next quiet matrices.
    # 660 since 2026-09-06: the drag injection is START-GATED now (the
    # press held until the app's own KAYA_DRAG_STARTED, eight moves paced
    # over a load-scaled duration capped at 4.5s), so the three dnd legs
    # cost 48-49s each under a matrix where they cost 22-27s, roughly
    # +100s on a lane whose last five matrices read 458-495s; 660 is
    # 1.12x over 590, to be re-read on the next quiet matrices.
    "android": 870,
    # 490 since 2026-08-23, KEPT for the delayed-and-four-wide schedule
    # of 2026-09-07 until it has samples: one at a time the sweep read
    # 348s delayed behind Android (2026-08-24) and 422s on the last such
    # matrix; four wide it read 151s standalone and 341s from t0 under
    # every lane's builds (matrix #24, the launch this file no longer
    # runs). 300 since 2026-09-07: three matrices after Android, four wide,
    # read 193, 214 and 210.
    "gates": 300,
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
        # The lane's own phase clock, on the record beside its row: where
        # a lane's seconds went is the question every wall question
        # becomes, and the scratch that held it is gone at exit.
        phases = re.findall(r"^TIMING (\S+) (\d+)s$", log_text, re.M)
        if phases:
            print(f"{name}: phases " + ", ".join(
                f"{p} {s}" for p, s in phases if p != "matrix"))
        keep_lane_log(name, LANES_KEEP_DIR)
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
