#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Run every milestone-0 validation natively on macOS. Run inside the
# dev shell, with a logged-in GUI session; each suite opens a window
# briefly.
#
# The scene lists, the queue (language order per scene, drain barriers,
# the panel-mode rotation points, the serial families) and the C-floor
# roster are DATA: tools/lib/lanes/mac.py, the one source the gates
# import too (docs/runner-conversion-plan.md §2, stage 4).

import atexit
import hashlib
import os
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time

from lanes import mac as lane
import flightrec_lane

TEXT = {"text": True, "encoding": "utf-8", "errors": "replace"}


def run(argv, **kw):
    return subprocess.run(argv, check=False, **kw)


def out_of(argv, stderr=subprocess.DEVNULL):
    got = subprocess.run(argv, stdout=subprocess.PIPE, stderr=stderr,
                         check=False, **TEXT)
    return got.stdout


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


os.chdir(ROOT)
# The one Python import mechanism: the kaya package resolves from here
# (the guests' sys.path shims are gone).
os.environ["PYTHONPATH"] = str(ROOT / "bindings/python")

_t0 = time.monotonic()


def timing(phase):
    global _t0
    print(f"TIMING {phase} {int(time.monotonic() - _t0)}s", flush=True)
    _t0 = time.monotonic()


# The Swift toolchain resolution stays in tools/lib/swift-toolchain.sh
# (ten shell consumers); every swiftc here goes through this bridge, so
# there is one copy of the resolution logic.
def kaya_swiftc(args, **kw):
    return run(["bash", "-c",
                'source "$1/tools/lib/swift-toolchain.sh" && shift && '
                'kaya_swiftc "$@"', "_", str(ROOT), *args], **kw)


# --lib as well as --example: the foreign guests load the cdylib, and
# --example alone would leave a stale libkaya.dylib in place. The scene
# list and the depth list are the lane module's; the leg blocks stay
# explicit there because they encode per-language coverage decisions.
BUILD_EXAMPLES = []
for _s in [*lane.SCENES, *lane.DEPTH_SCENES]:
    BUILD_EXAMPLES += ["--example", _s]
if run(["cargo", "build", "--locked", "--lib",
        *BUILD_EXAMPLES]).returncode != 0:
    sys.exit(1)
# The library the legs load must be the one this build produced — a
# build whose failure went unnoticed leaves the previous one in place
# and every verdict below is then about stale code.
if run([str(ROOT / "tools/build-id.py"), "--verify",
        "target/debug/libkaya.dylib"]).returncode != 0:
    sys.exit(1)

# STAGE THE RUST GUESTS OUT OF THE BUILD DIRECTORY, and run them from
# here. Not tidiness — launching an unbundled executable makes
# LaunchServices enumerate its CONTAINING DIRECTORY, and the same
# binary took 7.7s from a 776,613-entry target/debug/examples against
# 0.13s from a two-entry directory (measured 2026-08-10,
# docs/deferred.md). The staged list DERIVES from the module's lists,
# so a new scene cannot be built and then left running out of the
# build directory.
RUST_GUESTS = ROOT / "target/rust-guests"
shutil.rmtree(RUST_GUESTS, ignore_errors=True)
RUST_GUESTS.mkdir(parents=True)
for _s in [*lane.SCENES, *lane.DEPTH_SCENES]:
    shutil.copy2(ROOT / f"target/debug/examples/{_s}",
                 RUST_GUESTS / _s)
_staged = sum(1 for _ in RUST_GUESTS.iterdir()) + 1
if _staged > 64:
    die(f"validate-mac: the rust guest staging directory holds "
        f"{_staged} entries. It exists to be SMALL — macOS enumerates "
        f"an unbundled executable's siblings on every launch, and that "
        f"walk was 7.7s per leg when this was target/debug/examples. "
        f"Stage somewhere clean.")

# ONE FILE UNDER THE ASSET ROOT IS DERIVED and never committed
# (guests/assets/market/README.md), so the root a fresh clone has is
# incomplete until this runs. The gate sweep runs it too; a lane may
# not depend on the sweep having run, since this one can skip it (the
# matrix handshake below) and the other four never call it.
if run([sys.executable, str(ROOT / "tools/gen-market.py"),
        "--ensure"]).returncode != 0:
    print("validate-mac: python3 tools/gen-market.py --ensure failed — "
          "the market", file=sys.stderr)
    print("  family's transactions.csv is derived, so the asset root "
          "is incomplete", file=sys.stderr)
    print("  and every guest that reads it fails inside its build "
          "closure", file=sys.stderr)
    sys.exit(1)

