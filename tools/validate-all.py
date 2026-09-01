#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# The whole matrix, one invocation. The five lanes are independent, so
# they run CONCURRENTLY by default; --serial for benchmarking a single
# lane's honest numbers, debugging under contention, or recording mode
# (one screen, one recorder).
#
# Usage: validate-all.sh [--serial] [windows-host]
#   windows-host defaults to akhil@192.168.64.2 (the UTM VM;
#   deploy-win auto-starts it).
#
# tools/check-gates.sh pins the parallel launch block: all five
# platform lanes queued together with no barrier between them,
# Android's exact lane process waited on, then the one gate sweep at
# niceness 10.

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

    # The lane's own duration, stamped WHEN IT EXITS — a collection
    # that waited in queue order would bill an early finisher for its
    # slower siblings' time (the shell measured inside each subshell).
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
if MODE == "parallel":
    # ALL FIVE PLATFORM LANES START TOGETHER. The one gate sweep waits
    # for Android's recorded process, then runs at niceness 10.
    # THE WALL IS THEREFORE ANDROID PLUS THE SWEEP, IN SERIES, and no
    # longer the slowest lane: on the accepted 2026-08-24 run Android
    # ended at 268s and the sweep took 348s more (619s wall), while
    # the longest other lane — Windows, 533s — was already done, so
    # the sweep's last ~83s ran with nothing beside it. docs/traps.md
    # records the contention measurements; the gates ceiling below
    # owns what that band means for the anomaly guard.
    # The token is a t0 fingerprint of every keyed gate's inputs: it
    # attests SAME-TREE, not swept-and-passed, so the mac lane can
    # skip its own sweep while the matrix still owns the later
    # sweep's rc. Nothing survives this invocation; a hand-run of
    # validate-mac has no token and sweeps.
    got = subprocess.run(["tools/gates.sh", "--fingerprint"],
                         stdout=subprocess.PIPE, text=True,
                         encoding="utf-8", errors="replace",
                         check=False)
    if got.returncode != 0:
        sys.exit(1)
    os.environ["KAYA_MATRIX_GATES_TOKEN"] = got.stdout.strip()
    run_lane("mac", ["tools/validate-mac.sh"])
    # KAYA_LINUX_JOBS scopes a leg-pool width to the linux lane alone
    # — bare KAYA_JOBS would resize the mac pool too. Empty means the
    # lane's own default (run-suites' ${KAYA_JOBS:-8} treats empty as
    # unset). Measured under the full matrix 2026-08-20, and 8 stays:
    # width 6 was 431s (narrower just serializes cheap legs), 8 was
    # 401s, and 10 was 358s FOR THIS LANE but flaked a stall leg on
    # android and a picker leg on iOS in the same run — the wall only
    # moved 403 -> 394 while the extra host share destabilized the
    # phone lanes, KAYA_WIN_JOBS' contention story one lane over.
    run_lane("linux", ["tools/validate-linux.sh"],
             env={"KAYA_JOBS": os.environ.get("KAYA_LINUX_JOBS", "")})
    run_lane("windows", ["tools/deploy-win.sh", HOST, "all"])
    run_lane("ios", ["tools/ios/run-sim.sh"])
    run_lane("android", ["tools/android/run-emulator.sh"])
    android_lane_proc = lane_procs[-1]
    android_lane_proc.wait()
    run_lane("gates", ["nice", "-n", "10", "tools/gates.sh"])
else:
    run_lane("mac", ["tools/validate-mac.sh"])
    run_lane("linux", ["tools/validate-linux.sh"])
    run_lane("windows", ["tools/deploy-win.sh", HOST, "all"])
    run_lane("ios", ["tools/ios/run-sim.sh"])
    run_lane("android", ["tools/android/run-emulator.sh"])