# NOTHING TO STAGE FOR ASSETS, AND HERE IS WHY, CHECKED: the guests
# call `asset(name)`; with no KAYA_ASSET_DIR set the core falls
# through to the compile-time repo-relative default, and this lane
# runs from the repo root, so guests/assets is exactly where that
# points. LOUD, AND BEFORE ANY LEG RUNS: without the root, every guest
# that names an asset dies inside its build closure on eight legs at
# once (docs/assets-plan.md A5.4).
if not (ROOT / "guests/assets/fonts/sora-wght.ttf").is_file():
    print("validate-mac: the asset root guests/assets is not where the "
          "core's", file=sys.stderr)
    print("  repo-relative default points. This lane stages nothing "
          "because it", file=sys.stderr)
    print("  runs from the repo root; check that before doubting the "
          "guests.", file=sys.stderr)
    sys.exit(1)
_asset_count = sum(1 for f in (ROOT / "guests/assets").rglob("*")
                   if f.is_file())
print(f"assets: the root resolves by the repo-relative default "
      f"({_asset_count} files)")

# THE MATRIX HANDSHAKE (ratified 2026-08-20): when validate-all just
# ran the gate sweep in this same invocation, a MATCHING fingerprint
# means re-running it here would repeat work the matrix did seconds
# ago under contention. NOT a cache — the token never outlives one
# validate-all run, a hand-run of this script sees no token and runs
# everything, and a MISMATCH falls through to the full sweep. The
# interpreter still gets built and verified on the skip path: the legs
# run it, and gates.py was the builder this lane relied on.
_token = os.environ.get("KAYA_MATRIX_GATES_TOKEN", "")
if _token and out_of([str(ROOT / "tools/gates.py"),
                      "--fingerprint"]).strip() == _token:
    print(f"gates: skipped — validate-all ran the sweep in this matrix "
          f"run and the tree's gate fingerprint still matches "
          f"({_token})")
    if run([str(ROOT / "tools/swiftui/build-dylib.sh")]).returncode != 0:
        sys.exit(1)
    if run([str(ROOT / "tools/build-id.py"), "--verify",
            "--component", "swiftui",
            "target/swiftui/libkaya_swiftui.dylib"]).returncode != 0:
        sys.exit(1)
else:
    if run([str(ROOT / "tools/gates.py")]).returncode != 0:
        sys.exit(1)
timing("core-build+gates")

status = 0

# Legs run in a background pool (KAYA_JOBS wide, KAYA_JOBS=1 for the
# old serial behavior): every guest is its own process with a
# self-contained selftest, so nothing couples one leg to another. Each
# leg logs to its own file; verdicts print in submission order at
# drain, and a FAIL prints its log.
JOBS = int(os.environ.get("KAYA_JOBS", "8"))
LEGS_DIR = pathlib.Path(tempfile.mkdtemp())

# The flight recorder: one journal outside the build tree for every
# leg, and a capture bundle for every FAIL. The mac half — the per-leg
# sampler and the window-scoped capture — is
# tools/lib/flightrec_lane.py's MacRecorder since the runner
# conversion; a runner that cannot open the journal prints the miss
# once and still runs every leg.
FR = flightrec_lane.MacRecorder(ROOT)
FLIGHTREC_SCRATCH = pathlib.Path(tempfile.mkdtemp())

# ── THE MAC FILE-PANEL VIEW MODE, ROTATED RATHER THAN INHERITED ─────
# NSOpenPanel's file browser publishes a DIFFERENT accessibility
# identifier per view mode, and the mode is machine-wide
# (`NSGlobalDomain NSNavPanelFileListModeForOpenMode2`: 1 columns, 2
# list, 3 icons), written by any application's open panel for every
# application on the box (docs/traps.md). The interpreter reads all
# three shapes (KayaPanelShape); the lane sets the mode itself and
# splits the filedialog legs across the three, or one of the three
# readers is dead code on any given run.
#
# WRITING A MACHINE-WIDE USER PREFERENCE IS A SIDE EFFECT ON THE
# DEVELOPER'S BOX. The original is captured before the first change,
# restored on EXIT/INT/TERM, and — because SIGKILL runs no trap —
# written to a stamp file the next run restores from first.
PANEL_MODE_KEY = "NSNavPanelFileListModeForOpenMode2"
PANEL_MODE_STAMP = ROOT / "target/panel-mode.orig"


def panel_mode_read():
    # "unset" is a real value: the key may be absent, and restoring to
    # absent is a delete, not a write of some guessed default.
    got = subprocess.run(["defaults", "read", "-g", PANEL_MODE_KEY],
                         stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=False, **TEXT)
    return got.stdout.strip() if got.returncode == 0 else "unset"


def panel_mode_write(value):
    if value == "unset":
        run(["defaults", "delete", "-g", PANEL_MODE_KEY],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        run(["defaults", "write", "-g", PANEL_MODE_KEY, "-int",
             str(value)])


def panel_mode_restore():
    """Idempotent, and it VERIFIES rather than assumes: the stamp is
    removed only once the box reads back the value it started with. A
    restore that failed keeps the stamp, so the next run and probe-env
    both still see the debt."""
    if not PANEL_MODE_STAMP.is_file():
        return True
    want = PANEL_MODE_STAMP.read_text(encoding="utf-8").strip()
    panel_mode_write(want)
    back = panel_mode_read()
    if back != want:
        print(f"validate-mac: FAILED to put {PANEL_MODE_KEY} back: "
              f"wanted {want}, reads {back}. By hand: defaults write "
              f"-g {PANEL_MODE_KEY} -int {want}", file=sys.stderr)
        return False
    PANEL_MODE_STAMP.unlink(missing_ok=True)
    return True


PANEL_MODES_RUN = []


def panel_mode_set(mode, name):
    """Put the panel in one mode for the group that follows, and say
    so in the log — the mode is printed as a FACT for every group
    (the 2026-08-06 outage cost two hours for a value nothing
    logged). A ROTATION THAT DID NOT TAKE PROVES NOTHING: the write
    is read back and the lane refuses rather than pretend it
    rotated."""
    global status
    if not PANEL_MODE_STAMP.is_file():
        PANEL_MODE_STAMP.parent.mkdir(parents=True, exist_ok=True)
        PANEL_MODE_STAMP.write_text(panel_mode_read() + "\n",
                                    encoding="utf-8")
    panel_mode_write(mode)
    back = panel_mode_read()
    if back != str(mode):
        print(f'validate-mac: {PANEL_MODE_KEY} did not take — wrote '
              f'{mode}, reads "{back}"', file=sys.stderr)
        status = 1
        return False
    PANEL_MODES_RUN.append(str(mode))
    orig = PANEL_MODE_STAMP.read_text(encoding="utf-8").strip()
    print(f"== file panel view mode {mode} ({name}); restoring {orig} "
          f"at exit")
    return True


def panel_modes_missing():
    """Which of the three modes no leg ran under: deleting a group —
    or a refused write — leaves a lane still reporting ALL PASS while
    one of the interpreter's three readers goes back to being dead
    code, which is the silence this whole block exists to end."""
    return [m for m in ("1", "2", "3") if m not in PANEL_MODES_RUN]


# A previous run that was SIGKILLed, or a machine that lost power,
# left the box rotated and its original value on disk. Hand it back
# HERE, before this run reads anything, and say so out loud.
if PANEL_MODE_STAMP.is_file():
    print(f"validate-mac: an earlier run left the file-panel view mode "
          f"changed; restoring "
          f"{PANEL_MODE_STAMP.read_text(encoding='utf-8').strip()}")
    if not panel_mode_restore():
        status = 1

_torn = threading.Lock()


def kaya_teardown():
    if not _torn.acquire(blocking=False):
        return
    FR.flush()
    shutil.rmtree(LEGS_DIR, ignore_errors=True)
    shutil.rmtree(FLIGHTREC_SCRATCH, ignore_errors=True)
    panel_mode_restore()


atexit.register(kaya_teardown)
# EXIT alone is not enough for a signal death: a lane interrupted
# mid-rotation must still hand the box back.
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))

# Recording mode (KAYA_RECORD=1): ONE suite-long ScreenCaptureKit
# stream films every leg. The filter is display-scoped but
# include-listed — only guest windows are composited — and parallel
# legs tile into slots (KAYA_WIN_SLOT) so their crops never overlap.
# One stream on purpose: concurrent SCK window streams starve and die
# where a single stream is reliable.
RECORDINGS = ROOT / "target/recordings/mac"
REC_PROC = None
PIDFILE = RECORDINGS / "pids"
if os.environ.get("KAYA_RECORD"):
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        die("recording mode needs ffmpeg/ffprobe — run inside nix "
            "develop")
    if run([str(ROOT / "tools/harness-extract.sh"),
            "--selftest"]).returncode != 0:
        sys.exit(1)
    shutil.rmtree(RECORDINGS, ignore_errors=True)
    RECORDINGS.mkdir(parents=True)
    # The binary's path+content is its identity to the capture stack,
    # and REBUILDING IN PLACE POISONS IT: after enough rebuilds at one
    # path, shareable-content queries for that identity hang or return
    # bogus TCC declines, and the poisoned state survives reboots. A
    # content-hashed name gives each source version one stable, fresh
    # identity.
    _rec_src = ROOT / "tools/record-suite/main.swift"
    _rec_hash = hashlib.sha1(_rec_src.read_bytes()).hexdigest()[:12]
    REC_BIN = ROOT / f"target/tools/record-suite-{_rec_hash}"
    if not REC_BIN.is_file():
        (ROOT / "target/tools").mkdir(parents=True, exist_ok=True)
        for old in (ROOT / "target/tools").glob("record-suite-*"):
            old.unlink()
        if kaya_swiftc(["-O", "-framework", "ScreenCaptureKit",
                        "-framework", "AVFoundation", "-o",
                        str(REC_BIN),
                        str(_rec_src)]).returncode != 0:
            sys.exit(1)
    # Screen-capture health dies quietly: probe first and abort with
    # instructions instead of failing every leg.
    if run([str(REC_BIN), "--probe"]).returncode != 0:
        print("recording mode: screen capture probe failed.")
        print("check Screen Recording permission for this terminal/app "
              "in System")
        print("Settings -> Privacy & Security -> Screen & System Audio "
              "Recording.")
        sys.exit(1)
    PIDFILE.write_text("", encoding="utf-8")
    _rec_log = open(RECORDINGS / "rec.log", "w", encoding="utf-8")
    REC_PROC = subprocess.Popen(
        [str(REC_BIN), str(RECORDINGS / "suite.mov"), str(PIDFILE)],
        stdout=_rec_log, stderr=_rec_log)
    _rec_log.close()