# DURATION IS A CORRECTNESS SIGNAL (CLAUDE.md invariant 8): a lane can
# get six times slower and still report ALL PASS. Measured 2026-07-25:
# exporting GTK_A11Y=atspi lane-wide took linux from 65s to 393s — a
# change in blast radius, not in any assertion. A slower lane raises
# its number in the same commit that makes it slower; each entry
# carries that measurement.
BUDGETS = {
    # 900 since 2026-08-10, raised in the commit that makes the lane
    # slower, as this block asks. The save scene brought NINE legs
    # that must run ALONE BETWEEN DRAINS: macOS keeps a save panel's
    # last directory as a user preference shared by every process, so
    # pooled guests trample each other (measured — a leg asserting its
    # own kaya-save-<pid> directory was shown a sibling's).
    # Serialising ~18s x 9 costs about 170s that used to overlap: the
    # lane measured 610s pooled and 778s serialised, same 267 legs.
    # 900 keeps the ~1.25x headroom the other lanes have (the earlier
    # 678s reading, which this block previously declined to raise for,
    # was an environmental window and is NOT the reason for this one).
    #
    # LOWERED TO 560 on 2026-08-10, and lowering a ceiling is the
    # rarer half of this block's job. The lane stopped running its
    # guests out of `target/debug/examples`, a build directory that
    # had reached 776,613 entries — macOS enumerates an unbundled
    # executable's siblings on every launch, so all 32 rust legs
    # walked it, and the resulting LaunchServices contention starved
    # the ocaml, haskell and swift legs running beside them. All eight
    # languages now measure 1.1-1.6s a leg where four of them were
    # 8-31s (docs/deferred.md).
    #
    # Measured on the fixed tree: 431s contended at 268 legs, against
    # 966s the run before. 560 is the same ~1.25x over the contended
    # time the other lanes keep — and holding 900 here would let this
    # lane double again before saying a word, which is exactly what
    # let the old cost hide.
    #
    # 620 since 2026-09-01, raised in the commit that made the lane
    # bigger, as this block asks: the ninth binding added 42 js legs
    # (349 -> 391). STANDALONE the lane is unchanged in kind — 391
    # green at legs 275s against 248s the day before, the 27s being
    # the new legs' own cost at the python legs' per-leg rate. The
    # first contended matrix after read 546s (under 560 by 14s, with
    # the dialog legs failing fast on the host's Accessibility gate,
    # so not a clean reading); the second read 621s under a host at
    # load 75 from three simulators reseeding. 620 covers the roster
    # at the ~1.25x-over-quiet-contended headroom this block keeps;
    # the second reading is an environmental window, not the reason.
    "mac": 620,
    # 450 since 2026-08-20, raised in the commit that made the lane
    # bigger, as this block asks: the panes scene added 14 legs (seven
    # languages, both protocols), 550 -> 564. STANDALONE the lane is
    # UNCHANGED in kind — 564 legs green in the runs that landed the
    # slice, panes legs 2-3s each — and the first contended matrix
    # after read 442s against the old 420, which is the ~28s the legs
    # themselves cost. 450 keeps the same ~1.25x-over-contended
    # headroom this block has always kept.
    #
    # The history it extends: 420 since 2026-08-07, when text-ranges
    # added 16 legs (444 -> 460; contended 337s measured thrice
    # against the old 300-at-~240s).
    #
    # 470 since 2026-08-21, raised in the commit that made the lane
    # bigger, as this block asks: the tables scene added 14 legs
    # (seven languages, both protocols), 564 -> 578. STANDALONE the
    # lane is unchanged in kind — 578 green at 401s in the first quiet
    # contended matrix after — and the two busy-host matrices the same
    # day read 452s and 467s against video decode and a 46%
    # WindowServer, tripping 450 by 2s and 17s with every leg green.
    # 470 kept the ~1.25x-over-quiet-contended headroom.
    #
    # 530 since 2026-08-27, raised in the commit that made the lane
    # bigger, as this block asks: canvas added 2 legs (584 -> 586),
    # each wrapped in a11y-leg.sh's bus session (the ax-bus fix), and
    # the disk sweep the same night reset every cache. The three
    # post-sweep contended matrices read 796s (cold), 524s, 502s —
    # monotone toward warm — with every leg green all three times; 502
    # against the old 470 was the third consecutive trip, which is
    # this block's own signal to recalibrate rather than re-annotate.
    # 530 covers the warm-contended 502 with tight margin so a change
    # in kind still trips it.
    #
    # 600 since 2026-09-01, raised in the commit that made the lane
    # bigger, as this block asks: the ninth binding added 80 js legs
    # (604 -> 684, one per python leg on both protocols). STANDALONE
    # the lane is unchanged in kind — 683 green at legs 235s against
    # 222s before. The first contended matrix read 459s (under 530);
    # the second 663s under the same load-75 window as the mac
    # reading above, with 682 legs green and one wayland table read
    # a sighting. 600 keeps the ~1.25x-over-quiet-contended headroom
    # over the roster's own growth; the 663 is not the reason.
    "linux": 600,
    # 480 since 2026-08-03, and the ceiling moved in the commit that
    # made the lane slower, as this block asks. Two measured reasons,
    # neither a change in kind: filedialog_java used to ABORT at 4s
    # (the COM apartment defect) and now runs its scene to the end,
    # and the lane's four contention-sensitive legs (stall_rust,
    # panels_*) each take 20-26s longer under five concurrent lanes.
    # Everything else is unchanged — the per-leg median delta against
    # a standalone run is MINUS one second, which is the check that
    # says no work was added to every leg.
    # 520 since 2026-08-21: a run whose commit touches BINDING sources
    # pays a full manifest re-ship plus the remote javac and dotnet
    # rebuilds — measured 494s on the tables fan-out (the first
    # eight-binding commit since the per-file deploy landed) against
    # the 420-456 incremental band. The ceiling covers the
    # deploy-heavy mode; an incremental run drifting past ~460 is
    # still the signal the old 480 was for.
    "windows": 520,
    # 540 since 2026-08-10, raised in the commit that makes the lane
    # slower, as this block asks. The save scene added a leg measured
    # at 21s STANDALONE (the panel is typed into, so it is the slowest
    # non-clipboard leg on this lane), taking the lane to 74 legs.
    # Contended runs since: 401, 407, 409, 414, 416 and 446s against a
    # 420 ceiling — one crossing and two within five seconds, which is
    # a guard that fires on variance rather than on a change in kind.
    # Standalone the lane is 294s (boot 7 + three build-and-leg
    # phases), so the growth is contention amplifying real work, not
    # work added to every leg. 540 restores the ~1.25x headroom the
    # other lanes keep.
    #
    # MAC WAS DELIBERATELY NOT RAISED at the same time: it measured
    # 678s against 680 once, but that run overlapped a ~20-minute
    # window when every mac file-dialog leg failed for an
    # environmental reason (proven by running two unrelated legs as
    # controls); with the scene fully graduated it measures 610s at
    # 267 legs. Raising a ceiling to fit an environmental anomaly is
    # how a guard stops guarding.
    "ios": 540,
    # 310 since 2026-08-20: the pool-degradation trap's remedy is a
    # COLD BOOT (docs/traps.md), and the reboot run then carries
    # ~60-90s of emulator startup that the old 250 — set against a
    # warm pool — read as an anomaly. 310 clears a measured cold-boot
    # run (267s) with the usual headroom while still catching a change
    # in kind on a warm one.
    "android": 310,
    # 490 since 2026-08-23: dynamic tables added 17 watched
    # copy-target perturbations to check-steps and 12 surface/
    # forcing-app perturbations to check-sugar-surface.
    #
    # THE 378/387/391s BAND IT WAS SET AGAINST IS NOT THIS SCHEDULE'S.
    # Those three sweeps ran from t0 at ordinary priority, alongside
    # all five lanes for their whole length (docs/tables-plan.md,
    # docs/deferred.md). On the tree that changed the schedule, that
    # same from-t0 shape measured 427s at ordinary priority and 467s
    # niced (docs/traps.md) — so "1.25x over the band's top", which
    # this arm used to claim, was never true of 490 here.
    #
    # What 490 guards is the DELAYED-plus-NICED band, which has one
    # accepted sample: 348s (2026-08-24), with 218s and 208s from the
    # barrier-only and delayed-only experiments beside it. That is
    # ~1.4x. It deliberately does NOT cover 467: that reading is from
    # a schedule this file no longer runs, and a ceiling raised to
    # clear an abandoned schedule stops guarding the live one.
    #
    # The sweep is its own matrix unit AND half the wall (see the
    # launch block above): it starts only after Android exits, so its
    # tail runs at a host share no other reading has. A second
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
            print(f"{name}: DURATION ANOMALY — {secs}s exceeds the "
                  f"{budget}s ceiling. A lane that slows down by this "
                  f"much changed in kind, not in degree: look for work "
                  f"added to EVERY leg (an env export, a per-leg wait, "
                  f"a rebuild that stopped caching) before assuming it "
                  f"is load.")
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