_rec_slots = threading.Condition()
_rec_free = list(range(JOBS))


def run_recorded(name, argv, env, log):
    """One recorded leg: claim a tile, launch the guest into it,
    register its pid with the suite recorder, and release the guest's
    gate once the recorder reports the window tracked — a leg cannot
    outrun its recording. Returns False only for a guest failure;
    recording gaps surface at extraction."""
    rec_dir = RECORDINGS / name
    shutil.rmtree(rec_dir, ignore_errors=True)
    rec_dir.mkdir(parents=True)
    with _rec_slots:
        while not _rec_free:
            _rec_slots.wait()
        slot = _rec_free.pop(0)
    failed = False
    try:
        leg_env = dict(os.environ, **env,
                       KAYA_HARNESS_GATE=str(rec_dir / "go"),
                       KAYA_WIN_SLOT=str(slot))
        leg_env.setdefault("KAYA_SELFTEST", "1")
        with open(rec_dir / "leg.log", "w", encoding="utf-8",
                  errors="replace") as lf:
            proc = subprocess.Popen(argv, env=leg_env, stdout=lf,
                                    stderr=lf)
        with open(PIDFILE, "a", encoding="utf-8") as pf:
            pf.write(f"{proc.pid}\n")
        (rec_dir / "pid").write_text(f"{proc.pid}\n", encoding="utf-8")
        for _ in range(300):
            rec_log = (RECORDINGS / "rec.log").read_text(
                encoding="utf-8", errors="replace") \
                if (RECORDINGS / "rec.log").is_file() else ""
            if re.search(rf"TRACKING {proc.pid}$", rec_log, re.M):
                break
            if proc.poll() is not None:
                break
            time.sleep(0.05)
        (rec_dir / "go").write_text("", encoding="utf-8")
        # Bounded: a hung guest fails the leg instead of wedging the
        # suite.
        try:
            proc.wait(timeout=120)
        except subprocess.TimeoutExpired:
            proc.kill()
            with open(log, "a", encoding="utf-8") as lf:
                lf.write(f"{name}: guest did not exit within 120s\n")
            failed = True
        if proc.wait() != 0:
            failed = True
    finally:
        with _rec_slots:
            _rec_free.append(slot)
            _rec_slots.notify()
    if failed:
        with open(log, "a", encoding="utf-8") as lf:
            lf.write((rec_dir / "leg.log").read_text(
                encoding="utf-8", errors="replace"))
    return not failed


def rec_suite_stop():
    """Stop the suite recorder and derive every leg's stills from the
    film. The recorder drains until frames quiesce before finalizing;
    its exit is still nobody's word but its own — bound it."""
    global status
    if not os.environ.get("KAYA_RECORD") or REC_PROC is None:
        return
    REC_PROC.send_signal(signal.SIGINT)
    try:
        REC_PROC.wait(timeout=25)
    except subprocess.TimeoutExpired:
        print("recording: recorder did not exit within 25s of SIGINT; "
              "killing")
        REC_PROC.kill()
        status = 1
    rec_log = (RECORDINGS / "rec.log").read_text(encoding="utf-8",
                                                 errors="replace")
    anchor = ""
    scale = ""
    for line in rec_log.splitlines():
        if line.startswith("RECORDING_START "):
            anchor = line.split(" ", 1)[1]
        if line.startswith("SCALE ") and not scale:
            scale = line.split(" ", 1)[1]
    if not anchor or not scale:
        print("recording: no anchor in rec.log — no stills")
        print(rec_log)
        status = 1
        return
    # Legs share the one film; extractions are independent — run them
    # all at once and collect verdicts after. The packet index is
    # scanned once here, not per worker.
    pts = out_of(["ffprobe", "-v", "quiet", "-select_streams", "v",
                  "-show_entries", "packet=pts_time", "-of", "csv=p=0",
                  str(RECORDINGS / "suite.mov")])
    (RECORDINGS / ".pts").write_text(
        "\n".join(sorted(pts.split(), key=float)) + "\n",
        encoding="utf-8")
    ext_env = dict(os.environ, KAYA_PTS_INDEX=str(RECORDINGS / ".pts"))
    procs = []
    for rec_dir in sorted(RECORDINGS.iterdir()):
        if not (rec_dir / "pid").is_file():
            continue
        pid = (rec_dir / "pid").read_text(encoding="utf-8").strip()
        window = ""
        for line in rec_log.splitlines():
            if line.startswith(f"WINDOW {pid} "):
                window = line
        ext_log = open(rec_dir / "extract.log", "w", encoding="utf-8")
        if not window:
            ext_log.write(f"{rec_dir.name}: never tracked by the "
                          f"recorder\n")
            ext_log.close()
            (rec_dir / "extract-failed").write_text("", encoding="utf-8")
            continue
        _, _, x, y, wd, ht = window.split()
        s = float(scale)
        crop = (f"crop={int(float(wd) * s)}:{int(float(ht) * s)}:"
                f"{int(float(x) * s)}:{int(float(y) * s)}")
        (rec_dir / "crop").write_text(crop + "\n", encoding="utf-8")
        p = subprocess.Popen(
            [str(ROOT / "tools/harness-extract.sh"),
             str(RECORDINGS / "suite.mov"), str(rec_dir / "leg.log"),
             anchor, str(rec_dir / "steps"), crop],
            stdout=ext_log, stderr=ext_log, env=ext_env)
        procs.append((rec_dir, p, ext_log))
    for rec_dir, p, ext_log in procs:
        if p.wait() != 0:
            (rec_dir / "extract-failed").write_text("", encoding="utf-8")
        ext_log.close()
    for rec_dir in sorted(RECORDINGS.iterdir()):
        if not rec_dir.is_dir() or not (rec_dir / "extract.log").is_file():
            continue
        print((rec_dir / "extract.log").read_text(encoding="utf-8",
                                                  errors="replace"),
              end="")
        if (rec_dir / "extract-failed").exists():
            status = 1


# ------------------------------------------------------------ the pool
_leg_names = []
_leg_threads = []


def _leg_worker(name, argv, env):
    log = LEGS_DIR / f"{name}.log"
    t0 = time.monotonic()
    if os.environ.get("KAYA_RECORD"):
        ok = run_recorded(name, argv, env, log)
        verdict = "PASS" if ok else "FAIL"
        secs = int(time.monotonic() - t0)
        (LEGS_DIR / f"{name}.verdict").write_text(verdict + "\n",
                                                  encoding="utf-8")
        (LEGS_DIR / f"{name}.secs").write_text(f"{secs}\n",
                                               encoding="utf-8")
        # Journalled, but no sampler and no bundle: recording mode is
        # already filming every leg, and a poller beside a capture
        # stream is load on the one run that is timed for its frames.
        FR.leg(name, verdict, secs, FR.fail_sentence(log), "")
        return
    leg_env = dict(os.environ, **env)
    leg_env.setdefault("KAYA_SELFTEST", "1")
    scratch = FLIGHTREC_SCRATCH / name
    # THE VERB TRACE (crates/kaya/src/vtrace.rs and its two interpreter
    # copies): written by the guest on a failure alone, adopted into the
    # bundle by mac_leg, gone with the scratch either way.
    scratch.mkdir(parents=True, exist_ok=True)
    leg_env["KAYA_VERB_TRACE"] = str(scratch / "verb-trace.txt")
    with open(log, "w", encoding="utf-8", errors="replace") as lf:
        # The guest runs under `timeout`, which is both the 120s bound
        # and the sampler's anchor (the guest is timeout's descendant
        # and nothing else is).
        proc = subprocess.Popen(["timeout", "120", *argv], env=leg_env,
                                stdout=lf, stderr=lf)
        sampler = FR.sampler_start(scratch, proc)
        rc = proc.wait()
        FR.sampler_stop(sampler)
    verdict = "PASS" if rc == 0 else "FAIL"
    secs = int(time.monotonic() - t0)
    (LEGS_DIR / f"{name}.verdict").write_text(verdict + "\n",
                                              encoding="utf-8")
    (LEGS_DIR / f"{name}.secs").write_text(f"{secs}\n",
                                           encoding="utf-8")
    FR.mac_leg(name, verdict, secs, log, scratch)


def queue_leg(name, argv, env):
    global status
    if JOBS == 1 and not os.environ.get("KAYA_RECORD"):
        # STILL STREAMED — serial mode exists to watch a leg live —
        # but teed to the same log file the pooled path keeps, so the
        # journal carries the failure SENTENCE rather than only the
        # verdict.
        print(f"== {name} ==")
        t0 = time.monotonic()
        leg_env = dict(os.environ, **env)
        leg_env.setdefault("KAYA_SELFTEST", "1")
        scratch = FLIGHTREC_SCRATCH / name
        log = LEGS_DIR / f"{name}.log"
        with open(log, "w", encoding="utf-8", errors="replace") as lf:
            proc = subprocess.Popen(["timeout", "120", *argv],
                                    env=leg_env,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, **TEXT)
            sampler = FR.sampler_start(scratch, proc)
            for line in proc.stdout:
                print(line, end="")
                lf.write(line)
            rc = proc.wait()
            FR.sampler_stop(sampler)
        secs = int(time.monotonic() - t0)
        verdict = "PASS" if rc == 0 else "FAIL"
        print(f"{name}: {verdict} ({secs}s)")
        if rc != 0:
            status = 1
        FR.mac_leg(name, verdict, secs, log, scratch)
        return
    _leg_names.append(name)
    t = threading.Thread(target=_leg_worker, args=(name, argv, env))
    t.start()
    _leg_threads.append(t)
    # Watchdog: a wedged pool must die loudly in minutes, not silently
    # absorb tens of legs. No slot freeing for 3 minutes is never
    # legitimate — legs are bounded far tighter.
    spins = 0
    while sum(t.is_alive() for t in _leg_threads) >= JOBS:
        spins += 1
        if spins > 900:
            die(f"pool wedged: "
                f"{sum(t.is_alive() for t in _leg_threads)} legs "
                f"running, none finishing; queued={len(_leg_names)}")
        time.sleep(0.2)


def drain():
    """Collect the pool: verdicts in submission order, logs for
    failures only, plus the two diagnostic notes a bare verdict cannot
    carry."""
    global status
    for t in _leg_threads:
        t.join()
    _leg_threads.clear()
    for name in _leg_names:
        vfile = LEGS_DIR / f"{name}.verdict"
        verdict = (vfile.read_text(encoding="utf-8").strip()
                   if vfile.is_file() else "FAIL")
        print(f"== {name} ==")
        log = LEGS_DIR / f"{name}.log"
        log_text = (log.read_text(encoding="utf-8", errors="replace")
                    if log.is_file() else "")
        sfile = LEGS_DIR / f"{name}.secs"
        secs = (sfile.read_text(encoding="utf-8").strip()
                if sfile.is_file() else "?")
        if verdict != "PASS":
            print(log_text, end="")
            # The confusing failure class: verdict printed OK but the
            # leg still failed. Two causes share it and the note may
            # not pick one (invariant 3): a nonzero guest exit (the
            # Stage::finish class), or a wrapper failing after the
            # verdict.
            if "KAYA_SELFTEST: OK" in log_text:
                print(f"{name}: note — verdict was OK but the leg "
                      f"exited nonzero: the guest's exit path, or a "
                      f"wrapper clause failing after the verdict — its "
                      f"sentence, if any, is above")
            # A SILENT leg has two very different meanings — split by
            # duration because the mac timeout is a KILL: a killed
            # guest loses whatever its block-buffered stdout was
            # holding, so an empty log there means "hung with its
            # trace in the buffer", not "never started" (read the
            # wrong way 2026-07-25; docs/traps.md).
            if "KAYA_HARNESS" not in log_text:
                if secs != "?" and int(secs) >= 115:
                    print(f"{name}: note — NO OUTPUT, and it ran to "
                          f"the 120s timeout. It was KILLED: its "
                          f"buffered trace died with it, so this is a "
                          f"HANG, not a failure to start. Reproduce it "
                          f"and sample the live process — that is what "
                          f"named the accessibility legs' layout stall "
                          f"(docs/traps.md).")
                else:
                    print(f"{name}: note — NO OUTPUT AT ALL and it "
                          f"exited early. The guest never reached the "
                          f"harness: a bad library load, a missing "
                          f"display, or a blocking connect at startup. "
                          f"Look before the scene, not inside it.")
            status = 1
        print(f"{name}: {verdict} ({secs}s)", flush=True)
    _leg_names.clear()


# The guest builds are per-language INDEPENDENT, so they run as a pool
# (measured 2026-07-22: 29-38s serial, bounded by the slowest language
# when pooled). Each job logs to its own file; any failure prints its
# log and dies — no silent partial builds.
BUILDS_DIR = pathlib.Path(tempfile.mkdtemp())


def build_ocaml():
    # --root . BECAUSE DUNE WALKS UP: run from a git worktree under
    # the repo, a bare `dune build` builds the PARENT checkout
    # (measured 2026-08-28).
    return run(["dune", "build", "--root", "."],
               stdout=_blog("ocaml"), stderr=subprocess.STDOUT)


def build_haskell():
    return run(["cabal", "build", "all",
                f"--extra-lib-dirs={ROOT}/target/debug",
                f"--ghc-options=-L{ROOT}/target/debug "
                f"-optl-Wl,-rpath,{ROOT}/target/debug", "-v0"],
               cwd=ROOT / "guests/haskell",
               stdout=_blog("haskell"), stderr=subprocess.STDOUT)


def build_csharp():
    # dotnet run rebuilds per invocation; build once, legs exec it.
    return run(["dotnet", "build", "--nologo", "-v", "q",
                "guests/csharp/kaya-guests.csproj"],
               stdout=_blog("csharp"), stderr=subprocess.STDOUT)


def build_go():
    # ONE BINARY FOR EVERY SCENE: guests/go/cmd imports every scene
    # library and picks one from KAYA_SELFTEST. encodebench is
    # guest-only and a benchmark, its own main package.
    (ROOT / "target/go-guests").mkdir(parents=True, exist_ok=True)
    rc = run(["go", "build", "-o", "target/go-guests/kaya-go",
              "dev.kaya/guests/go/cmd"],
             stdout=_blog("go"), stderr=subprocess.STDOUT)
    if rc.returncode != 0:
        return rc
    return run(["go", "build", "-o", "target/go-guests/encodebench",
                "dev.kaya/guests/go/encodebench"],
               stdout=_blog("go"), stderr=subprocess.STDOUT)


def build_swift():
    """The same bindings the iOS bundles compile, linked against
    libkaya.dylib. swiftc allows top-level code only in a file named
    main.swift, so each scene gets its own staging dir and the
    compiles pool. DEPTH_SCENES too: a depth slice's guests arrive one
    language at a time, and the file test decides — a scene whose
    Swift guest has not landed is skipped, not a build failure."""
    (ROOT / "target/swift-guests").mkdir(parents=True, exist_ok=True)
    procs = []
    for guest in [*lane.SCENES, *lane.DEPTH_SCENES]:
        src = ROOT / f"guests/swift/{guest}.swift"
        if not src.is_file():
            continue
        stage = ROOT / f"target/swift-guests/.stage-{guest}"
        shutil.rmtree(stage, ignore_errors=True)
        stage.mkdir(parents=True)
        shutil.copy2(src, stage / "main.swift")
        companions = []
        if (ROOT / f"guests/swift/{guest}+Kaya.swift").is_file():
            companions = [f"guests/swift/{guest}+Kaya.swift"]
        blog = open(stage / "build.log", "w", encoding="utf-8")
        p = subprocess.Popen(
            ["bash", "-c",
             'source "$1/tools/lib/swift-toolchain.sh" && shift && '
             'kaya_swiftc "$@"', "_", str(ROOT),
             "-import-objc-header", "crates/kaya/include/kaya.h",
             "bindings/swift/KayaWire.swift",
             "bindings/swift/KayaApp.swift",
             "bindings/swift/KayaRecords.swift",
             "bindings/swift/KayaSums.swift",
             *companions, str(stage / "main.swift"),
             "-L", "target/debug", "-lkaya",
             "-Xlinker", "-rpath", "-Xlinker",
             f"{ROOT}/target/debug",
             "-o", f"target/swift-guests/{guest}"],
            stdout=blog, stderr=blog)
        procs.append((guest, stage, p, blog))
    rc = 0
    for guest, stage, p, blog in procs:
        if p.wait() != 0:
            blog.close()
            with open(_blog_path("swift"), "a",
                      encoding="utf-8") as out:
                out.write((stage / "build.log").read_text(
                    encoding="utf-8", errors="replace"))
            rc = 1
        else:
            blog.close()
    for stage in (ROOT / "target/swift-guests").glob(".stage-*"):
        shutil.rmtree(stage, ignore_errors=True)
    return subprocess.CompletedProcess([], rc)


def build_c():
    # THE C FLOOR, THE SCENES THIS LANE ACTUALLY RUNS: the module's
    # C_SCENES, which check-steps' sweep_c_floor reads from the other
    # side — a guest built here and run nowhere is the false-coverage
    # shape that census was written against.
    return run(["make", "-C", "guests/c",
                f"SCENES={' '.join(lane.C_SCENES)}",
                f"TARGET_DIR={ROOT}/target/debug",
                f"OUT={ROOT}/target/c-guests"],
               stdout=_blog("c"), stderr=subprocess.STDOUT)


def build_java():
    # The shared binding + the desktop transport + every scene + the
    # Main selector, one javac.
    shutil.rmtree(ROOT / "target/java-guests", ignore_errors=True)
    (ROOT / "target/java-guests").mkdir(parents=True)
    srcs = ["bindings/java-desktop/dev/kaya/KayaRing.java",
            *sorted(str(p.relative_to(ROOT))
                    for p in (ROOT / "bindings/java/dev/kaya"
                              ).glob("*.java")),
            *sorted(str(p.relative_to(ROOT))
                    for p in (ROOT / "guests/java/dev/kaya/milestone2kt"
                              ).glob("*.java")),
            "guests/java-desktop/dev/kaya/milestone2kt/Main.java"]
    return run(["javac", "-encoding", "UTF-8", "-d",
                "target/java-guests", *srcs],
               stdout=_blog("java"), stderr=subprocess.STDOUT)


def _blog_path(name):
    return BUILDS_DIR / f"{name}.log"


def _blog(name):
    return open(_blog_path(name), "a", encoding="utf-8")


_build_threads = []
_build_rc = {}


def run_build(name, fn):
    def go():
        _build_rc[name] = fn().returncode

    t = threading.Thread(target=go)
    t.start()
    _build_threads.append((name, t))


run_build("ocaml", build_ocaml)
run_build("haskell", build_haskell)
run_build("csharp", build_csharp)
run_build("go", build_go)
run_build("swift", build_swift)
run_build("java", build_java)
run_build("c", build_c)
_build_status = 0
for _name, _t in _build_threads:
    _t.join()
    if _build_rc.get(_name, 1) != 0:
        print(f"guest build FAILED: {_name}", file=sys.stderr)
        blog = _blog_path(_name)
        if blog.is_file():
            print(blog.read_text(encoding="utf-8", errors="replace"),
                  file=sys.stderr, end="")
        _build_status = 1
shutil.rmtree(BUILDS_DIR, ignore_errors=True)
if _build_status != 0:
    sys.exit(1)

_hs_bins = {}


def hs_bin(name):
    if name not in _hs_bins:
        got = subprocess.run(["cabal", "list-bin", name, "-v0"],
                             cwd=ROOT / "guests/haskell",
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=False,
                             **TEXT)
        _hs_bins[name] = got.stdout.strip()
    return _hs_bins[name]


CS_GUEST = "guests/csharp/bin/Debug/net10.0/kaya-guests.dll"

# The encode-benchmark leg: the generated encoders must clear their
# floor rates (structural-regression guard, not a race).
if run([str(ROOT / "tools/bench-encode.sh")],
       env=dict(os.environ, CS_GUEST=CS_GUEST)).returncode != 0:
    sys.exit(1)
timing("guest-builds+bench")

# Every guest against the SwiftUI backend, the one macOS backend. The
# interpreter build's exit status was load-bearing enough to move into
# gates.py/build-dylib above; KAYA_SWIFTUI_LIB is what every leg
# loads.
os.environ["KAYA_SWIFTUI_LIB"] = str(
    ROOT / "target/swiftui/libkaya_swiftui.dylib")

_scripts = {}


def scene_script(scene):
    """The Swift interpreter reads the scene script from the
    environment (the Rust backends embed theirs at build time).
    Comments stripped: some transports fold newlines into `;`, and a
    leading comment must not swallow the folded script. Newlines are
    KEPT on this lane."""
    if scene not in _scripts:
        lines = [line for line in
                 (ROOT / f"tools/scenes/{scene}.steps").read_text(
                     encoding="utf-8").splitlines()
                 if not line.startswith("#")]
        _scripts[scene] = "\n".join(lines)
    return _scripts[scene]


KAYA_LIB_LANGS = lane.KAYA_LIB_LANGS


def leg_argv(scene, lang):
    # ONE COPY, in the lane module: tools/run-leg.py runs a leg by hand
    # through the same mapping and the same env.
    return lane.leg_argv(scene, lang, hs_bin)


def leg_env(scene, lang, appearance=""):
    """Per-leg env, never a persisting export (the shell's one
    KAYA_SELFTEST_SCRIPT export once ran another scene's steps)."""
    env = lane.leg_env(ROOT, scene, lang, appearance)
    # The lane's own script cache; the module's loader re-reads.
    env["KAYA_SELFTEST_SCRIPT"] = scene_script(scene)
    return env


for _entry in lane.ORDER:
    _kind = _entry[0]
    if _entry == ("drain",):
        drain()
    elif _kind == "panel_mode":
        panel_mode_set(_entry[1], _entry[2])
    elif _kind == "panel_check":
        _gap = panel_modes_missing()
        if _gap:
            print(f"validate-mac: the filedialog legs ran panel view "
                  f"modes \"{' '.join(PANEL_MODES_RUN)}\" — mode(s) "
                  f"{' '.join(_gap)} were exercised by nothing (1 "
                  f"columns, 2 list, 3 icons). One of KayaPanelShape's "
                  f"three readers in swift/KayaSwiftUI.swift is dead "
                  f"code this run, which is exactly how 2026-08-06 "
                  f"happened", file=sys.stderr)
            status = 1
        if not panel_mode_restore():
            status = 1
    elif _kind == "dark_leg":
        _name, _scene, _lang = lane.DARK_LEG
        queue_leg(_name, leg_argv(_scene, _lang),
                  leg_env(_scene, _lang, appearance="dark"))
    else:
        _scene, _langs = _entry
        for _lang in _langs:
            queue_leg(lane.leg_name(_scene, _lang),
                      leg_argv(_scene, _lang), leg_env(_scene, _lang))
drain()
timing("legs")

rec_suite_stop()
if os.environ.get("KAYA_RECORD"):
    timing("recording-stop+stills")

# The one-line verdict: suites accumulate failures rather than abort,
# so a truncated log must still end with the answer.
if status == 0:
    print("validate-mac: ALL PASS")
else:
    print("validate-mac: FAILURES ABOVE")
sys.exit(status)
