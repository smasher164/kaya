#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Build, install, and self-test the scenes in the Android emulator.
# Usage: tools/android/run-emulator.py [compose|jvm|go|python|all]
#
# stdout is invisible to an Android app process, so selftest results are
# read from logcat. The roster, the per-leg modifiers and the
# declared-off lists (split and panels are desktop-only BY DESIGN) are
# DATA: tools/lib/lanes/android.py, the source the gates import too.

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

from packaging import android as packaging_android
from packaging import identity as app_identity
from lanes import android as lane
import exclusive
import scene_cut
import flightrec_lane

# Device output is not clean UTF-8 (docs/traps.md, "NOT UTF-8").
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


_t0 = time.monotonic()


def timing(phase):
    global _t0
    print(f"TIMING {phase} {int(time.monotonic() - _t0)}s", flush=True)
    _t0 = time.monotonic()


# Compile the android target before anything heavy: a missing match arm
# should fail here, not after the emulator boots.
if run([str(ROOT / "tools/check-targets.py"), "android"]).returncode != 0:
    sys.exit(1)

SUITE = sys.argv[1] if len(sys.argv) > 1 else "all"
# An unknown suite name is refused rather than run as zero legs, which
# would print ALL PASS having run nothing.
if SUITE not in (*lane.SUITES, "all"):
    die(f"run-emulator: unknown suite {SUITE!r} (one of: "
        f"{', '.join((*lane.SUITES, 'all'))})")
os.chdir(ROOT)

for gen in ("gen-header", "gen-bindings"):
    if run([str(ROOT / f"tools/{gen}.py"), "--check"]).returncode != 0:
        sys.exit(1)
timing("preflight")

# The emulator/snapshot state library stays SHELL: tools/probe-env.sh
# sources it too, so it is called through this bridge rather than
# copied (docs/runner-conversion-plan.md §6).
AESTATE = ROOT / "tools/lib/android-emulator-state.sh"


def aestate(fn, *args):
    argv = ["bash", "-c", f'source "{AESTATE}"; "$@"', "_", fn, *args]
    got = subprocess.run(argv, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=False, **TEXT)
    return got.returncode, got.stdout


if run(["bash", str(AESTATE), "--selftest"]).returncode != 0:
    sys.exit(1)

# AVDs live under target/ so nothing leaks into $HOME.
os.environ["ANDROID_AVD_HOME"] = str(ROOT / "target/avd")
pathlib.Path(os.environ["ANDROID_AVD_HOME"]).mkdir(parents=True,
                                                   exist_ok=True)
AVD = "kaya"
IMAGE = "system-images;android-35;google_apis;arm64-v8a"
GUEST_EMULATOR_ID = "/data/local/tmp/kaya-emulator-identity"
_rc, _state = aestate("android_emulator_state_id",
                      os.environ.get("ANDROID_SDK_ROOT", ""))
if _rc != 0 or "\n" not in _state.strip():
    die("run-emulator: could not resolve the emulator state identity")
EMULATOR_EXE, SYSTEM_IMAGE_DIR = _state.strip().split("\n", 1)
# One tablet alongside the phone pool, for exactly one reason: every
# pool device is 360dp wide (KAYA_ANDROID_LCD below), an unambiguously
# COMPACT window, and Material shows two panes only at 840dp — so nothing
# else in this lane observes the list-detail SPLIT arm, and a wrong one
# compiled and passed everything.
TABLET_AVD = "kaya-tablet"

_avds = out_of(["avdmanager", "list", "avd", "-c"]).splitlines()
if AVD not in _avds:
    run(["avdmanager", "create", "avd", "-n", AVD, "-k", IMAGE],
        input="no\n", stdout=subprocess.DEVNULL, **TEXT)
if TABLET_AVD not in _avds:
    # medium_tablet: a 2560x1600 panel at density 320 whose NATURAL
    # orientation is landscape, so a headless instance comes up at
    # 1280dp, past Material's 840. Measured both ways: rotated to
    # portrait the same device reports 800dp, INSIDE the 400..840 band.
    # config.ini's hw.initialOrientation does NOT decide this, which is
    # why the width is ASSERTED at boot below.
    run(["avdmanager", "create", "avd", "-n", TABLET_AVD, "-k", IMAGE,
         "-d", "medium_tablet"],
        input="no\n", stdout=subprocess.DEVNULL, **TEXT)

# All pool instances share the one AVD READ-ONLY — the sharing rule is
# all-or-nothing, a read-write instance locks every sibling out — and
# read-only instances quickboot from the snapshot in ~2-4s. The snapshot
# itself can only be written by a read-write instance. Pool instances
# stay warm across runs on purpose (docs/traps.md, "An Android toolchain
# move outlives its dev shell").
if not os.environ.get("KAYA_ANDROID_EMUS", "4").isdigit():
    die("run-emulator: KAYA_ANDROID_EMUS must be a positive integer")
POOL = int(os.environ.get("KAYA_ANDROID_EMUS", "4"))
if POOL < 1:
    die("run-emulator: KAYA_ANDROID_EMUS must be at least 1")
TABLET_PORT = 5554 + 2 * POOL
TABLET_SERIAL = f"emulator-{TABLET_PORT}"

# The `drag` verb's injection budget (docs/dnd-plan.md D10): how many
# times one request may be injected while the app has not acked it, and
# how long after an injection ends before the next is allowed. The retry
# is for a press that never became a drag, and that try costs the hold
# alone — three of them and their two gaps come to 16s of the verb's own
# 20s ack ceiling. A try that DID start is not retried at all (the
# in-flight check below), so the long ones are never repeated.
DRAG_INJECT_TRIES = 3
DRAG_INJECT_RETRY_S = 2.0

# THE GESTURE IS BUILT BY HAND, GATED ON THE APP'S OWN START AND PACED BY
# THE HOST'S LOAD (docs/deferred.md's android `dnd-compose` drag WATCH,
# twenty-four sightings). `input draganddrop` is ONE guest-side command
# running a FIXED schedule the runner cannot look into — the press,
# Android's own long-press wait, the moves, the release — so its moves are
# spent whether or not the drag session exists yet, which is exactly what
# the twenty-third sighting read: `KAYA_DRAG_STARTED`, then `ended op=0
# entered=0` with an aim inside both boxes and no DRAG_LOCATION ever
# reaching the app. `input motionevent DOWN|MOVE|UP` (on the pool's image,
# API 35) lets the runner press, WAIT for KAYA_DRAG_STARTED and only then
# walk the moves, so no move can precede the session. Measured on a quiet
# emulator 2026-09-06: the long press fires 497ms after a DOWN followed by
# nothing, each `input motionevent` costs ~20ms, and the drop is taken.
#
# THE WALK'S OWN WINDOW still follows the load, for the OTHER suspect in
# the same reading — a system that compressed the moves past a small
# target: the request's ms at or under DRAG_QUIET_LOAD, proportional above
# it, capped. Deterministic given the host, free when quiet, longest
# exactly when the emulator is slowest. NO RETRY rides on the outcome:
# `ended op=0 entered=0` is also what the dnd scene's own `drag ended
# none` step asserts, and the runner cannot tell the two apart.
DRAG_QUIET_LOAD = 8.0
DRAG_DURATION_CAP_MS = 4500

# THE HELD PRESS IS A DEVICE-GLOBAL SWITCH: a pointer left down makes the
# next DOWN on that device "Invalid DOWN event - pointers already down"
# (InputDispatcher, measured the same day), and this pool stays warm
# across runs — so the release is in the teardown, in a `finally`, AND
# ahead of every press, an UP costing one logged line when nothing is
# down.
DRAG_HOLD_MS = 4000
DRAG_MOVE_MIN_MS = 150
# EIGHT, because every move is its own `adb shell input` and the guest
# pays an app_process for each: ~20ms on a quiet emulator and ~190ms
# under a matrix-shaped load (measured 2026-09-06, sixteen moves costing
# 3.8s of round trip on top of the 4.5s they were pacing). Eight is the
# walk the two-command probe was measured green with.
DRAG_MOVES_MAX = 8

# The scaling's own doctored reading, and NOTHING a lane records: a
# whole-lane run (`all`, which is the matrix's own invocation) refuses it,
# because a forced reading there would put a duration on the record that
# the host never justified. A single-suite run is a hand probe by
# definition and takes it, with the forcing printed here and again on
# every injection line.
DRAG_LOAD_FORCED = os.environ.get("KAYA_DRAG_LOAD", "")
if DRAG_LOAD_FORCED:
    try:
        _forced = float(DRAG_LOAD_FORCED)
    except ValueError:
        die(f"run-emulator: KAYA_DRAG_LOAD={DRAG_LOAD_FORCED!r} is not a "
            f"number")
    if _forced < 0:
        die(f"run-emulator: KAYA_DRAG_LOAD={DRAG_LOAD_FORCED} is negative")
    if SUITE == "all":
        die("run-emulator: KAYA_DRAG_LOAD forces the drag duration's load "
            "reading and this is a whole-lane run — its log would record "
            "durations the host never justified. Probe one suite "
            f"({', '.join(lane.SUITES)}) instead.")
    print(f"run-emulator: KAYA_DRAG_LOAD={DRAG_LOAD_FORCED} — every drag's "
          f"duration is scaled off THAT reading and not this host's. A "
          f"probe run; nothing here is a measurement of the host.",
          flush=True)


def drag_load():
    """The one-minute load average the next injection is scaled by."""
    return float(DRAG_LOAD_FORCED) if DRAG_LOAD_FORCED else os.getloadavg()[0]


def drag_duration(asked_ms, load1):
    """The ms the walk is spread over for a request that asked for
    `asked_ms` on a host reading `load1`. Pure, so the scaling can be
    watched moving and watched holding still (drag_duration_selftest)."""
    if load1 <= DRAG_QUIET_LOAD:
        return asked_ms
    return max(asked_ms, min(DRAG_DURATION_CAP_MS,
                             round(asked_ms * load1 / DRAG_QUIET_LOAD)))


def drag_duration_spelled(asked_ms, load1):
    """(the ms, the injection line's own clause) — a failed leg's reading
    names the schedule that actually ran, not the one that was asked for."""
    ms = drag_duration(asked_ms, load1)
    return ms, (f"{ms}ms (asked {asked_ms}ms, one-minute load "
                f"{load1:.2f}{' FORCED' if DRAG_LOAD_FORCED else ''})")


def drag_moves(ms):
    """(how many moves the walk takes, the wall gap between them) for a
    gesture the host's load bought `ms` for. Paced rather than burst: the
    other half of the sixth sighting's reading is a system that compressed
    the moves past a small target, and a walk fired as fast as adb can
    round-trip is 20ms a move."""
    n = max(4, min(DRAG_MOVES_MAX, int(ms // DRAG_MOVE_MIN_MS)))
    return n, ms / n / 1000.0


def drag_duration_selftest():
    """The scaling watched moving AND watched holding still, on every
    launch — the runner is the only place this rule exists, and a guard
    nobody has seen fail is worse than none (CLAUDE.md invariant 3)."""
    held = 0
    for load1 in (0.0, 1.9, DRAG_QUIET_LOAD):
        got, line = drag_duration_spelled(1500, load1)
        if got != 1500 or "1500ms (asked 1500ms" not in line:
            die(f"run-emulator: SELF-TEST FAIL — a one-minute load of "
                f"{load1} moved the drag duration to {got}ms ({line}); at "
                f"or under {DRAG_QUIET_LOAD} it is the request's own")
        held += 1
    moved = 0
    for load1, want in ((12.0, 2250), (16.0, 3000), (24.0, 4500),
                        (264.0, DRAG_DURATION_CAP_MS)):
        got, line = drag_duration_spelled(1500, load1)
        if got != want:
            die(f"run-emulator: SELF-TEST FAIL — a one-minute load of "
                f"{load1} bought {got}ms of drag, wanted {want}ms")
        if f"{want}ms (asked 1500ms, one-minute load {load1:.2f}" not in line:
            die(f"run-emulator: SELF-TEST FAIL — the injection line reads "
                f"{line!r}, which does not carry the {want}ms it ran")
        moved += 1
    if drag_duration(6000, 400.0) != 6000:
        die("run-emulator: SELF-TEST FAIL — the cap shortened a request "
            "that already asked for longer than it")
    paced = 0
    for ms in (1500, 2250, 3000, DRAG_DURATION_CAP_MS):
        n, gap = drag_moves(ms)
        if n < 4 or n > DRAG_MOVES_MAX:
            die(f"run-emulator: SELF-TEST FAIL — {ms}ms of drag walks in "
                f"{n} moves, outside 4..{DRAG_MOVES_MAX}")
        if abs(n * gap * 1000 - ms) > 1:
            die(f"run-emulator: SELF-TEST FAIL — {n} moves {gap * 1000:.0f}ms "
                f"apart spend {n * gap * 1000:.0f}ms of the {ms}ms the load "
                f"bought")
        if gap * 1000 < DRAG_MOVE_MIN_MS:
            die(f"run-emulator: SELF-TEST FAIL — {ms}ms of drag paces its "
                f"moves {gap * 1000:.0f}ms apart, under the "
                f"{DRAG_MOVE_MIN_MS}ms a move needs to not be coalesced")
        paced += 1
    print(f"run-emulator: the drag duration held at 1500ms for {held} "
          f"quiet loads and grew for {moved} loaded ones (cap "
          f"{DRAG_DURATION_CAP_MS}ms), and {paced} durations walked in "
          f"4..{DRAG_MOVES_MAX} paced moves", flush=True)


drag_duration_selftest()


# docs/traps.md 2026-09-11: the core's stderr reaches logcat through a
# bridge (crates/kaya/src/android.rs forward_stderr_to_logcat), and a bridge
# that died would be as silent as the hole it replaced — so the lane counts
# the legs whose logcat carried the core's own metrics line and refuses at
# its end when none did.
CORE_DIAG = {"legs": 0, "seen": 0}
CORE_DIAG_LINE = "KAYA_DIAG core metrics"


def adb(serial, *args, **kw):
    return run(["adb", "-s", serial, *args], **kw)


def adb_out(serial, *args):
    return out_of(["adb", "-s", serial, *args])


def _log_tail(serial):
    log = ROOT / f"target/emu-{serial.removeprefix('emulator-')}.log"
    if log.is_file():
        for line in log.read_text(encoding="utf-8",
                                  errors="replace").splitlines()[-5:]:
            print(line, file=sys.stderr)


def boot_wait(serial, proc):
    tries = 0
    while "1" not in adb_out(serial, "shell", "getprop",
                             "sys.boot_completed"):
        if proc is not None and proc.poll() is not None:
            print(f"{serial} exited before Android completed boot; "
                  f"emulator log tail:", file=sys.stderr)
            _log_tail(serial)
            return False
        tries += 1
        if tries > 120:
            print(f"{serial} did not boot; emulator log tail:",
                  file=sys.stderr)
            _log_tail(serial)
            return False
        time.sleep(1)
    return True


def avd_name(serial):
    rc, got = aestate("android_avd_name", serial)
    return got.strip() if rc == 0 else None


def connected_emulators():
    out = []
    for line in out_of(["adb", "devices"]).splitlines():
        fields = line.split()
        if (len(fields) == 2 and fields[1] == "device"
                and re.fullmatch(r"emulator-[0-9]+", fields[0])):
            out.append(fields[0])
    return out


def device_present(serial):
    return "device" in adb_out(serial, "get-state")


def wait_device_gone(serial):
    for _ in range(150):
        if not device_present(serial):
            return True
        time.sleep(0.2)
    print(f"run-emulator: {serial} did not stop within 30 seconds",
          file=sys.stderr)
    return False


def stop_avd_instance(serial, expected):
    actual = avd_name(serial)
    if actual is None:
        print(f"run-emulator: could not identify the AVD on {serial}; "
              f"refusing to stop it", file=sys.stderr)
        return False
    if actual != expected:
        print(f"run-emulator: {serial} is {actual}, not {expected}; "
              f"refusing to stop it", file=sys.stderr)
        return False
    if adb(serial, "emu", "kill", stdout=subprocess.DEVNULL,
           stderr=subprocess.DEVNULL).returncode != 0:
        return False
    return wait_device_gone(serial)


def stop_all_avd_instances(expected):
    for serial in connected_emulators():
        if avd_name(serial) == expected:
            if not stop_avd_instance(serial, expected):
                return False
    return True


def wait_emulator_exit(proc, label):
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        print(f"run-emulator: {label} did not exit within 30 seconds",
              file=sys.stderr)
        return False
    if proc.returncode != 0:
        print(f"run-emulator: {label} exited nonzero after emulator "
              f"console kill", file=sys.stderr)
        return False
    return True


# THE POOL PHONE'S PANEL (ruled 2026-09-05): 360x800dp at density 160 — the
# most common Android phone box (Galaxy class) at the cheapest density
# software rendering draws, 1.4x the pixels of avdmanager's 320x640
# default, which no shipping phone is and which put a three-column form off
# both edges before any real phone would have. NOT the Pixel's 412: that is
# inside the 400..840 band where the platforms disagree about pane count,
# and the pool-width assertion below refuses it. KAYA_ANDROID_LCD ("WxH")
# is the hand knob for an edge-case run at 320x640: the quickboot snapshot
# is tied to the panel, so a changed size reseeds it once.
LCD = os.environ.get("KAYA_ANDROID_LCD", "360x800")


def shape_pool_panel(avd):
    parts = LCD.split("x")
    if len(parts) != 2 or not all(x.isdigit() for x in parts):
        die(f"run-emulator: KAYA_ANDROID_LCD wants WxH in dp, got {LCD!r}")
    want = {"hw.lcd.width": parts[0], "hw.lcd.height": parts[1],
            "hw.lcd.density": "160"}
    avd_dir = pathlib.Path(os.environ["ANDROID_AVD_HOME"]) / f"{avd}.avd"
    ini = avd_dir / "config.ini"
    lines = ini.read_text(encoding="utf-8").splitlines()
    have = dict(ln.split("=", 1) for ln in lines if "=" in ln)
    if all(have.get(k) == v for k, v in want.items()):
        return
    if not stop_all_avd_instances(avd):
        die(f"run-emulator: could not stop {avd} to reshape its panel")
    kept = [ln for ln in lines if ln.split("=", 1)[0] not in want]
    kept += [f"{k}={v}" for k, v in want.items()]
    ini.write_text("\n".join(kept) + "\n", encoding="utf-8")
    shutil.rmtree(avd_dir / "snapshots/default_boot", ignore_errors=True)
    (avd_dir / ".kaya-default-boot-id").unlink(missing_ok=True)
    print(f"run-emulator: {avd} panel is now {parts[0]}x{parts[1]}dp at "
          f"density 160 (was {have.get('hw.lcd.width')}x"
          f"{have.get('hw.lcd.height')}); the quickboot snapshot reseeds")


def make_snapshot(avd, port):
    serial = f"emulator-{port}"
    avd_dir = pathlib.Path(os.environ["ANDROID_AVD_HOME"]) / f"{avd}.avd"
    snapshot = avd_dir / "snapshots/default_boot"
    marker = avd_dir / ".kaya-default-boot-id"
    log = ROOT / f"target/emu-{port}.log"
    if avd not in (AVD, TABLET_AVD):
        print(f"run-emulator: refusing to manage unknown AVD {avd}",
              file=sys.stderr)
        return False
    rc, _ = aestate("android_snapshot_state_current", str(marker),
                    str(snapshot), EMULATOR_EXE, SYSTEM_IMAGE_DIR)
    if rc == 0:
        return True
    print(f"== emulator state moved; reseeding quickboot snapshot for "
          f"{avd} ==")
    if not stop_all_avd_instances(avd):
        return False
    if device_present(serial):
        print(f"run-emulator: {serial} is occupied by another AVD; "
              f"refusing to replace it", file=sys.stderr)
        return False
    shutil.rmtree(snapshot, ignore_errors=True)
    marker.unlink(missing_ok=True)
    with open(log, "w", encoding="utf-8") as lf:
        builder = subprocess.Popen(
            ["emulator", "-avd", avd, "-no-snapshot-load", "-no-window",
             "-no-audio", "-no-boot-anim", "-gpu", "swiftshader_indirect",
             "-port", str(port)],
            stdout=lf, stderr=lf)
    if not boot_wait(serial, builder):
        return False
    if adb(serial, "shell", "rm", "-f", GUEST_EMULATOR_ID).returncode != 0:
        return False
    if adb(serial, "emu", "kill", stdout=subprocess.DEVNULL,
           stderr=subprocess.DEVNULL).returncode != 0:
        return False
    if not wait_emulator_exit(builder, f"{avd} snapshot builder"):
        return False
    if not (snapshot / "snapshot.pb").is_file():
        print(f"run-emulator: {avd} snapshot builder wrote no fresh "
              f"snapshot.pb", file=sys.stderr)
        return False
    bad = [ln for ln in log.read_text(encoding="utf-8",
                                      errors="replace").splitlines()
           if re.search(r"unable to lock snapshot save|Snapshots have "
                        r"been disabled|Failed to save snapshot", ln)]
    if bad:
        print(f"run-emulator: {avd} snapshot builder reported that it "
              f"could not save:", file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        return False
    rc, _ = aestate("android_write_snapshot_state", str(marker),
                    EMULATOR_EXE, SYSTEM_IMAGE_DIR)
    return rc == 0


def live_instance_current(serial, avd):
    rc, _ = aestate("android_live_instance_current", serial, avd,
                    EMULATOR_EXE, SYSTEM_IMAGE_DIR, GUEST_EMULATOR_ID)
    return rc == 0


READERS = []


def launch_reader(port, expected_avd):
    serial = f"emulator-{port}"
    if live_instance_current(serial, expected_avd):
        return True
    if device_present(serial):
        actual = avd_name(serial)
        if actual is None:
            print(f"run-emulator: could not identify {serial}; refusing "
                  f"to replace it", file=sys.stderr)
            return False
        print(f"run-emulator: {serial} is {actual} but has no current "
              f"live-instance identity; restarting it")
        if actual in (AVD, TABLET_AVD):
            if not stop_avd_instance(serial, actual):
                return False
        else:
            print(f"run-emulator: {serial} belongs to foreign AVD "
                  f"{actual}; refusing to replace it", file=sys.stderr)
            return False
    with open(ROOT / f"target/emu-{port}.log", "w",
              encoding="utf-8") as lf:
        proc = subprocess.Popen(
            ["emulator", "-avd", expected_avd, "-read-only", "-snapshot",
             "default_boot", "-force-snapshot-load", "-no-window",
             "-no-audio", "-no-boot-anim", "-gpu",
             "swiftshader_indirect", "-port", str(port)],
            stdout=lf, stderr=lf)
    READERS.append((port, expected_avd, proc))
    return True


def finish_reader(port, expected_avd, proc):
    serial = f"emulator-{port}"
    log = ROOT / f"target/emu-{port}.log"
    if not boot_wait(serial, proc):
        return False
    actual = avd_name(serial)
    if actual != expected_avd:
        print(f"run-emulator: {serial} booted {actual}, wanted "
              f"{expected_avd}", file=sys.stderr)
        return False
    rc, _ = aestate("android_snapshot_log_clean", str(log))
    if rc != 0:
        _rc2, observed = aestate("android_snapshot_log_failure", str(log))
        print(f"run-emulator: {serial} did not restore the required "
              f"quickboot snapshot:", file=sys.stderr)
        print(f"  {observed.strip() or 'emulator log missing'}",
              file=sys.stderr)
        return False
    if adb(serial, "shell", "test", "-e", GUEST_EMULATOR_ID,
           stdout=subprocess.DEVNULL,
           stderr=subprocess.DEVNULL).returncode == 0:
        print(f"run-emulator: {serial} restored a snapshot carrying a "
              f"live-instance identity", file=sys.stderr)
        print(f"  reseed {expected_avd}; a reader must identify only "
              f"its own overlay", file=sys.stderr)
        return False
    rc, _ = aestate("android_write_guest_identity", serial,
                    GUEST_EMULATOR_ID, EMULATOR_EXE, SYSTEM_IMAGE_DIR,
                    expected_avd)
    if rc != 0:
        print(f"run-emulator: {serial} did not retain its emulator "
              f"identity", file=sys.stderr)
        return False
    return True


shape_pool_panel(AVD)
if not make_snapshot(AVD, 5554):
    sys.exit(1)
if not make_snapshot(TABLET_AVD, TABLET_PORT):
    sys.exit(1)

SERIALS = []
for i in range(POOL):
    port = 5554 + 2 * i
    SERIALS.append(f"emulator-{port}")
    if not launch_reader(port, AVD):
        sys.exit(1)
# The tablet takes the port after the pool's and is NOT a pool member:
# a leg that claimed it from the pool would leave the other legs' size
# class up to a race.
if not launch_reader(TABLET_PORT, TABLET_AVD):
    sys.exit(1)

# THE LANE'S FOREIGN CLIPBOARD APP: this host has no `cmd clipboard`, so
# the outside process is an APK that seeds from the BACKGROUND and reads
# back as the DEFAULT IME, whose reads ClipboardService admits before it
# checks focus (docs/clipboard-plan.md §7 finding 1). A SEPARATE GRADLE
# BUILD from android/'s: a harness-only APK must never be one `assemble`
# away from the module graph the apps ship.
CLIPHELPER_PKG = "dev.kaya.cliphelper"
CLIPHELPER_IME = f"{CLIPHELPER_PKG}/.HelperIme"
CLIPHELPER_APK = (ROOT / "tools/android/cliphelper/app/build/outputs/"
                         "apk/debug/app-debug.apk")
if run(["gradle", "--console=plain", "-q", ":app:assembleDebug"],
       cwd=ROOT / "tools/android/cliphelper").returncode != 0:
    sys.exit(1)
if not CLIPHELPER_APK.is_file():
    print("run-emulator: the clipboard helper build produced no apk at",
          file=sys.stderr)
    print(f"  {CLIPHELPER_APK}", file=sys.stderr)
    sys.exit(1)

for _port, _avd, _proc in READERS:
    if not finish_reader(_port, _avd, _proc):
        sys.exit(1)
for _serial in SERIALS:
    if not live_instance_current(_serial, AVD):
        die(f"run-emulator: {_serial} is not a current {AVD} instance")
if not live_instance_current(TABLET_SERIAL, TABLET_AVD):
    die(f"run-emulator: {TABLET_SERIAL} is not a current {TABLET_AVD} "
        f"instance")


# THE DEVICE IS THIS LANE'S WIDTH, so it owes the rule a resize owes:
# check-steps forbids an expect_split between 400 and 840dp, the band
# where GNOME, Material and TwoPaneView legitimately disagree about pane
# count. Read the dp the apps actually see (`am get-config`'s w<N>dp —
# the device's own answer, not width/density arithmetic a skin could
# make a lie) and refuse a device inside the band.
def assert_outside_band(serial, label):
    m = re.search(r"-w([0-9]+)dp-",
                  adb_out(serial, "shell", "am", "get-config"))
    if not m:
        die(f"{label} ({serial}): could not read the display width in "
            f"dp")
    dp = int(m.group(1))
    if 400 <= dp < 840:
        die(f"{label} ({serial}) is {dp}dp wide, inside the 400..840 "
            f"band where the platforms disagree about pane count — the "
            f"listdetail leg would fail there for a reason that is not "
            f"a bug")
    print(f"{label}: {dp}dp")


assert_outside_band(SERIALS[0], "phone pool")
assert_outside_band(TABLET_SERIAL, "tablet")

status = 0
timing("boot")

if os.environ.get("KAYA_RECORD"):
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        die("recording mode needs ffmpeg/ffprobe — run inside nix "
            "develop")
    if run([str(ROOT / "tools/harness-extract.sh"),
            "--selftest"]).returncode != 0:
        sys.exit(1)

# drain() closes the suite before the next build and stage.
LEGS_DIR = pathlib.Path(tempfile.mkdtemp())

# The flight recorder (tools/lib/flightrec_lane.py holds the rules).
FR = flightrec_lane.AndroidRecorder(ROOT)

# THE POOL STAYS WARM ACROSS RUNS (nothing kills it at exit), so every
# device-global switch this run flips has to come back off — on the EXIT
# path and not at the end of the script, since a failed leg, a ^C and an
# abort all leave the same mess.
CLIPHELPER_IME_ON = []
# The held presses, {serial: (x, y)} — a drag gesture is such a switch
# now that the runner holds the press itself (DRAG_HOLD_MS above).
DRAG_POINTER_DOWN = {}
_torn = threading.Lock()


def kaya_teardown():
    if not _torn.acquire(blocking=False):
        return
    FR.flush()
    shutil.rmtree(LEGS_DIR, ignore_errors=True)
    for serial, (x, y) in list(DRAG_POINTER_DOWN.items()):
        adb(serial, "shell", "input", "motionevent", "UP", str(x), str(y),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for serial in CLIPHELPER_IME_ON:
        adb(serial, "shell", "ime", "reset", stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)


atexit.register(kaya_teardown)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))


# THE HELPER LANDS ON EVERY POOL DEVICE BEFORE ANY LEG RUNS, both halves
# VERIFIED: an absent helper times a seed's latch out naming nothing, and
# an `ime set` that did not take turns every foreign read into a null —
# which is also what an empty clipboard, a denied read and a locked
# device answer. NOT ON THE TABLET: it is the one device with no slot
# lock, so two legs there would share one clipboard (check-steps pins it).
def cliphelper_prepare(serial):
    if adb(serial, "install", "-r", str(CLIPHELPER_APK),
           stdout=subprocess.DEVNULL).returncode != 0:
        print(f"run-emulator: could not install {CLIPHELPER_PKG} on "
              f"{serial}", file=sys.stderr)
        return False
    pkgs = adb_out(serial, "shell", "pm", "list",
                   "packages").replace("\r", "")
    if f"package:{CLIPHELPER_PKG}" not in pkgs.splitlines():
        print(f"run-emulator: {CLIPHELPER_PKG} is not on {serial} after "
              f"an install that", file=sys.stderr)
        print("  reported success — every clipboard leg would seed into "
              "nothing", file=sys.stderr)
        return False
    # BOUNDED WAIT: the input method service is registered
    # asynchronously after the install, so `ime enable` on its heels
    # answers "Unknown id" and the `ime set` behind it silently keeps
    # the previous keyboard.
    for _ in range(50):
        imes = adb_out(serial, "shell", "ime", "list", "-a",
                       "-s").replace("\r", "")
        if f"{CLIPHELPER_PKG}/" in imes:
            break
        time.sleep(0.2)
    # AND IT MUST ACTUALLY BE THE SELECTED ONE: `ime set` returns before
    # the setting settles, so poll the setting ClipboardService itself
    # reads (Settings.Secure DEFAULT_INPUT_METHOD, compared by PACKAGE).
    # enable/set RE-ISSUE inside the poll, non-fatal each time: a freshly
    # restored snapshot's input method service drops a one-shot set
    # (docs/traps.md 2026-08-28).
    current = ""
    for _ in range(50):
        adb(serial, "shell", "ime", "enable", CLIPHELPER_IME,
            stdout=subprocess.DEVNULL)
        adb(serial, "shell", "ime", "set", CLIPHELPER_IME,
            stdout=subprocess.DEVNULL)
        current = adb_out(serial, "shell", "settings", "get", "secure",
                          "default_input_method").replace("\r",
                                                          "").strip()
        if current.startswith(f"{CLIPHELPER_PKG}/"):
            return True
        time.sleep(0.2)
    print(f"run-emulator: {CLIPHELPER_IME} did not become the default "
          f"IME on {serial}", file=sys.stderr)
    print(f'  (default_input_method reads "{current}") — the helper\'s '
          f"reads would", file=sys.stderr)
    print("  answer null, which is what an empty clipboard answers too",
          file=sys.stderr)
    return False


# THE SELECTION HALF, ON ITS OWN, because the default input method DOES
# NOT STAY PUT: measured 2026-08-06 on emulator-5554, it reverted to the
# stock keyboard between runs with nothing asking it to. The RANGES leg
# cannot tolerate that — a third-party input method finishes a composing
# region it did not create within tens of milliseconds — so it re-asserts
# this immediately before it runs.
def select_helper_ime(serial, out):
    current = ""
    for _ in range(50):
        adb(serial, "shell", "ime", "enable", CLIPHELPER_IME,
            stdout=subprocess.DEVNULL, stderr=out)
        adb(serial, "shell", "ime", "set", CLIPHELPER_IME,
            stdout=subprocess.DEVNULL, stderr=out)
        current = adb_out(serial, "shell", "settings", "get", "secure",
                          "default_input_method").replace("\r",
                                                          "").strip()
        if current.startswith(f"{CLIPHELPER_PKG}/"):
            return True
        time.sleep(0.2)
    print(f"run-emulator: {CLIPHELPER_IME} is not the default IME on "
          f"{serial}", file=out)
    print(f'  (default_input_method reads "{current}") — the ranges '
          f"leg's D4 step needs a", file=out)
    print("  device where nothing else is composing, and another input "
          "method will", file=out)
    print("  finish the composing region before the select arrives",
          file=out)
    return False


# THE ASSET ROOT, ON EVERY POOL DEVICE BEFORE ANY LEG RUNS
# (docs/assets-plan.md A2). Readability is MEASURED FROM THE APP:
# SELinux stops untrusted_app reading shell_data_file on many images and
# `run-as` cannot answer for it (runas_app may read what the app may
# not). BY HASH AND NOT BY SIZE. AND ONE FILE UNDER THE ROOT IS DERIVED,
# ensured here ahead of BOTH readers — the adb push and the
# assembleDebug that copies the root into the APK.
if run([sys.executable, str(ROOT / "tools/gen-market.py"),
        "--ensure"]).returncode != 0:
    print("run-emulator: python3 tools/gen-market.py --ensure failed — "
          "the market", file=sys.stderr)
    print("  family's transactions.csv is derived, so both the pushed "
          "root and", file=sys.stderr)
    print("  every APK this lane assembles would be missing it",
          file=sys.stderr)
    sys.exit(1)
ASSET_SRC = ROOT / "guests/assets"
ASSET_ON_DEVICE = "/data/local/tmp/kaya-assets"
# One string, three files: this, KayaAssets.kt's `ROOT` and
# android/build.gradle.kts's `kayaAssetPrefix` — tools/check-assets.py's
# C7 refuses if the three disagree.
APK_ASSET_PREFIX = "kaya"


def tree_asset_hashes():
    return {f.relative_to(ASSET_SRC).as_posix():
            hashlib.sha256(f.read_bytes()).hexdigest()
            for f in sorted(ASSET_SRC.rglob("*")) if f.is_file()}


def asset_hashes_agree(serial, listing_text):
    there = {}
    for line in listing_text.splitlines():
        line = line.strip()
        if not line or " " not in line:
            continue
        digest, path = line.split(None, 1)
        if len(digest) != 64:
            continue
        path = path.strip()
        if not path.startswith(ASSET_ON_DEVICE + "/"):
            continue
        there[path[len(ASSET_ON_DEVICE) + 1:]] = digest.lower()
    here = tree_asset_hashes()
    bad = []
    for name, want in sorted(here.items()):
        got = there.get(name)
        if got is None:
            bad.append(f"  {name}: never arrived")
        elif got != want:
            bad.append(f"  {name}: arrived as {got[:12]}, the tree has "
                       f"{want[:12]}")
    for name in sorted(set(there) - set(here)):
        bad.append(f"  {name}: is on the device and not in the tree — "
                   f"a stale asset a guest can still resolve by name")
    if not here:
        bad.append("  the tree's asset root is empty, so this "
                   "comparison would agree with an empty device")
    if bad:
        print(f"run-emulator: the asset root on {serial} does not match "
              f"the tree:")
        print("\n".join(bad))
        print("  a leg would then fail three removes away — a resolved "
              "family that is not Sora, or declared bytes the decoder "
              "refused")
        return False
    print(f"assets: {len(here)} files on {serial}, every one hash-equal "
          f"to the tree")
    return True


# THE DECLARED APP IDENTITY AND ITS LAUNCH SLOT, THROUGH THE ONE READER
# (tools/lib/packaging/identity.py; docs/packaging-plan.md P1). Every
# refusal is that reader's, so a half-spelled declaration reads the same
# in every packaging step. apk_icon_verify and apk_launch_verify hold
# what gradle packaged against these.
KAYA_IDENTITY_MANIFEST = ROOT / app_identity.MANIFEST
try:
    DECLARED = app_identity.load(ROOT)
except app_identity.Undeclared as _exc:
    die(f"run-emulator: {_exc}")
ICON_REL = DECLARED.icon
ICON_SRC = DECLARED.icon_path
LAUNCH_BG = DECLARED.launch_background
LAUNCH_IMAGE_REL = DECLARED.launch_image
LAUNCH_IMAGE_SRC = DECLARED.launch_image_path

# WHERE THE RENDERED LAUNCHER MIPMAPS GO (docs/packaging-plan.md P6).
# android/build.gradle.kts adds this as a res source set and REFUSES a
# build without it, naming this runner: the densities are rendered by
# python (tools/lib/packaging/android.py) and gradle only packages them.
IDENTITY_RES = ROOT / "target/android-identity/res"


def assets_prepare(serial):
    adb(serial, "shell", "rm", "-rf", ASSET_ON_DEVICE,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if adb(serial, "push", str(ASSET_SRC), ASSET_ON_DEVICE,
           stdout=subprocess.DEVNULL).returncode != 0:
        print(f"run-emulator: could not push {ASSET_SRC} to {serial}",
              file=sys.stderr)
        return False
    adb(serial, "shell", "chmod", "-R", "755", ASSET_ON_DEVICE,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    listing = out_of(["adb", "-s", serial, "shell",
                      f"find {ASSET_ON_DEVICE} -type f -exec sha256sum "
                      f"{{}} +"],
                     stderr=subprocess.STDOUT).replace("\r", "")
    return asset_hashes_agree(serial, listing)


for _serial in SERIALS:
    if not cliphelper_prepare(_serial):
        sys.exit(1)
    CLIPHELPER_IME_ON.append(_serial)
    if not assets_prepare(_serial):
        sys.exit(1)
    # BIG LOG BUFFERS, so an on-FAIL dump holds the whole leg PLUS the
    # system's side: at the stock size a busy leg's window rotates out
    # of `main` in about a minute (measured 2026-08-20). Persists until
    # the emulator reboots, hence per run rather than per boot.
    for _buf, _size in (("main", "16M"), ("system", "16M"),
                        ("events", "8M")):
        adb(_serial, "logcat", "-b", _buf, "-G", _size,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # DocumentsUI's own debug logging (gated on Log.isLoggable of these
    # tags) and the WM_DEBUG_STATES text log — the save-jvm WATCH's
    # instruments (docs/deferred.md carries the entry).
    adb(_serial, "shell", "setprop", "log.tag.Documents", "DEBUG",
        stderr=subprocess.DEVNULL)
    adb(_serial, "shell", "setprop", "log.tag.DocumentsUI", "DEBUG",
        stderr=subprocess.DEVNULL)
    adb(_serial, "shell", "cmd", "window", "logging", "enable-text",
        "WM_DEBUG_STATES", stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
timing("cliphelper")

# WHAT "BOUND" IS RECOGNISED BY: `dumpsys accessibility` prints its bound
# set as `Bound services:{Service[label=...]}` — a LABEL and no component
# — so the only match available is a name the harness service gives
# ITSELF. A service with no label inherits the application's, and moving
# that failed the bind check on all three pool devices with nothing
# naming the cause (measured 2026-08-18), so the two sides are checked
# against each other here.
A11Y_LABEL = "kaya harness"


def a11y_label_check():
    manifests = sorted(ROOT.glob("android/*/src/main/AndroidManifest.xml"))
    seen = 0
    bad = []
    for path in manifests:
        text = path.read_text(encoding="utf-8")
        for service in re.findall(r"<service\b.*?</service>", text, re.S):
            if "KayaHarnessAccessibility" not in service:
                continue
            seen += 1
            if f'android:label="{A11Y_LABEL}"' not in service:
                bad.append(
                    f"{path}: the harness accessibility service declares "
                    f'no android:label="{A11Y_LABEL}", so dumpsys prints '
                    f"whatever label it inherits — today the app's "
                    f"DECLARED name — and this runner's bind check greps "
                    f"that label. Every leg on every device would fail "
                    f"saying the picker never came up.")
    if not seen:
        bad.append("no android/*/src/main/AndroidManifest.xml declares "
                   "KayaHarnessAccessibility at all — this check read "
                   "nothing and would agree with any label")
    if bad:
        print("run-emulator: " + "\n  ".join(bad), file=sys.stderr)
        return False
    print(f'run-emulator: harness a11y label "{A11Y_LABEL}" declared '
          f"by {seen} apps")
    return True


if not a11y_label_check():
    sys.exit(1)


def a11y_disarm(serial, package, a11y, out=None):
    err = out or sys.stderr
    enabled = adb_out(serial, "shell", "settings", "get", "secure",
                      "enabled_accessibility_services").replace("\r", "")
    if a11y not in enabled:
        return True
    adb(serial, "shell", "settings", "delete", "secure",
        "enabled_accessibility_services", stdout=subprocess.DEVNULL,
        stderr=err)
    adb(serial, "shell", "settings", "put", "secure",
        "accessibility_enabled", "0", stdout=subprocess.DEVNULL,
        stderr=err)
    adb(serial, "shell", "am", "force-stop", package,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    bound, process_id = True, ""
    for _ in range(50):
        dump = adb_out(serial, "shell", "dumpsys",
                       "accessibility").replace("\r", "")
        bound = bool(re.search(rf"Bound services:.*{A11Y_LABEL}", dump))
        process_id = adb_out(serial, "shell", "pidof",
                             package).replace("\r", "").strip()
        enabled = adb_out(serial, "shell", "settings", "get", "secure",
                          "enabled_accessibility_services"
                          ).replace("\r", "")
        if not bound and not process_id and a11y not in enabled:
            return True
        time.sleep(0.2)
    print(f"run-emulator: {serial} could not disarm the prior harness "
          f"accessibility service", file=err)
    print(f"  (bound={int(bound)} process={process_id or 'none'} "
          f"enabled={enabled.strip() or 'none'})", file=err)
    return False


# Retire a service left by an interrupted run. One device read per run
# rather than one before every ordinary leg; picker legs keep the
# guarded per-leg retirement inside run_apk_on.
def a11y_hygiene(serial):
    enabled = adb_out(serial, "shell", "settings", "get", "secure",
                      "enabled_accessibility_services"
                      ).replace("\r", "").strip()
    if enabled in ("", "null"):
        return True
    for component in enabled.split(":"):
        if component.endswith("/dev.kaya.KayaHarnessAccessibility"):
            package = component.split("/", 1)[0]
            if not a11y_disarm(serial, package, component):
                return False
    return True


for _serial in [*SERIALS, TABLET_SERIAL]:
    if not a11y_hygiene(_serial):
        sys.exit(1)

# THE STAGED INSTALLS HAVE A WALL: tools/validate-all.py starts the gate
# sweep only after this lane's pid exits, so an `adb install` into a
# wedged emulator costs the whole matrix its verdict. The deadline sits
# on the JOIN and not in front of adb, so tools/lib/android-leg-order.py
# can pin the disarm/install chain. 300s against a measured per-install
# band of 0.73-0.88s median / 1.0-1.7s mean (docs/traps.md's install
# census): it cannot fire on a device that is merely slow.
_deadline_raw = os.environ.get("KAYA_STAGE_DEADLINE", "300")
if not _deadline_raw.isdigit() or int(_deadline_raw) < 1:
    die("run-emulator: KAYA_STAGE_DEADLINE must be a positive integer")
STAGE_DEADLINE = int(_deadline_raw)


def stage_suite_apk(label, apk, package, targets):
    """Install the suite's one APK on every target, per-target verdicts
    printed and counted — a silent install miss surfaces a whole suite
    later as `am start` "Activity class does not exist", which reads as
    a manifest or gradle defect and not as a lost install."""
    if label not in lane.SUITES:
        print(f"run-emulator: refusing to stage unknown suite {label}",
              file=sys.stderr)
        return False
    expected = POOL + 1 if label == "compose" else POOL
    if len(targets) != expected:
        print(f"run-emulator: {label} staging received {len(targets)} "
              f"targets, wanted {expected}", file=sys.stderr)
        return False
    if len(set(targets)) != len(targets):
        print(f"run-emulator: {label} staging names a target twice",
              file=sys.stderr)
        return False
    stage_dir = LEGS_DIR / f"stage-{label}"
    try:
        stage_dir.mkdir()
    except OSError:
        print(f"run-emulator: could not create the {label} staging "
              f"verdict directory", file=sys.stderr)
        return False

    def stage_one(serial):
        with open(stage_dir / f"{serial}.log", "w", encoding="utf-8",
                  errors="replace") as slog:
            target_verdict = "FAIL"
            a11y = f"{package}/dev.kaya.KayaHarnessAccessibility"
            # The disarm sits immediately before the install: package
            # replacement can resurrect a stale service after
            # force-stop (docs/traps.md).
            if a11y_disarm(serial, package, a11y, out=slog) and adb(
                    serial, "install", "-r", str(apk),
                    stdout=subprocess.DEVNULL,
                    stderr=slog).returncode == 0:
                # AN INSTALL THAT REPORTED SUCCESS IS RE-READ, the same
                # postcondition cliphelper_prepare keeps.
                pkgs = adb_out(serial, "shell", "pm", "list",
                               "packages").replace("\r", "")
                if f"package:{package}" in pkgs.splitlines():
                    # THE NOTIFICATION PERMISSION, PRE-GRANTED (docs/
                    # tasks-s3-plan.md N5): on API 33+ the first post
                    # asks, and a modal prompt in front of the scene is
                    # a leg nobody can drive. Granted per install rather
                    # than per leg — it survives every force-stop, and a
                    # package that has just been replaced starts denied.
                    grant = out_of(
                        ["adb", "-s", serial, "shell", "pm", "grant",
                         package, "android.permission.POST_NOTIFICATIONS"],
                        stderr=subprocess.STDOUT)
                    if grant.strip():
                        print(f"run-emulator: pm grant POST_NOTIFICATIONS "
                              f"on {package} said {grant.strip()!r} — the "
                              f"notify legs would meet the runtime prompt",
                              file=slog)
                    target_verdict = "OK"
                else:
                    print(f"run-emulator: {package} is not on {serial} "
                          f"after an install that", file=slog)
                    print(f"  reported success — every {label} leg on "
                          f"this device would start nothing", file=slog)
            (stage_dir / f"{serial}.verdict").write_text(
                target_verdict + "\n", encoding="utf-8")

    threads = []
    for serial in targets:
        t = threading.Thread(target=stage_one, args=(serial,),
                             daemon=True)
        t.start()
        threads.append(t)
    launched = len(threads)
    deadline_at = time.monotonic() + STAGE_DEADLINE
    for serial, t in zip(targets, threads):
        t.join(timeout=max(0.0, deadline_at - time.monotonic()))
        if t.is_alive():
            print(f"run-emulator: {label} APK staging on {serial} "
                  f"passed {STAGE_DEADLINE}s without", file=sys.stderr)
            print(f"  reaching a verdict — the staging phase, before "
                  f"any {label} leg ran.", file=sys.stderr)
            if not (stage_dir / f"{serial}.verdict").is_file():
                (stage_dir / f"{serial}.verdict").write_text(
                    "TIMEOUT\n", encoding="utf-8")
    observed = passed = 0
    for serial in targets:
        print(f"== stage-{label}-{serial} ==")
        slog = stage_dir / f"{serial}.log"
        if slog.is_file():
            print(slog.read_text(encoding="utf-8", errors="replace"),
                  end="")
        vfile = stage_dir / f"{serial}.verdict"
        if vfile.is_file():
            observed += 1
            verdict = vfile.read_text(encoding="utf-8").strip()
        else:
            verdict = "MISSING"
        if verdict == "OK":
            passed += 1
        print(f"stage-{label}-{serial}: {verdict}")
    if launched != expected or observed != expected:
        print(f"run-emulator: {label} staging under-ran (wanted "
              f"{expected}, launched {launched}, reported {observed})",
              file=sys.stderr)
        return False
    if passed != expected:
        print(f"run-emulator: {label} staging failed on "
              f"{expected - passed} of {expected} targets",
              file=sys.stderr)
        return False
    print(f"stage-{label}: OK ({passed}/{expected} targets)")
    return True


def run_apk_on(serial, name, apk, component, script, extras,
               remount_expect, two_act, log, rebooted=False):
    """One leg on one device, everything it prints going to its own
    log. The per-leg setup ORDER is load-bearing and
    tools/lib/android-leg-order.py polices it: guarded disarm of a
    prior service, force-stop the app, force-stop the picker packages
    (DocumentsUI survives the app's force-stop, and left standing it
    sits on top of the app's task — the next `am start` brings that
    task forward, onCreate never runs, and the leg reads as a clean run
    of nothing), logcat -c, the a11y arm with its READY handshake, then
    am start — never `-S`, which would kill the service the bind check
    just confirmed."""
    failed = False
    package = component.split("/", 1)[0]
    a11y = f"{package}/dev.kaya.KayaHarnessAccessibility"
    needs_a11y = script in lane.A11Y_SCENES
    # Startup hygiene handles an interrupted prior run; only a picker
    # scene can have armed this run's service.
    if needs_a11y and not a11y_disarm(serial, package, a11y, out=log):
        return False
    adb(serial, "shell", "am", "force-stop", package, stdout=log,
        stderr=log)
    for picker in ("com.google.android.documentsui",
                   "com.android.documentsui"):
        adb(serial, "shell", "am", "force-stop", picker,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    adb(serial, "logcat", "-c", stdout=log, stderr=log)
    # THE HARNESS'S EYES OUTSIDE THIS APP: the picker is a separate APK
    # and the platform stops one app reading another's UI, so picker
    # scenes need an accessibility service only adb can enable. Armed
    # AFTER force-stop and logcat -c, which kill the service and wipe the
    # connection message that proves it came up (docs/traps.md, "Package
    # replacement can resurrect a service after force-stop"). DELETED
    # BEFORE EACH SET: writing the value already there notifies nobody.
    if needs_a11y:
        ready = False
        bound = False
        for arm in range(1, 4):
            bound = False
            adb(serial, "logcat", "-c", stdout=log, stderr=log)
            adb(serial, "shell", "settings", "delete", "secure",
                "enabled_accessibility_services",
                stdout=subprocess.DEVNULL, stderr=log)
            adb(serial, "shell", "settings", "put", "secure",
                "enabled_accessibility_services", a11y,
                stdout=subprocess.DEVNULL, stderr=log)
            adb(serial, "shell", "settings", "put", "secure",
                "accessibility_enabled", "1", stdout=subprocess.DEVNULL,
                stderr=log)
            for _ in range(50):
                dump = adb_out(serial, "shell", "dumpsys",
                               "accessibility").replace("\r", "")
                if re.search(rf"Bound services:.*{A11Y_LABEL}", dump):
                    bound = True
                tail = adb_out(serial, "logcat", "-d", "-s",
                               "kaya:*").replace("\r", "")
                if bound and "KAYA_A11Y_WINDOWS: READY" in tail:
                    ready = True
                    break
                if "KAYA_A11Y_WINDOWS: BLIND" in tail:
                    break
                time.sleep(0.2)
            if ready:
                break
            if arm < 3:
                print(f"run-emulator: {serial} bound={int(bound)} but "
                      f"had no readable window on arm {arm} — re-arming",
                      file=log)
        if not ready and not rebooted:
            print(f"run-emulator: {serial} did not bind with a readable "
                  f"window after 3 arms — rebooting it once", file=log)
            adb(serial, "reboot", stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL)
            adb(serial, "wait-for-device", stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL)
            for _ in range(90):
                if adb_out(serial, "shell", "getprop",
                           "sys.boot_completed").strip() == "1":
                    break
                time.sleep(1)
            time.sleep(5)
            return run_apk_on(serial, name, apk, component, script,
                              extras, remount_expect, two_act, log,
                              rebooted=True)
        if not ready:
            print(f"run-emulator: the harness accessibility service "
                  f"never bound with a readable window on {serial}",
                  file=log)
            print("  (three arms and a reboot; "
                  "enabled_accessibility_services was set to", file=log)
            print(f"   {a11y}, bound={int(bound)} — the scene would run "
                  f"with blind eyes and report", file=log)
            print("   a picker that never came up)", file=log)
            return False
    # A SECOND ACT STARTS FROM AN EMPTY STATE HOME: the marker act one
    # writes is consumed on read, but a run killed between the two acts
    # leaves both files behind and a stale verdict would answer for this
    # run (docs/tasks-s9-plan.md R6).
    if two_act:
        run_as(serial, package, "rm", "-rf", ACT2_REL)
    rec_proc = None
    rec_extra = []
    if os.environ.get("KAYA_RECORD"):
        adb(serial, "shell", "rm", "-f", "/data/local/tmp/kaya-rec.mp4",
            stdout=log, stderr=log)
        rec_proc = subprocess.Popen(
            ["adb", "-s", serial, "shell", "screenrecord",
             "/data/local/tmp/kaya-rec.mp4"],
            stdout=log, stderr=log)
        rec_extra = ["--es", "KAYA_RECORD", "1"]
    adb(serial, "shell", "am", "start", "-W", "-n", component, "--es",
        "KAYA_SELFTEST", script, *rec_extra, *extras,
        stdout=subprocess.DEVNULL, stderr=log)
    # POLLED DUMPS, NEVER ONE STREAM: a streaming watch wedged for its
    # whole 60s with the verdict already sitting in the buffer it was
    # reading (docs/traps.md 2026-08-28). NO PER-LEG SCREENSHOT: 48 of
    # 52 outputs were the launcher's WALLPAPER (measured 2026-07-27) —
    # `am start -W` already blocks until the first frame and the scene
    # exits ~300ms after its verdict.
    out = ""
    # THE `drag` VERB'S ONE HAND (docs/dnd-plan.md D10). The harness runs
    # INSIDE the app and no app may inject a system drag, so it prints
    # both widgets' centres in screen pixels and this poll — which is
    # already re-reading the whole buffer every half second — runs the
    # real gesture on the leg's OWN device.
    #
    # REQUEST, INJECT, and re-inject ONLY while the gesture was lost: a
    # touch injected into the first ~400ms of a leg never starts (the
    # launch transition and the splash window are still coming down,
    # measured 2026-09-03). Re-injection exists for that alone — once the
    # app logs KAYA_DRAG_STARTED (the source's transferData ran, so the
    # gesture took) the seq is IN FLIGHT and a fresh drag would clobber
    # a slow-ending one under load, which is exactly what reddened one
    # reorder under the matrix (docs/traps.md). The app acks the drag that
    # ENDED, refused or taken; drags are serial, so the start count at a
    # seq's first injection dates every later start to that seq.
    served = {}
    # The shade taps this leg has served, keyed by the app's own sequence
    # number — the drag's bookkeeping, one verb over.
    tapped = {}
    # 240 ROUNDS, roughly 0.7s each: the budget has to outlast a leg that
    # is FAILING, and a failing step costs this backend up to 15s now
    # (KayaCompose.kt's stepDeadline, the core's own POLL_DEADLINE). At
    # 120 a red leg with five failed steps could run past the poll and be
    # written down as "no verdict" — a legible failure turned into an
    # illegible one. A green leg breaks on its verdict and pays nothing.
    # A TWO-ACT SCENE PUBLISHES ACT ONE'S VERDICT UNDER ITS OWN WORDS
    # (docs/tasks-s9-plan.md R6), so this poll waits for that one and the
    # ordinary verdict below is act TWO's, out of the file.
    verdict_pat = (r"^.*KAYA_SELFTEST: ACT 1 (?:OK|FAILED).*$" if two_act
                   else r"^.*KAYA_SELFTEST: (?:OK|FAILED).*$")
    for _ in range(240):
        dump = kaya_logcat(serial)
        m = re.search(verdict_pat, dump, re.M)
        if m:
            out = m.group(0)
            break
        acked = set(re.findall(r"KAYA_ACK: draganddrop (\d+)", dump))
        starts = kaya_starts(dump)
        # THE SHADE TAP the `notification_activate` verb asks for. Re-tried
        # only while the app has not acked: the tap lands on SystemUI, and
        # a second one after the app answered would open the shade over the
        # next step.
        tap_acked = set(re.findall(r"KAYA_ACK: notify_tap (\d+)", dump))
        for seq, title in re.findall(r"KAYA_REQUEST: notify_tap (\d+) (.*)",
                                     dump):
            title = title.rstrip("\r")
            tries, last = tapped.get(seq, (0, 0.0))
            if seq in tap_acked or tries >= NOTIFY_TAP_TRIES:
                continue
            if tries and time.monotonic() - last < NOTIFY_TAP_RETRY_S:
                continue
            began = time.monotonic()
            told = tap_notification(serial, title, log)
            tapped[seq] = (tries + 1, time.monotonic())
            print(f"{name}: notify_tap #{seq} try {tries + 1} -> {told} in "
                  f"{int((time.monotonic() - began) * 1000)}ms", file=log)
        for seq, *point in re.findall(
                r"KAYA_REQUEST: draganddrop (\d+) (-?\d+) (-?\d+) (-?\d+) "
                r"(-?\d+) (\d+)", dump):
            tries, last, starts_at = served.get(seq, (0, 0.0, starts))
            if seq in acked or tries >= DRAG_INJECT_TRIES:
                continue
            # In flight: a start postdates this seq's first injection.
            if tries and starts > starts_at:
                continue
            if tries and time.monotonic() - last < DRAG_INJECT_RETRY_S:
                continue
            *aim, asked = point
            ms, spelled = drag_duration_spelled(int(asked), drag_load())
            began = time.monotonic()
            told = inject_drag(serial, aim, ms, starts, log)
            served[seq] = (tries + 1, time.monotonic(),
                           starts_at if tries else starts)
            print(f"{name}: draganddrop #{seq} try {tries + 1} "
                  f"{' '.join(aim)} {spelled} -> {told} in "
                  f"{int((time.monotonic() - began) * 1000)}ms", file=log)
        time.sleep(0.5)
    if out:
        CORE_DIAG["legs"] += 1
        if CORE_DIAG_LINE in dump:
            CORE_DIAG["seen"] += 1
    print(out, file=log)
    if two_act:
        act_one = out
        out = (act_two(serial, name, package, component, dump, log)
               if "KAYA_SELFTEST: ACT 1 OK" in act_one else "")
        # ONE LEG, TWO VERDICTS: the leg is PASS only when act one left
        # cleanly and the process the platform started answered. Act one
        # is named by its VERDICT alone — its whole observation list is
        # already printed above, and a scene as long as the task
        # manager's puts a thousand characters in front of the answer
        # this line exists to give.
        said = re.search(r"KAYA_SELFTEST: (ACT 1 (?:OK|FAILED))", act_one)
        print(f"{name}: two acts — "
              f"{said.group(1) if said else '(no ACT 1 verdict)'} + "
              f"{out or '(no ACT 2 verdict)'}", file=log)
    if "KAYA_SELFTEST: OK" not in out and out and served:
        # The drag WATCH's instrument, beside the injections: every drag
        # event the app saw, so "drag ended none" under a matrix says which
        # target the pointer entered and where the drop landed.
        for line in re.findall(r"^.*KAYA_DRAG_EVENT: .*$", dump, re.M):
            print(f"{name}: {line.split('KAYA_DRAG_EVENT: ', 1)[1]}", file=log)
    if "KAYA_SELFTEST: OK" not in out and out:
        # THE THREE-LINK TRACE (docs/deferred.md's android
        # `portfolio-python` WATCH): the app dumps its ring just before
        # the verdict, so the verb's own dispatch, the widget's handler
        # and the batch that answered are all in THIS dump — printed
        # here rather than left to the 60-line tail below, which a long
        # scene's trace outruns.
        for line in re.findall(r"^.*\bKAYA_DIAG:? .*$", dump, re.M):
            print(f"{name}: {line.split('KAYA_DIAG', 1)[1].lstrip(': ')}",
                  file=log)
    # THE RECREATION LEG'S OWN PROOF (docs/deferred.md's mount entry):
    # a green verdict does not say the relaunch happened. Both sentences
    # come out of the SAME process's harness thread, so the pair is the
    # whole claim: two onCreates, one process, the remaining expects
    # green after the second. AND THE PRESENTATION RE-REPORTED: the core
    # LATCHES the last scale and appearance, so a composition that never
    # reports again moves nothing observable.
    if remount_expect:
        remount_log = adb_out(serial, "logcat", "-d", "-s",
                              "kaya:*").replace("\r", "")
        if remount_expect not in remount_log:
            print(f"{name}: the recreation never fired — the log "
                  f"carries no", file=log)
            print(f'  "{remount_expect}"', file=log)
            print("  (KAYA_RECREATE_AFTER counts non-comment "
                  "statements; a scene edit moves it)", file=log)
            failed = True
        if "KAYA_REMOUNT: re-attached" not in remount_log:
            print(f"{name}: the re-created activity never re-attached "
                  f"in this process", file=log)
            failed = True
        reports = remount_log.count("KAYA_PRESENTATION:")
        if reports < 2:
            print(f"{name}: the presentation was reported {reports} "
                  f"time(s) across two", file=log)
            print("  compositions — a re-attached surface must report "
                  "its own scale and", file=log)
            print("  appearance (KayaRoot's LaunchedEffect)", file=log)
            failed = True
    if os.environ.get("KAYA_RECORD"):
        rec_dir = ROOT / f"target/recordings/android/{name}"
        rec_dir.mkdir(parents=True, exist_ok=True)
        t_kill = int(time.time() * 1000)
        adb(serial, "shell", "kill -2 $(pidof screenrecord)",
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if rec_proc is not None:
            rec_proc.wait()
        time.sleep(1)
        adb(serial, "pull", "/data/local/tmp/kaya-rec.mp4",
            str(rec_dir / "video.mp4"), stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        with open(rec_dir / "leg.log", "w", encoding="utf-8",
                  errors="replace") as lf:
            run(["adb", "-s", serial, "logcat", "-d", "-s", "kaya:*"],
                stdout=lf, stderr=subprocess.DEVNULL, **TEXT)
        dur = out_of(["ffprobe", "-v", "exclusive", "-show_entries",
                      "format=duration", "-of", "csv=p=0",
                      str(rec_dir / "video.mp4")]).strip()
        try:
            dur_ms = int(float(dur or "0") * 1000)
        except ValueError:
            dur_ms = 0
        if not dur_ms:
            print(f"{name}: recording produced no readable video",
                  file=log)
            failed = True
        elif run([str(ROOT / "tools/harness-extract.sh"),
                  str(rec_dir / "video.mp4"), str(rec_dir / "leg.log"),
                  str(t_kill - dur_ms), str(rec_dir / "steps")],
                 stdout=log, stderr=log).returncode != 0:
            failed = True
    if "KAYA_SELFTEST: OK" not in out:
        # The DEVICE, first: nothing else in this log says which
        # emulator ran the leg, and the dump below is only chaseable
        # there.
        print(f"leg device: {serial}", file=log)
        # THREE TAGS, NOT ONE: AndroidRuntime carries JVM exceptions
        # only, a Go panic goes under `Go` (measured 2026-08-07), and
        # DEBUG:F is the tombstone header. THE SENTENCE THAT NAMES THE
        # CAUSE COMES FIRST, AND WHOLE — a tombstone puts its `Abort
        # message:` ABOVE its frames, so a bare tail of a forty-frame
        # stack drops exactly the line a reader needs (2026-08-19).
        crash = out_of(["adb", "-s", serial, "logcat", "-d", "-b",
                        "crash,main", "-s", "AndroidRuntime:E", "Go:E",
                        "kaya:E", "DEBUG:F"])
        heads = [ln for ln in crash.splitlines()
                 if re.search(r"panicked at|Abort message|FATAL "
                              r"EXCEPTION", ln)]
        print("\n".join(heads[:5]), file=log)
        stack = out_of(["adb", "-s", serial, "logcat", "-d", "-s",
                        "AndroidRuntime:E", "Go:E", "DEBUG:F"])
        print("\n".join(stack.splitlines()[-30:]), file=log)
        # AND THE HARNESS TRACE: a failure with no crash keeps only
        # crash-shaped lines otherwise, which is NOTHING — four
        # save-dialog sightings were investigated off a one-line verdict
        # because the step timings died with the buffer (2026-08-20).
        trace = out_of(["adb", "-s", serial, "logcat", "-d", "-s",
                        "kaya:*"])
        print("\n".join(trace.splitlines()[-60:]), file=log)
        # AND THE SYSTEM'S SIDE OF A LOST DIALOG RESULT, read AT FAIL
        # TIME because the main buffer rotates in about a minute on a
        # busy leg. The events buffer still held the am_ timeline, which
        # is why it rides along.
        sys_side = out_of(["adb", "-s", serial, "logcat", "-d", "-b",
                           "events,main"])
        wanted = [ln for ln in sys_side.splitlines()
                  if re.search(r"documentsui|has died|am_kill|am_freeze"
                               r"|am_proc_died|ANR in|force.?stop", ln,
                               re.I)]
        print("\n".join(wanted[-60:]), file=log)
        # AND THE WHOLE BUFFER TO A FILE, because the NEXT leg on this
        # device starts with `logcat -c` — this dump is the only
        # complete record the sighting will ever have.
        keep = ROOT / "target/validate-failures"
        keep.mkdir(parents=True, exist_ok=True)
        with open(keep / f"android-{name}-buffers.log", "w",
                  encoding="utf-8", errors="replace") as bf:
            run(["adb", "-s", serial, "logcat", "-d", "-b", "all"],
                stdout=bf, stderr=subprocess.DEVNULL, **TEXT)
        with open(keep / f"android-{name}-activities.txt", "w",
                  encoding="utf-8", errors="replace") as af:
            run(["adb", "-s", serial, "shell", "dumpsys", "activity",
                 "activities"], stdout=af, stderr=subprocess.DEVNULL,
                **TEXT)
        print(f"full buffers kept at target/validate-failures/"
              f"android-{name}-buffers.log", file=log)
        # THE VERB TRACE, out of the app's private files dir through
        # run-as (the debug APKs are debuggable).
        pulled = subprocess.run(
            ["adb", "-s", serial, "exec-out", "run-as", package, "cat",
             f"files/verb-trace-{name}.txt"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if pulled.returncode == 0 and pulled.stdout:
            dest = (LEGS_DIR / f"{name}.log").with_suffix(".vtrace")
            dest.write_bytes(pulled.stdout)
            print(f"verb trace kept beside the log ({len(pulled.stdout)} "
                  f"bytes)", file=log)
        failed = True
    if needs_a11y and not a11y_disarm(serial, package, a11y, out=log):
        failed = True
    return not failed


# ------------------------------------------------------------ the pool
_dev_slots = list(range(POOL))
_slots_lock = threading.Condition()
_tablet_lock = threading.Lock()
_leg_names = []
_leg_threads = []
_tablet_threads = []


def _claim_device():
    with _slots_lock:
        while not _dev_slots:
            _slots_lock.wait()
        return _dev_slots.pop(0)


def _release_device(slot):
    with _slots_lock:
        _dev_slots.append(slot)
        _slots_lock.notify()


def _leg_worker(name, script, args, tablet):
    with open(LEGS_DIR / f"{name}.log", "w", encoding="utf-8",
              errors="replace", buffering=1) as log:
        if tablet:
            _tablet_lock.acquire()
            serial, slot = TABLET_SERIAL, None
        else:
            slot = _claim_device()
            serial = SERIALS[slot]
        t0 = time.monotonic()
        try:
            ready = True
            # The ranges leg's slot-local IME re-assert: on the device
            # it just claimed, before the launch, failing through the
            # normal leg verdict path (select_helper_ime carries the
            # reason).
            if (script in lane.IME_SCENES
                    and not select_helper_ime(serial, log)):
                ready = False
            ok = ready and run_apk_on(serial, name, *args, log=log)
        finally:
            if tablet:
                _tablet_lock.release()
            else:
                _release_device(slot)
        secs = int(time.monotonic() - t0)
        (LEGS_DIR / f"{name}.secs").write_text(f"{secs}\n",
                                               encoding="utf-8")
        (LEGS_DIR / f"{name}.verdict").write_text(
            f"{'PASS' if ok else 'FAIL'}\n", encoding="utf-8")


def queue_leg(name, script, args, tablet=False):
    # THE MATRIX-WIDE TOKEN (tools/lib/exclusive.py): start nothing while
    # another lane holds it; for this lane's exclusive legs, empty the pool
    # first, then hold it and run the leg inline.
    exclusive.wait("android", name)
    mode = os.environ.get("KAYA_EXCLUSIVE", "")
    if (mode == "only") != (name in lane.EXCLUSIVE) and mode in ("only", "skip"):
        return
    _leg_names.append(name)
    if name in lane.EXCLUSIVE:
        for t in [*_leg_threads, *_tablet_threads]:
            t.join()
        with exclusive.hold("android", name):
            _leg_worker(name, script, args, tablet)
        return
    t = threading.Thread(target=_leg_worker,
                         args=(name, script, args, tablet))
    t.start()
    if tablet:
        # The tablet's legs are tracked apart from the pool's: riding
        # the pool count they would throttle a pool they do not use and
        # eventually trip its wedge watchdog.
        _tablet_threads.append(t)
        return
    _leg_threads.append(t)
    # A wedged pool must die loudly in minutes, not silently absorb
    # tens of legs.
    spins = 0
    while sum(t.is_alive() for t in _leg_threads) >= len(SERIALS):
        spins += 1
        if spins > 900:
            die(f"pool wedged: "
                f"{sum(t.is_alive() for t in _leg_threads)} legs "
                f"running, none finishing; queued={len(_leg_names)}")
        time.sleep(0.2)


def drain():
    global status
    for t in [*_leg_threads, *_tablet_threads]:
        t.join()
    _leg_threads.clear()
    _tablet_threads.clear()
    for name in _leg_names:
        vfile = LEGS_DIR / f"{name}.verdict"
        verdict = (vfile.read_text(encoding="utf-8").strip()
                   if vfile.is_file() else "FAIL")
        print(f"== {name} ==")
        lfile = LEGS_DIR / f"{name}.log"
        if lfile.is_file():
            print(lfile.read_text(encoding="utf-8", errors="replace"),
                  end="", flush=True)
        if verdict != "PASS":
            status = 1
        sfile = LEGS_DIR / f"{name}.secs"
        secs = (sfile.read_text(encoding="utf-8").strip()
                if sfile.is_file() else "?")
        # THE JOURNAL TAKES EVERY LEG, pass or fail; the bundle carries
        # the device roster too, because only the roster tells an
        # offline emulator from a failed assertion.
        FR.android_leg(name, verdict, secs, LEGS_DIR / f"{name}.log")
        print(f"{name}: {verdict} ({secs}s)", flush=True)
    _leg_names.clear()


# ------------------------------------------------- the scene scripts
def scene_script(scene):
    """Comments stripped, every line folded into `;` — the grammar's
    newline stand-in, because intent extras cannot carry newlines
    through the shell."""
    lines = [line for line in
             (ROOT / f"tools/scenes/{scene}.steps").read_text(
                 encoding="utf-8").splitlines()
             if not line.startswith("#")]
    return ";".join(lines) + ";"


def scene_script_cut(scene, cut, keep, extra=""):
    """The phone-expressible prefix, decided in tools/lib/scene_cut.py —
    one census for run-sim, this runner and check-steps."""
    path = ROOT / f"tools/scenes/{scene}.steps"
    try:
        prefix, dropped = scene_cut.scene_prefix(path, cut, keep, extra,
                                                 who="run-emulator")
    except scene_cut.CutRefused as exc:
        die(str(exc))
    for line in dropped:
        if line.strip():
            print(f"run-emulator: NOT RUN on this host (after `{cut}`): "
                  f"{line.strip()}", file=sys.stderr)
    return ";".join(line.strip() for line in prefix if line.strip()) + ";"



def drop_block(lines, specs, keep):
    """The DROP's decision, over normalized lines and nothing else —
    (kept, dropped), or a ValueError carrying the sentence. Pure so its
    refusals can be watched firing at import (drop_block_selftest)."""
    keeps = keep.split()
    if not keeps:
        raise ValueError(
            f"dropping {list(specs)} with no `keep` verb — say which "
            f"assertions this drop may not take with it, or the leg can "
            f"be trimmed until it asserts nothing")
    at = []
    for spec in specs:
        words = spec.split()
        hits = [i for i, line in enumerate(lines)
                if line.split()[:len(words)] == words]
        if len(hits) != 1:
            raise ValueError(
                f"the scene has {len(hits)} `{spec}` steps and this lane "
                f"drops exactly one — it was reshaped and nobody re-read "
                f"what the phone can express. Fix the leg, do not widen "
                f"the drop.")
        at.append(hits[0])
    at.sort()
    if at != list(range(at[0], at[0] + len(at))):
        raise ValueError(
            f"the dropped steps {[lines[i] for i in at]} are not one "
            f"block — a drop takes a step and the assertions it feeds, "
            f"never a step from the top and an assertion from the bottom")
    gone = set(at)
    kept = [line for i, line in enumerate(lines) if i not in gone]

    def asserted(seq, verb, target=None):
        return {line for line in seq
                if (p := line.split()) and p[0] == verb
                and (target is None or (len(p) > 1 and p[1] == target))}

    for tok in keeps:
        verb, _, target = tok.partition("=")
        whole = asserted(lines, verb, target or None)
        survived = asserted(kept, verb, target or None)
        if not survived:
            raise ValueError(
                f"dropping {[lines[i] for i in at]} leaves no `{tok}` "
                f"step at all — the leg would pass without asserting the "
                f"thing it exists for")
        if survived != whole:
            raise ValueError(
                f"dropping {[lines[i] for i in at]} takes "
                f"{sorted(whole - survived)} — the drop may not take an "
                f"assertion of `{tok}` with it")
    return kept, [lines[i] for i in at]


def drop_blocks(lines, blocks):
    """Every block of a lane's `drop`, in the table's order and each
    refused on its own terms — the blocks of one scene need not be
    contiguous with each other (taskspersist's two sit on opposite sides
    of the `relaunch`). Pure, so the sequencing's own refusal can be
    watched firing at import."""
    taken = []
    for specs, keep, why in blocks:
        lines, gone = drop_block(lines, specs, keep)
        taken.append((why, gone))
    return lines, taken


def drop_block_selftest():
    """The refusals above, watched firing on every launch — the runner
    is the only wall a lane's cut has, and a guard nobody has seen fail
    is worse than none (CLAUDE.md invariant 3)."""
    sample = ['drag label#0 to label#1',
              'expect label#4 "text target got text hello (copy)"',
              'drag_file "$TMP/f.txt" to label#3',
              'expect label#4 "files target got f.txt (copy)"',
              'expect_order column@rows "a|b|c"']
    good = ('drag_file', 'expect label#4 "files target got f.txt (copy)"')
    reds = 0
    for specs, keep, why in (
            (good, "", "no keep verb"),
            (("expect",), "expect_order", "a spec matching four steps"),
            (("scroll_end",), "expect_order", "a spec matching nothing"),
            (("drag_file", 'expect_order column@rows "a|b|c"'),
             "expect_order", "two hits that are not one block"),
            ((good[0], good[1], 'expect_order column@rows "a|b|c"'),
             "expect_order", "a drop taking a keep's own assertion")):
        try:
            drop_block(list(sample), specs, keep)
        except ValueError:
            reds += 1
            continue
        die(f"run-emulator: SELF-TEST FAIL — drop_block accepted {why}")
    kept, gone = drop_block(list(sample), good, "expect_order")
    if len(kept) != 3 or len(gone) != 2:
        die("run-emulator: SELF-TEST FAIL — drop_block refused the real "
            f"shape ({len(kept)} kept, {len(gone)} dropped)")
    # THE SEQUENCE: a second block is read against what the first LEFT, so
    # one that names a step already taken must be refused rather than
    # quietly dropping nothing.
    two = [(good, "expect_order", "the foreign source"),
           (("drag label#0",), "expect_order", "the local drag")]
    kept, taken = drop_blocks(list(sample), two)
    if len(kept) != 2 or len(taken) != 2:
        die(f"run-emulator: SELF-TEST FAIL — drop_blocks refused two real "
            f"blocks ({len(kept)} kept, {len(taken)} block(s) taken)")
    try:
        drop_blocks(list(sample), [two[0], two[0]])
    except ValueError:
        reds += 1
    else:
        die("run-emulator: SELF-TEST FAIL — drop_blocks accepted a second "
            "block naming the step the first had already taken")
    print(f"run-emulator: drop_block refused {reds} bad drops", flush=True)


drop_block_selftest()


def scene_script_drop(scene, blocks):
    """A BLOCK OUT OF THE MIDDLE, where a CUT can only take a tail: the
    identity scene's `expect_title window#1` reads the declared NAME off
    a window this host has not got, and below it sit the live widgets
    and the SECOND expect_app_icon; the dnd scene's `drag_file` is a
    FOREIGN source no phone app can be handed (docs/dnd-plan.md D9), and
    the one assertion it feeds goes with it — an expect over a step that
    did not run is a lie. EACH SPEC IS A LEADING RUN OF WORDS, AS SHORT
    AS IT CAN BE while naming exactly one step — `drag_file` is the
    whole spec, and identity's stops at `expect_title window#1` rather
    than retyping the declared name after it, which is the second source
    of truth guests/assets/identity.toml exists to prevent. Only a
    discriminator no shorter spec has may be a quoted value: six steps
    share `expect label#4`. THE iOS LANE TAKES THE SAME LIST AND THE
    SAME GRAMMAR — two mobile lanes, one question, and two answers is
    how lanes drift — and tools/ios/run-sim.py's own drop still names
    ONE step by (verb, target): it takes this shape when it next needs a
    block, which is the same `drag_file` cut (docs/dnd-plan.md D9).

    SEVERAL BLOCKS, in the table's order, each refused on its own terms:
    taskspersist's two desktop-only steps sit on opposite sides of the
    `relaunch` (the resize in act one, the frame assertion in act two), so
    no one contiguous block names them and a CUT would take the whole
    second act with it (docs/tasks-s4-plan.md §4, the phone cut)."""
    path = ROOT / f"tools/scenes/{scene}.steps"
    lines = [" ".join(line.split()) for line in
             path.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    try:
        lines, taken = drop_blocks(lines, blocks)
    except ValueError as e:
        die(f"run-emulator: {path}: {e}")
    for why, gone in taken:
        for line in gone:
            print(f"run-emulator: NOT RUN on this host ({why}): {line}",
                  file=sys.stderr)
    return ";".join(lines) + ";"


# Every leg's script is PRECOMPUTED here, so a refused cut or drop — or
# a missing .steps file — kills the lane before any device sees a leg:
# measured 2026-08-16, three legs green-on-nothing ("script has no
# expects") from an inline refusal.
_scripts = {}


def script_for(scene):
    if scene not in _scripts:
        mods = lane.MODS.get(scene, {})
        if "cut" in mods:
            verb, keep, extra = mods["cut"]
            text = scene_script_cut(scene, verb, keep, extra)
        elif "drop" in mods:
            text = scene_script_drop(scene, mods["drop"])
        else:
            text = scene_script(scene)
        _scripts[scene] = text + mods.get("append", "")
    return _scripts[scene]


for _scene in sorted({lane.scene_of(_leg) for _leg in lane.legs()}):
    script_for(_scene)


def relaunch_count(script_text):
    """The `relaunch` statements in a leg's script — the interpreter's own
    flattening, one level simpler: this text is already `;`-joined and no
    quoted string can spell a bare statement. THE VERB, not the whole
    statement: the door rides as one argument (docs/tasks-s4-plan.md P5),
    so `relaunch launch` counts and `relaunch_soon` still does not."""
    return sum(1 for s in re.split(r"[;\n]", script_text)
               if s.split()[:1] == ["relaunch"])


def relaunch_count_selftest():
    """Watched on every launch, drop_block_selftest's shape: this reading
    decides whether a leg WAITS FOR A SECOND ACT, so a count that answers
    0 on a two-act scene runs act one and calls the leg green — the whole
    door untested with nothing red (docs/tasks-s9-plan.md R6)."""
    cases = (
        ("expect_title \"t\";relaunch;expect_entries 1", 1, "the shipped shape"),
        ("expect_title \"t\";expect_entries 0", 0, "no second act"),
        ("a;relaunch;b;relaunch;c", 2, "two acts, which the arm refuses"),
        ("expect label#0 \"relaunch\"", 0, "the word inside a quoted string"),
        ("relaunch_soon;expect_entries 1", 0, "a longer verb starting with it"),
        ("expect_title \"t\";relaunch launch;expect_entries 1", 1,
         "the plain door, whose argument is the door name"),
        ("  relaunch  \n expect_entries 1", 1, "spaces and a real newline"),
    )
    for text, want, why in cases:
        got = relaunch_count(text)
        if got != want:
            die(f"run-emulator: SELF-TEST FAIL — relaunch_count read {got} "
                f"and not {want} for {why}")
    print(f"run-emulator: relaunch_count agrees on {len(cases)} scripts",
          flush=True)


relaunch_count_selftest()


def kaya_logcat(serial):
    return out_of(["timeout", "10", "adb", "-s", serial, "logcat", "-d",
                   "-s", "kaya:*"])


def kaya_starts(dump):
    return len(re.findall(r"KAYA_DRAG_STARTED: draganddrop", dump))


def motionevent(serial, kind, x, y, log):
    return run(["timeout", "30", "adb", "-s", serial, "shell", "input",
                "motionevent", kind, str(int(x)), str(int(y))],
               stdout=log, stderr=log).returncode


# The notification shade's row, found by TEXT: uiautomator's dump is the
# only reader of another app's window this host has, and SystemUI's shade
# is another app's window. The title is what the scene asserted, so the
# row it names is the row it posted.
NOTIFY_TAP_TRIES = 3
NOTIFY_TAP_RETRY_S = 4.0


def shade_row_centre(dump, title):
    """The centre of the node whose text is exactly `title`, or None. The
    dump is XML, and a title is free text, so the attribute is compared
    after unescaping rather than matched inside the pattern."""
    import html
    for m in re.finditer(r'text="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
                         dump):
        if html.unescape(m.group(1)) != title:
            continue
        x1, y1, x2, y2 = (int(v) for v in m.groups()[1:])
        return (x1 + x2) // 2, (y1 + y2) // 2
    return None


def tap_notification(serial, title, log):
    """THE `notification_activate` VERB'S ONE HAND (docs/tasks-s3-plan.md
    N5): expand the shade, find the row by its title, tap it, collapse.
    An app may not open SystemUI's shade or read its window, so this is
    the drag verb's shape one feature over — the app prints what it
    wants and the host drives the device.

    Returns the clause the injection line prints. The shade is collapsed
    on every path: left open it covers the next leg's first frame."""
    expanded = run(["adb", "-s", serial, "shell", "cmd", "statusbar",
                    "expand-notifications"], stdout=log, stderr=log)
    if expanded.returncode != 0:
        return "the shade refused to expand"
    try:
        # The dump lands on the device and is read back: `uiautomator
        # dump /dev/tty` interleaves with the tool's own chatter.
        for attempt in range(1, 4):
            time.sleep(0.5)
            run(["adb", "-s", serial, "shell", "uiautomator", "dump",
                 "/sdcard/kaya-shade.xml"], stdout=log, stderr=log)
            dump = adb_out(serial, "shell", "cat",
                           "/sdcard/kaya-shade.xml").replace("\r", "")
            centre = shade_row_centre(dump, title)
            if centre is not None:
                adb(serial, "shell", "input", "tap", str(centre[0]),
                    str(centre[1]), stdout=log, stderr=log)
                return (f"tapped {title!r} at {centre[0]},{centre[1]} "
                        f"on dump {attempt}")
            texts = sorted({m for m in re.findall(r'text="([^"]+)"', dump)})
            print(f"run-emulator: the shade dump {attempt} on {serial} "
                  f"carries no row {title!r}; it reads {texts}", file=log)
        return f"no row reading {title!r} in three shade dumps"
    finally:
        adb(serial, "shell", "cmd", "statusbar", "collapse", stdout=log,
            stderr=log)


# ------------------------------------------------------- the second act
# THE APP'S OWN STATE HOME (docs/tasks-s9-plan.md R6): `<files>/act2/<id>`
# under the app's private data, with `<id>` the DECLARED reverse-DNS id
# and not the lane's package. run-as is the door — the same one the verb
# trace comes back through, and the debug APKs are debuggable.
ACT2_REL = f"files/act2/{DECLARED.id}"
# How long act one's process has to be GONE after its verdict (its own
# exit grace is 3s), and how long the relaunched process has to answer.
ACT2_GONE_S = 20.0
ACT2_VERDICT_S = 120.0


def run_as(serial, package, *args):
    """One command inside the app's private data directory, and what it
    printed. THE EXIT CODE SAYS LITTLE: `adb exec-out run-as … cat` on a
    missing file exits 0 with cat's own "No such file or directory" on
    the stream (measured 2026-09-08), so every caller here reads the
    CONTENT and the code rides along for the record."""
    got = subprocess.run(["adb", "-s", serial, "exec-out", "run-as",
                          package, *args], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=False, **TEXT)
    return got.stdout, got.returncode


def app_pid(serial, package):
    return adb_out(serial, "shell", "pidof", package).strip()


def act_two(serial, name, package, component, dump, log):
    """THE PLATFORM'S OWN DOOR (docs/tasks-s9-plan.md R6, R7;
    docs/tasks-s4-plan.md P5). Act one has published its verdict and left,
    so the door this opens starts a COLD process — the tap a user makes on
    a reminder for an app that is no longer running, or the app started
    again the way a user starts it — and the marker act one wrote is what
    tells that process which scene it is finishing. Returns act two's
    verdict line, or "" with the reason printed."""
    tap = re.search(r"KAYA_RELAUNCH: door notify_tap notification=(\d+) "
                    r"title=(.*)", dump)
    plain = "KAYA_RELAUNCH: door launch" in dump
    link = re.search(r"KAYA_RELAUNCH: door link url=(\S+)", dump)
    if tap is None and not plain and link is None:
        print(f"{name}: act one published ACT 1 OK and named no door — "
              f"its log carries no KAYA_RELAUNCH line, so there is nothing "
              f"to open", file=log)
        return ""
    nid, title = (tap.group(1), tap.group(2).rstrip("\r")) if tap else ("", "")
    # THE PROCESS MUST BE GONE FIRST: a tap into a live app is an
    # onNewIntent, which is S3's warm activation and not S9's. AND
    # `am force-stop` IS NOT THE FALLBACK ON THE TAP DOOR — it takes the
    # app's own notifications out of the shade with it, so the door would
    # go with the process; a process still standing here is act one's
    # clean exit failing, and is reported as that. The PLAIN door has no
    # notification to lose and still reports it, because a live process
    # there means the same defect.
    deadline = time.monotonic() + ACT2_GONE_S
    pid = app_pid(serial, package)
    while pid and time.monotonic() < deadline:
        time.sleep(0.5)
        pid = app_pid(serial, package)
    if pid:
        print(f"{name}: act one's process {pid} was still alive "
              f"{ACT2_GONE_S:.0f}s after its verdict, so the door would "
              f"reach the LIVE app; force-stop is not the fallback here "
              f"because it cancels the app's notifications and the tap "
              f"door with them", file=log)
        return ""
    if plain or link:
        # THE PLAIN DOOR (docs/tasks-s4-plan.md P5): the same package
        # started with NO extras and nothing pending, which is what a
        # user's tap on the launcher icon is. THE LINK DOOR
        # (docs/app-links-plan.md L5) is the same act boundary with the
        # URL in place of the component — what `am start -a VIEW -d`
        # does, which is what a tap on a link does. Neither carries an
        # extra, so both second acts read their scene off the marker.
        # force-stop after the wait above — the process is already gone,
        # and this drops the task record so the start below cannot bring
        # a stale task forward with the previous leg's intent extras on
        # it; on the link door that matters more, since `singleTask`
        # exists to reuse a task.
        if link:
            url = link.group(1).rstrip("\r")
            # `-p` NARROWS THE IMPLICIT INTENT TO THIS PACKAGE, and it
            # has to: the scheme is the app's DECLARED ID, every host
            # APK on this emulator claims it, and a bare `am start -a
            # VIEW -d` then starts ResolverActivity — the chooser, with
            # act two never launched (measured 2026-09-09,
            # docs/traps.md). The filter is still what resolves it.
            start = ["am", "start", "-W", "-a",
                     "android.intent.action.VIEW", "-d", f"'{url}'",
                     "-p", package]
            told = f"link {url}"
        else:
            start = ["am", "start", "-W", "-n", component]
            told = f"plain launch of {component}"
        print(f"{name}: act one's process is gone; the door is a {told}",
              file=log)
        adb(serial, "shell", "am", "force-stop", package, stdout=log,
            stderr=log)
        started = adb(serial, "shell", *start,
                      stdout=subprocess.DEVNULL, stderr=log).returncode
        print(f"{name}: door {'link' if link else 'launch'} -> am start "
              f"exit {started}", file=log)
        if started != 0:
            return ""
    else:
        print(f"{name}: act one's process is gone; the door is notification "
              f"{nid} {title!r}", file=log)
        told = tap_notification(serial, title, log)
        print(f"{name}: door notify_tap -> {told}", file=log)
        if not told.startswith("tapped"):
            # NOTHING WAS TAPPED, so nothing will arrive: the poll below
            # would spend its whole budget proving what this sentence
            # already says.
            return ""
    deadline = time.monotonic() + ACT2_VERDICT_S
    while time.monotonic() < deadline:
        # THE ANSWER IS A VERDICT LINE, never merely output: `adb
        # exec-out run-as … cat` exits 0 and puts cat's own "No such
        # file or directory" on the stream, so a poll that took any
        # non-empty text read the MISS as the answer (measured
        # 2026-09-08, and it is what the first hand run reported).
        text, _rc = run_as(serial, package, "cat",
                           f"{ACT2_REL}/act2.verdict")
        for line in text.replace("\r", "").splitlines():
            if line.startswith("KAYA_SELFTEST:"):
                return line.strip()
        time.sleep(0.5)
    # WHAT WAS MEASURED, since the causes look alike from outside: an
    # untouched marker means no relaunched process ever read it, a
    # consumed one means the second act started and did not finish. The
    # DIRECTORY IS LISTED rather than the marker cat'd — a cat exits 0
    # either way (see run_as), so a code-keyed sentence here would say
    # the same thing for both causes.
    listing, _rc = run_as(serial, package, "ls", ACT2_REL)
    held = listing.replace("\r", "").split()
    seen = ("the marker is still on disk, so nothing consumed it"
            if "marker" in held else
            "the marker is gone, so a process did read it")
    print(f"{name}: no act2.verdict in {ACT2_VERDICT_S:.0f}s — {seen} "
          f"(the directory holds {held or 'nothing'}); pid now "
          f"{app_pid(serial, package) or 'none'}", file=log)
    for line in re.findall(r"^.*(?:KAYA_ACT2|KAYA_NOTIFICATION_ACTIVATED"
                           r"|KAYA_SELFTEST).*$", kaya_logcat(serial),
                           re.M):
        print(f"{name}: {line}", file=log)
    return ""


def inject_drag(serial, aim, ms, started_before, log):
    """One gesture, GATED ON THE APP'S OWN START (docs/deferred.md's
    android drag WATCH): press, hold until KAYA_DRAG_STARTED says the
    platform drag session exists, then walk the moves over the ms the
    host's load bought and release. No move can precede the session, which
    is the shape twenty-four sightings recorded — STARTED, then `ended
    op=0 entered=0` with no DRAG_LOCATION ever reaching the app.

    Returns the clause the injection line prints. The pointer is released
    on every path, including a failure, and DRAG_POINTER_DOWN carries it
    to the teardown for the paths a `finally` cannot reach."""
    x1, y1, x2, y2 = (int(v) for v in aim)
    # A pointer left down refuses the next DOWN on this device ("Invalid
    # DOWN event - pointers already down") and the pool stays warm across
    # runs, so a release comes FIRST too — with nothing down it is one
    # logged line and no event.
    motionevent(serial, "UP", x1, y1, log)
    if motionevent(serial, "DOWN", x1, y1, log) != 0:
        return "the DOWN was refused by adb"
    DRAG_POINTER_DOWN[serial] = (x1, y1)
    try:
        pressed = time.monotonic()
        held = None
        while time.monotonic() - pressed < DRAG_HOLD_MS / 1000.0:
            if kaya_starts(kaya_logcat(serial)) > started_before:
                held = int((time.monotonic() - pressed) * 1000)
                break
            time.sleep(0.15)
        if held is None:
            return (f"NO START while the press was held {DRAG_HOLD_MS}ms — "
                    f"released without moving")
        moves, gap = drag_moves(ms)
        walked = 0
        for i in range(1, moves + 1):
            time.sleep(gap)
            x, y = x1 + (x2 - x1) * i / moves, y1 + (y2 - y1) * i / moves
            if motionevent(serial, "MOVE", x, y, log) != 0:
                break
            DRAG_POINTER_DOWN[serial] = (int(x), int(y))
            walked += 1
        return (f"started after {held}ms, {walked} of {moves} moves "
                f"{int(gap * 1000)}ms apart")
    finally:
        x, y = DRAG_POINTER_DOWN.pop(serial, (x1, y1))
        motionevent(serial, "UP", x, y, log)


def kaya_write_compose_marker():
    gen_dir = ROOT / "android/kaya/generated/dev/kaya"
    gen_dir.mkdir(parents=True, exist_ok=True)
    compose_id = out_of([str(ROOT / "tools/build-id.py"),
                         "compose"]).strip()
    (gen_dir / "KayaBuildId.java").write_text(
        "// Generated by tools/android/run-emulator.py. Do not edit, "
        "do not commit.\n"
        "package dev.kaya;\n\n"
        "public final class KayaBuildId {\n"
        f'    public static final String MARKER = '
        f'"kaya-build-id:{compose_id}";\n\n'
        "    private KayaBuildId() {}\n"
        "}\n", encoding="utf-8")


def apk_icon_verify(apk):
    """The bytes INSIDE the apk gradle just wrote against the bytes the
    ARM produced (tools/lib/packaging/android.py `apk_entries`, which is
    also what wrote them). HERE AND NOT IN A GATE, so the wall is on the
    path nobody can avoid (invariant 3). android/build.gradle.kts pins
    isCrunchPngs = false so aapt cannot re-encode behind this.

    EVERY DENSITY, not the unqualified entry alone (docs/packaging-plan.md
    P6): the launcher draws the density that matches the device, so a
    rendered set that half arrived would be invisible to a check that read
    only the fallback."""
    want = packaging_android.apk_entries(ROOT)
    for entry, data in sorted(want.items()):
        if run(["unzip", "-l", str(apk), entry],
               stdout=subprocess.DEVNULL,
               stderr=subprocess.DEVNULL).returncode != 0:
            print(f"run-emulator: {apk} carries no {entry} — the app",
                  file=sys.stderr)
            print("  identity's picture never reached the package, so its "
                  "launcher icon", file=sys.stderr)
            print("  is whatever Android draws for an app that declares "
                  "none", file=sys.stderr)
            print(f"  (android/build.gradle.kts packages what "
                  f"{IDENTITY_RES} holds; {ICON_REL} is the source)",
                  file=sys.stderr)
            return False
        declared = hashlib.sha256(data).hexdigest()
        packaged = hashlib.sha256(subprocess.run(
            ["unzip", "-p", str(apk), entry],
            stdout=subprocess.PIPE, check=False).stdout).hexdigest()
        if declared != packaged:
            print(f"run-emulator: the mark inside {apk} is not the one "
                  f"the arm rendered.", file=sys.stderr)
            print(f"  rendered from {ICON_REL}: {declared}",
                  file=sys.stderr)
            print(f"  packaged ({entry}): {packaged}", file=sys.stderr)
            print("  One picture is the picture on all five platforms "
                  "(ruling 1); two", file=sys.stderr)
            print("  readers that disagree is the failure ruling 4 exists "
                  "to prevent.", file=sys.stderr)
            return False
    print(f"identity: {len(want)} launcher mipmaps inside "
          f"{apk.name}, every one the arm's own bytes")
    return True


def build_tool(name, why):
    """A build-tools binary, or None with the reason printed.

    The version is READ from the module that pins it, in minsdk_of's
    shape: retyping it here would go stale the day the nix SDK moves and
    the caller would then blame what it was reading."""
    pin = ROOT / "android/kaya/build.gradle.kts"
    m = re.search(r'buildToolsVersion\s*=\s*"([^"]+)"',
                  pin.read_text(encoding="utf-8"))
    if m is None:
        print(f"run-emulator: {pin} pins no buildToolsVersion, so {name} "
              f"cannot be resolved", file=sys.stderr)
        print(f"  and {why} cannot be read back", file=sys.stderr)
        return None
    tool = pathlib.Path(os.environ.get("ANDROID_HOME", "")) \
        / "build-tools" / m.group(1) / name
    if not tool.is_file():
        print(f"run-emulator: {tool} is not there, so {why}",
              file=sys.stderr)
        print("  cannot be read back — it lives in the compiled package "
              "and in no file of the tree", file=sys.stderr)
        return None
    return tool


def apk_launch_verify(apk):
    """THE LAUNCH SLOT'S TWO HALVES INSIDE THE APK gradle just wrote,
    against guests/assets/identity.toml (docs/tasks-s2-plan.md T4) —
    beside apk_icon_verify, on the same path nobody can avoid. The
    picture is a FILE entry and is hashed; the colour is a value in the
    resource table and is read back with aapt2, which is the only route
    to it — nothing in the APK's file listing carries it."""
    entry = "res/drawable/kaya_launch_mark.png"
    if run(["unzip", "-l", str(apk), entry],
           stdout=subprocess.DEVNULL,
           stderr=subprocess.DEVNULL).returncode != 0:
        print(f"run-emulator: {apk} carries no {entry} — the launch "
              f"slot's picture", file=sys.stderr)
        print("  never reached the package, so Android draws the "
              "windowBackground alone", file=sys.stderr)
        print(f"  (android/build.gradle.kts is the reader; "
              f"{LAUNCH_IMAGE_REL} is the source)", file=sys.stderr)
        return False
    declared = hashlib.sha256(LAUNCH_IMAGE_SRC.read_bytes()).hexdigest()
    packaged = hashlib.sha256(subprocess.run(
        ["unzip", "-p", str(apk), entry],
        stdout=subprocess.PIPE, check=False).stdout).hexdigest()
    if declared != packaged:
        print(f"run-emulator: the launch picture inside {apk} is not the "
              f"declared one.", file=sys.stderr)
        print(f"  declared ({LAUNCH_IMAGE_REL}): {declared}",
              file=sys.stderr)
        print(f"  packaged ({entry}): {packaged}", file=sys.stderr)
        return False
    aapt2 = build_tool("aapt2", f"the launch colour inside {apk}")
    if aapt2 is None:
        return False
    table = out_of([str(aapt2), "dump", "resources", str(apk)],
                   stderr=subprocess.STDOUT)
    m = re.search(r"color/kaya_launch_background\s*\n\s*\(\)\s*"
                  r"(#[0-9a-fA-F]{8})", table)
    if m is None:
        print(f"run-emulator: {apk} declares no "
              f"color/kaya_launch_background —", file=sys.stderr)
        print("  the splash theme names it, and an attribute pointing "
              "at a missing", file=sys.stderr)
        print("  colour leaves the platform's own ground behind the "
              "mark", file=sys.stderr)
        return False
    want = "#ff" + LAUNCH_BG[1:].lower()
    if m.group(1).lower() != want:
        print(f"run-emulator: the launch colour inside {apk} is "
              f"{m.group(1)}, and", file=sys.stderr)
        print(f"  {KAYA_IDENTITY_MANIFEST} declares {LAUNCH_BG} "
              f"({want}).", file=sys.stderr)
        return False
    return True


# The compiled manifest nests by indentation, 4 per element and +2 for an
# element's own attributes, so a block is its header's indent and every
# deeper line under it.
def xmltree_blocks(text, name):
    out, header, body = [], None, []
    for line in text.split("\n"):
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if header is not None and stripped and indent <= header:
            out.append("\n".join(body))
            header, body = None, []
        if stripped.startswith(f"E: {name} "):
            header, body = indent, [line]
        elif header is not None:
            body.append(line)
    if header is not None:
        out.append("\n".join(body))
    return out


def xmltree_attr(block, name):
    """One attribute's value, NORMALIZED. aapt2 prints an enum as plain
    decimal (`launchMode(0x0101001d)=2`) and other values as hex, so a
    reader that matched one spelling reported a correct APK as broken —
    measured 2026-09-09, on the first run of this check."""
    m = re.search(rf":{name}\(0x[0-9a-f]+\)=(\S+)", block)
    return None if m is None else m.group(1)


def link_declaration(tree, package, want):
    """The app-link door inside a COMPILED manifest: [] when it is there,
    otherwise the failures. Pure, so the reader itself is watched."""
    errs = []
    activity = [a for a in xmltree_blocks(tree, "activity")
                if f'"{package}.MainActivity"' in a]
    if len(activity) != 1:
        return [f"the compiled manifest holds {len(activity)} activity "
                f"named {package}.MainActivity — the app-link filter is "
                f"declared on it, and aapt2 read none (or more than one)"]
    activity = activity[0]
    # singleTask is launchMode 2, read as a NUMBER: see xmltree_attr.
    mode = xmltree_attr(activity, "launchMode")
    if mode is None or int(mode, 0) != 2:
        errs.append(f"{package}.MainActivity is launchMode "
                    f"{mode or 'unset'} and not singleTask (2) in the "
                    f"COMPILED manifest, so a link tapped while it runs "
                    f"would stack a second activity")
    view = [f for f in xmltree_blocks(activity, "intent-filter")
            if "android.intent.action.VIEW" in f]
    if not view:
        errs.append(f"{package}.MainActivity carries no VIEW "
                    f"intent-filter, so this package resolves no app link "
                    f"at all")
        return errs
    got = re.findall(r':scheme\(0x[0-9a-f]+\)="([^"]*)"', view[0])
    if got != [want]:
        errs.append(f"the VIEW filter claims {got} and the declaration "
                    f"says {want!r} (tools/lib/packaging/android.py's "
                    f"link_scheme; the manifest placeholder is "
                    f"android/build.gradle.kts's kayaLinkScheme)")
    for category in ("android.intent.category.DEFAULT",
                     "android.intent.category.BROWSABLE"):
        if category not in view[0]:
            errs.append(f"the VIEW filter declares no {category} — an "
                        f"implicit intent is matched against DEFAULT and "
                        f"a followed link carries BROWSABLE")
    return errs


def link_declaration_selftest():
    """Watched on every launch: the reader above decides whether an APK
    ships an app-link door at all, and its FIRST draft matched
    `launchMode` only in hex and reported a correct package as broken."""
    good = (
        '          E: activity (line=73)\n'
        '            A: android:name(0x01010003)="p.MainActivity" (Raw: "p.MainActivity")\n'
        '            A: android:exported(0x01010010)=true\n'
        '            A: android:launchMode(0x0101001d)=2\n'
        '              E: intent-filter (line=77)\n'
        '                  E: action (line=78)\n'
        '                    A: android:name(0x01010003)="android.intent.action.MAIN"\n'
        '              E: intent-filter (line=82)\n'
        '                  E: action (line=83)\n'
        '                    A: android:name(0x01010003)="android.intent.action.VIEW"\n'
        '                  E: category (line=85)\n'
        '                    A: android:name(0x01010003)="android.intent.category.DEFAULT"\n'
        '                  E: category (line=86)\n'
        '                    A: android:name(0x01010003)="android.intent.category.BROWSABLE"\n'
        '                  E: data (line=88)\n'
        '                    A: android:scheme(0x01010027)="s.c" (Raw: "s.c")\n'
        '          E: service (line=98)\n'
        '            A: android:name(0x01010003)="dev.kaya.KayaHarnessAccessibility"\n'
    )
    if link_declaration(good, "p", "s.c"):
        die(f"run-emulator: SELF-TEST FAIL — link_declaration refused a "
            f"correct manifest: {link_declaration(good, 'p', 's.c')}")
    # The hex spelling must read as singleTask too, since that is the one
    # the first draft assumed and no APK here spells.
    if link_declaration(good.replace("=2\n", "=0x00000002\n"), "p", "s.c"):
        die("run-emulator: SELF-TEST FAIL — link_declaration refused a "
            "hex-spelled launchMode")
    cases = (
        ("the launch mode gone", good.replace(
            "            A: android:launchMode(0x0101001d)=2\n", ""),
         "singleTask"),
        ("standard instead of singleTask",
         good.replace("launchMode(0x0101001d)=2", "launchMode(0x0101001d)=0"),
         "singleTask"),
        ("the VIEW filter gone",
         good.replace("android.intent.action.VIEW", "android.intent.action.SEND"),
         "no VIEW intent-filter"),
        ("BROWSABLE gone",
         good.replace("android.intent.category.BROWSABLE",
                      "android.intent.category.APP_BROWSER"),
         "BROWSABLE"),
        ("an unsubstituted placeholder",
         good.replace('scheme(0x01010027)="s.c"',
                      'scheme(0x01010027)="${kayaLinkScheme}"'),
         "claims"),
        ("no activity by that name", good.replace("p.MainActivity", "q.Other"),
         "holds 0 activity"),
    )
    for label, doctored, needle in cases:
        if doctored == good:
            die(f"run-emulator: SELF-TEST BROKEN — the link negative "
                f"{label!r} changed nothing")
        errs = link_declaration(doctored, "p", "s.c")
        if not any(needle in e for e in errs):
            die(f"run-emulator: SELF-TEST FAIL — link_declaration passed "
                f"{label} (wanted {needle!r}; got {errs})")
    print(f"run-emulator: link_declaration refuses {len(cases)} doctored "
          f"manifests and accepts both launchMode spellings", flush=True)


link_declaration_selftest()


def apk_link_verify(apk, package):
    """THE APP-LINK DOOR INSIDE THE APK gradle just wrote
    (docs/app-links-plan.md §4), beside apk_icon_verify and
    apk_launch_verify and for their reason: the manifest in the tree is
    the SOURCE, and what a device resolves is the MERGED, compiled one.
    A placeholder that never substituted, a manifest merge that dropped
    the filter, an activity that lost its launch mode — each ships an APK
    whose only witness is a links leg, and three of the four suites run
    none.

    The compiled manifest is read with aapt2, which is the only route to
    it: the entry inside the package is binary XML and carries no text."""
    aapt2 = build_tool("aapt2", "the app-link filter inside the APK")
    if aapt2 is None:
        return False
    tree = out_of([str(aapt2), "dump", "xmltree", str(apk),
                   "--file", "AndroidManifest.xml"],
                  stderr=subprocess.STDOUT)
    want = packaging_android.link_scheme(ROOT)
    errs = link_declaration(tree, package, want)
    for e in errs:
        print(f"run-emulator: {apk}: {e}", file=sys.stderr)
    if errs:
        return False
    print(f"links: {package} claims {want}:// with launchMode=singleTask")
    return True


def apk_assets_verify(apk):
    """THE SAME BYTE EQUALITY FOR THE WHOLE ASSET ROOT
    (docs/assets-plan.md A6 Gate 2): Android is the ONE platform whose
    packaged assets are not files — an entry inside an APK has no path
    and is read through AssetManager, and the leg that arrives with no
    KAYA_ASSET_DIR resolves out of the package itself. BOTH DIRECTIONS:
    a missing entry is the obvious failure; an EXTRA one is the failure
    the frozen census actually catches, because a stray file in
    `assets/` puts a name in the miss sentence no other platform
    prints."""
    listing = out_of(["unzip", "-Z1", str(apk),
                      f"assets/{APK_ASSET_PREFIX}/*"])
    root = f"assets/{APK_ASSET_PREFIX}/"
    packaged = [ln.strip() for ln in listing.splitlines()
                if ln.strip().startswith(root)
                and not ln.strip().endswith("/")]
    here = tree_asset_hashes()
    there = {e[len(root):]: e for e in packaged}
    bad = []
    if not here:
        bad.append("  the tree's asset root is empty, so this "
                   "comparison would agree with an empty package")
    for name, want in sorted(here.items()):
        entry = there.get(name)
        if entry is None:
            bad.append(f"  {name}: is not in the apk under {root}")
            continue
        got_bytes = subprocess.run(["unzip", "-p", str(apk), entry],
                                   stdout=subprocess.PIPE,
                                   check=False).stdout
        got = hashlib.sha256(got_bytes).hexdigest()
        if got != want:
            bad.append(f"  {name}: packaged as {got[:12]}, the tree "
                       f"has {want[:12]}")
    for name in sorted(set(there) - set(here)):
        bad.append(f"  {name}: is in the apk and not in the tree — the "
                   f"app's own census would name an asset no other "
                   f"platform carries")
    if bad:
        print(f"run-emulator: the assets inside {apk} are not the "
              f"tree's:")
        print("\n".join(bad))
        print(f"  android/build.gradle.kts copies {ASSET_SRC} into "
              f"{root} at configuration")
        print("  time; the leg that runs with no KAYA_ASSET_DIR reads "
              "exactly these")
        print("  entries, and tools/scenes/assets.steps freezes their "
              "names")
        return False
    print(f"assets: {len(here)} files inside {pathlib.Path(apk).name} "
          f"under {root}, every one byte-equal to the tree")
    return True


def module_min_sdk(module, tier):
    """The one `minSdk = N` in a module's build.gradle.kts, read rather
    than written twice: a guest cross-built against a newer platform
    links fine and dies at load time with a relocation nobody can
    read."""
    for line in pathlib.Path(module).read_text(
            encoding="utf-8").splitlines():
        if line.lstrip().startswith("//"):
            continue
        m = re.search(r"\bminSdk\s*=\s*(\d+)", line)
        if m:
            return m.group(1)
    die(f"run-emulator: {module} declares no minSdk, so {tier} has no "
        f"platform to cross-build against")


def ndk_clang(api, module):
    ndk = pathlib.Path(os.environ.get("ANDROID_NDK_ROOT", ""))
    bins = sorted(ndk.glob("toolchains/llvm/prebuilt/*/bin"))
    ndkbin = bins[0] if bins else ndk / "toolchains/llvm/prebuilt/none"
    clang = ndkbin / f"aarch64-linux-android{api}-clang"
    if not clang.is_file():
        die(f"run-emulator: the NDK has no aarch64-linux-android{api}-"
            f"clang\n  (looked in {ndkbin}; minSdk {api} comes from "
            f"{module})")
    return ndkbin, clang


def exported_once(ndkbin, so, symbol):
    got = out_of([str(ndkbin / "llvm-nm"), "-D", "--defined-only",
                  str(so)])
    # THE LEADING SPACE IS THE POINT: llvm-nm prints `<addr> T <name>`,
    # and cgo emits a SECOND symbol per //export — the generated
    # trampoline `_cgoexp_<hash>_<name>` ends in the same characters,
    # so an end-anchor alone counts two.
    return sum(1 for ln in got.splitlines()
               if ln.endswith(f" {symbol}"))


def kaya_go_build(lib, jnilibs):
    """The Go guest as `-buildmode=c-shared` (docs/go-mobile-plan.md
    D1). The NDK API level follows the module's own minSdk; cgo uses CC
    to LINK as well as to compile, so the cross compiler rides CC and
    the #cgo android line in bindings/go/runtime.go carries
    -L…/aarch64-linux-android/debug -lkaya, filled by the cargo ndk
    build before this. guests/go/cmd IS THE WHOLE GUEST:
    `-buildmode=c-shared` allows exactly one main package per
    library."""
    module = ROOT / "android/gohost/build.gradle.kts"
    api = module_min_sdk(module, "the Go guest")
    ndkbin, clang = ndk_clang(api, module)
    (ROOT / "target/go-android").mkdir(parents=True, exist_ok=True)
    if run(["go", "build", "-buildmode=c-shared", "-o",
            str(ROOT / f"target/go-android/lib{lib}.so"),
            "dev.kaya/guests/go/cmd"],
           env=dict(os.environ, CGO_ENABLED="1", GOOS="android",
                    GOARCH="arm64", CC=str(clang))).returncode != 0:
        print("run-emulator: the Go guest did not cross-build",
              file=sys.stderr)
        return False
    shutil.copy2(ROOT / f"target/go-android/lib{lib}.so", jnilibs)
    n = exported_once(ndkbin, pathlib.Path(jnilibs) / f"lib{lib}.so",
                      "Java_dev_kaya_KayaGo_attach")
    if n != 1:
        print(f"run-emulator: lib{lib}.so does not export exactly one",
              file=sys.stderr)
        print(f"  Java_dev_kaya_KayaGo_attach (found {n}). That symbol "
              f"is the whole", file=sys.stderr)
        print("  contract between "
              "android/kaya/src/main/kotlin/dev/kaya/KayaGo.kt",
              file=sys.stderr)
        print("  and the //export in bindings/go/android.go; nothing "
              "else checks", file=sys.stderr)
        print("  it, and the failure on a device is an "
              "UnsatisfiedLinkError in", file=sys.stderr)
        print("  onCreate that reads as a leg which never printed a "
              "verdict.", file=sys.stderr)
        return False
    return True


def kaya_py_build(jnilibs):
    """tools/android/pyhost-jni.c as libkaya_pyhost.so.
    Java_dev_kaya_KayaPy_run is the one name binding KayaPy.kt to the
    shim and NO COMPILER ON EITHER SIDE CHECKS IT."""
    module = ROOT / "android/pyhost/build.gradle.kts"
    api = module_min_sdk(module, "the python shim")
    ndkbin, clang = ndk_clang(api, module)
    pypfx = (pathlib.Path(os.environ["KAYA_CPYTHON_ANDROID_AARCH64"])
             / "prefix")
    if run([str(clang), "-shared", "-fPIC",
            str(ROOT / "tools/android/pyhost-jni.c"),
            "-I", str(pypfx / "include/python3.15"),
            "-L", str(pypfx / "lib"), "-lpython3.15",
            "-o", str(pathlib.Path(jnilibs) /
                      "libkaya_pyhost.so")]).returncode != 0:
        print("run-emulator: the python shim did not cross-build",
              file=sys.stderr)
        return False
    n = exported_once(ndkbin,
                      pathlib.Path(jnilibs) / "libkaya_pyhost.so",
                      "Java_dev_kaya_KayaPy_run")
    if n != 1:
        print("run-emulator: libkaya_pyhost.so does not export "
              "Java_dev_kaya_KayaPy_run", file=sys.stderr)
        print(f"  exactly once (found {n}) — KayaPy.run would throw",
              file=sys.stderr)
        print("  UnsatisfiedLinkError at first use", file=sys.stderr)
        return False
    return True


def stage_python_assets():
    """The staged stdlib + guests, re-derived every run: the runner is
    the staging truth, like the jniLibs beside it. AAPT decompresses
    real `.gz` assets, so the rename here is undone by MainActivity's
    extraction; the stamp is a hash of the staged bytes, so an
    unchanged staging is a skipped device copy."""
    pypfx = (pathlib.Path(os.environ["KAYA_CPYTHON_ANDROID_AARCH64"])
             / "prefix")
    dest = ROOT / "android/pyhost/src/main/assets/python"
    shutil.rmtree(dest, ignore_errors=True)
    (dest / "app").mkdir(parents=True)
    skip = {"test", "idlelib", "tkinter", "turtledemo", "__pycache__"}
    src = pypfx / "lib/python3.15"
    out_lib = dest / "lib/python3.15"
    for f in sorted(src.rglob("*")):
        if f.is_dir() or set(f.relative_to(src).parts) & skip:
            continue
        target = out_lib / f.relative_to(src)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, target)
    app = dest / "app"
    shutil.copy2(ROOT / "tools/pyhost-main.py", app / "main.py")
    for scene in ("portfolio", "varied"):
        shutil.copy2(ROOT / f"guests/python/{scene}.py",
                     app / f"{scene}.py")
    shutil.copytree(ROOT / "bindings/python/kaya", app / "kaya",
                    ignore=shutil.ignore_patterns("__pycache__"))
    renamed = 0
    for p in dest.rglob("*.gz"):
        p.rename(p.with_name(p.name + "-"))
        renamed += 1
    h = hashlib.sha256()
    count = 0
    for f in sorted(dest.rglob("*")):
        if f.is_file():
            h.update(f.relative_to(dest).as_posix().encode())
            h.update(f.read_bytes())
            count += 1
    if count < 400:
        die(f"run-emulator: python staging copied {count} files — a "
            f"stdlib that small is the copy failing, not the guests "
            f"passing")
    (dest / "kaya-stamp").write_text(h.hexdigest(), encoding="utf-8")
    print(f"python staging: {count} files, {renamed} gz renamed, "
          f"stamp {h.hexdigest()[:12]}")


def fresh_jnilibs(path):
    """Only what this run builds ships: AGP packs every .so in jniLibs,
    so a leftover from a renamed library rode inside the APK for weeks
    (docs/probes/mobilepkg-contract.md §5.4) and a stale one failed the
    lane's own verify after the 2026-09-02 module rename."""
    path.mkdir(parents=True, exist_ok=True)
    for old in path.glob("*.so"):
        old.unlink()


def gradle_assemble(module):
    """THE ONE ASSEMBLE FUNNEL, and where the launcher mipmaps are
    rendered (docs/packaging-plan.md P6): every suite's build comes
    through here, so a density set cannot be missed by one of them.
    Gradle only packages what this wrote — it refuses a build whose
    IDENTITY_RES is absent, naming this runner."""
    packaging_android.write_res(ROOT, IDENTITY_RES)
    return run(["gradle", "--console=plain", "-q",
                f":{module}:assembleDebug"],
               cwd=ROOT / "android").returncode == 0


def build_suite(suite):
    """The suite's build phase, ending in the artifact proofs in order:
    build-id --verify on the copied .so (the COPY, not the source —
    gradle packages from jniLibs, so this covers the build and the copy
    at once), the compose-component verify on the apk, the icon and
    asset byte equalities, then the staging barrier. Builds fail the
    RUN, loudly: an unguarded build failure would install the PREVIOUS
    apk and green the legs against stale code (caught live 2026-07-22,
    a Kotlin compile error produced a zero-verdict run)."""
    apk_rel, package, _activity = lane.SUITE_APPS[suite]
    apk = ROOT / apk_rel
    if suite == "compose":
        jnilibs = ROOT / "android/rusthost/src/main/jniLibs/arm64-v8a"
        fresh_jnilibs(jnilibs)
        if run(["cargo", "ndk", "-t", "arm64-v8a", "build", "--locked",
                "--example", "rusthost"]).returncode != 0:
            return False
        shutil.copy2(ROOT / "target/aarch64-linux-android/debug/"
                            "examples/librusthost.so", jnilibs)
        if run([str(ROOT / "tools/build-id.py"), "--verify",
                str(jnilibs / "librusthost.so")]).returncode != 0:
            return False
        kaya_write_compose_marker()
        if not gradle_assemble("rusthost"):
            return False
    elif suite == "jvm":
        jnilibs = ROOT / "android/javahost/src/main/jniLibs/arm64-v8a"
        fresh_jnilibs(jnilibs)
        if run(["cargo", "ndk", "-t", "arm64-v8a", "build", "--locked",
                "--lib"]).returncode != 0:
            return False
        shutil.copy2(ROOT / "target/aarch64-linux-android/debug/"
                            "libkaya.so", jnilibs)
        if run([str(ROOT / "tools/build-id.py"), "--verify",
                str(jnilibs / "libkaya.so")]).returncode != 0:
            return False
        kaya_write_compose_marker()
        if not gradle_assemble("javahost"):
            return False
    elif suite == "go":
        jnilibs = ROOT / "android/gohost/src/main/jniLibs/arm64-v8a"
        fresh_jnilibs(jnilibs)
        # The Go guest NEEDs libkaya.so by SONAME and the app's linker
        # resolves it out of this directory.
        if run(["cargo", "ndk", "-t", "arm64-v8a", "build", "--locked",
                "--lib"]).returncode != 0:
            return False
        shutil.copy2(ROOT / "target/aarch64-linux-android/debug/"
                            "libkaya.so", jnilibs)
        if run([str(ROOT / "tools/build-id.py"), "--verify",
                str(jnilibs / "libkaya.so")]).returncode != 0:
            return False
        # NO --verify ON THE GO .so: the build id lives inside libkaya,
        # and here libkaya is a SHARED library the guest merely names,
        # so the guest carries no marker. (On iOS the same Go sources DO
        # carry it — there kaya is a static archive linked in.)
        if not kaya_go_build("gohost", jnilibs):
            return False
        kaya_write_compose_marker()
        if not gradle_assemble("gohost"):
            return False
    elif suite == "python":
        cpy = os.environ.get("KAYA_CPYTHON_ANDROID_AARCH64", "")
        if not cpy or not (pathlib.Path(cpy) / "prefix").is_dir():
            print("run-emulator: KAYA_CPYTHON_ANDROID_AARCH64 is unset "
                  "or not a", file=sys.stderr)
            print("  directory — the dev shell exports it (flake.nix's "
                  "cpythonAndroid);", file=sys.stderr)
            print("  re-enter nix develop", file=sys.stderr)
            return False
        jnilibs = ROOT / "android/pyhost/src/main/jniLibs/arm64-v8a"
        fresh_jnilibs(jnilibs)
        if run(["cargo", "ndk", "-t", "arm64-v8a", "build", "--locked",
                "--lib"]).returncode != 0:
            return False
        shutil.copy2(ROOT / "target/aarch64-linux-android/debug/"
                            "libkaya.so", jnilibs)
        if run([str(ROOT / "tools/build-id.py"), "--verify",
                str(jnilibs / "libkaya.so")]).returncode != 0:
            return False
        pfx = pathlib.Path(cpy) / "prefix"
        for so in ("libpython3.15.so", "libcrypto_python.so",
                   "libssl_python.so", "libsqlite3_python.so"):
            # rm first: the source is the read-only nix store, so a
            # prior staging's copy has no write bit and a bare copy
            # refuses it.
            (jnilibs / so).unlink(missing_ok=True)
            shutil.copy2(pfx / "lib" / so, jnilibs / so)
            (jnilibs / so).chmod(0o644)
        if not kaya_py_build(jnilibs):
            return False
        stage_python_assets()
        kaya_write_compose_marker()
        if not gradle_assemble("pyhost"):
            return False
    if run([str(ROOT / "tools/build-id.py"), "--verify",
            "--component", "compose", str(apk)]).returncode != 0:
        return False
    if not apk_icon_verify(apk):
        return False
    if not apk_launch_verify(apk):
        return False
    if not apk_link_verify(apk, package):
        return False
    if not apk_assets_verify(apk):
        return False
    if suite != "compose":
        timing(f"build-{suite}")
    targets = ([*SERIALS, TABLET_SERIAL] if suite == "compose"
               else list(SERIALS))
    return stage_suite_apk(suite, apk, package, targets)


# ONE LEG BY HAND (CLAUDE.md: validate a change with single-leg runs, not
# a whole lane). A PREFIX, the linux lane's own spelling and semantics
# (tools/linux/run-suites.sh): `KAYA_ONLY=taskspersist` takes every suite's
# taskspersist leg. A filter that selects NOTHING is refused below rather
# than printing ALL PASS over an empty run, and the verdict names the
# filter so a probe can never be read as a lane.
ONLY = os.environ.get("KAYA_ONLY", "")
_selected = 0


def selected_legs(suite):
    legs = lane.suite_legs(suite)
    return [leg for leg in legs if leg.startswith(ONLY)] if ONLY else legs


# ---------------------------------------- the real preferences domain
# NO LEG MAY WRITE THE APP'S OWN SETTINGS (docs/tasks-s4-plan.md §4).
# Under KAYA_SELFTEST the store is `<id>.selftest`, and the shipped
# domain is the USER's — a lane that wrote it would be changing the
# settings of the app on the machine. NOTHING ELSE CAN SEE THIS: every
# scene reads back through the scratch domain, so a backing that ignored
# the harness would pass every leg while quietly writing the real file.
# One `run-as ls` per device at the end of a suite, which is where a leg
# of that suite would have left it.
REAL_PREFS_FILE = f"{DECLARED.id}.xml"


def real_prefs_written(listings, real):
    """(serial, file) for every device whose shared_prefs holds the real
    domain. Pure, so its refusal can be watched firing at import."""
    return [(serial, real) for serial, names in listings if real in names]


def real_prefs_selftest():
    scratch = [f"{DECLARED.id}.selftest.xml"]
    if real_prefs_written([("emulator-1", scratch)], REAL_PREFS_FILE):
        die("run-emulator: SELF-TEST FAIL — the real-domain census named "
            "a device holding only the scratch store")
    leaked = [("emulator-1", scratch), ("emulator-2", [REAL_PREFS_FILE])]
    if len(real_prefs_written(leaked, REAL_PREFS_FILE)) != 1:
        die("run-emulator: SELF-TEST FAIL — the real-domain census missed "
            f"a device holding {REAL_PREFS_FILE}")
    print("run-emulator: the real-domain census refuses a leaked store",
          flush=True)


real_prefs_selftest()


def check_real_prefs(suite, package, targets):
    global status
    listings = []
    for serial in targets:
        listing, _rc = run_as(serial, package, "ls", "shared_prefs")
        listings.append((serial, listing.replace("\r", "").split()))
    leaked = real_prefs_written(listings, REAL_PREFS_FILE)
    if not leaked:
        print(f"prefs-{suite}: OK (the real domain {REAL_PREFS_FILE} is on "
              f"none of {len(targets)} device(s))")
        return
    for serial, real in leaked:
        print(f"run-emulator: a leg of the {suite} suite wrote the app's "
              f"REAL preferences domain on {serial} "
              f"(shared_prefs/{real}) — under KAYA_SELFTEST the store is "
              f"{DECLARED.id}.selftest and the shipped domain is the "
              f"user's (docs/tasks-s4-plan.md §4)", file=sys.stderr)
    status = 1


def run_suite_legs(suite):
    """Every leg from the lane module's roster, in its order, one drain
    at the end. The bare suite legs launch with KAYA_SELFTEST=1 (the
    unprefixed milestone2 arm); everything else passes its scene name.
    The tablet leg, the remount legs and the per-leg extras are
    lanes/android.py's FLAGS."""
    global _selected
    apk_rel, package, activity = lane.SUITE_APPS[suite]
    apk = ROOT / apk_rel
    component = f"{package}/{activity}"
    for leg in selected_legs(suite):
        _selected += 1
        flags = lane.FLAGS.get(leg, {})
        scene = lane.scene_of(leg)
        selftest = "1" if leg in lane.SUITES else scene
        script_text = script_for(scene) + flags.get("append", "")
        extras = []
        remount_expect = ""
        if "remount" in flags:
            step, remount_expect = flags["remount"]
            extras += ["--es", "KAYA_RECREATE_AFTER", str(step)]
        extras += ["--es", "KAYA_SELFTEST_SCRIPT", f"'{script_text}'"]
        if flags.get("asset_dir"):
            extras += ["--es", "KAYA_ASSET_DIR", ASSET_ON_DEVICE]
        if flags.get("appearance"):
            extras += ["--es", "KAYA_APPEARANCE", flags["appearance"]]
        # THE VERB TRACE, a RELATIVE name the interpreter resolves under
        # the app's own files dir — the one place run-as can read back
        # (crates/kaya/src/vtrace.rs).
        extras += ["--es", "KAYA_VERB_TRACE", f"verb-trace-{leg}.txt"]
        # THE SCENE'S OWN SECOND ACT, and the door this lane opens for it
        # (docs/tasks-s9-plan.md R6): a `relaunch` with no door named is
        # a leg that would wait out its ceiling for a tap nobody makes.
        two_act = relaunch_count(script_text) > 0
        door = lane.RELAUNCH_DOOR.get(scene)
        if two_act and door not in ("notify_tap", "launch", "link"):
            die(f"run-emulator: {scene}.steps carries a `relaunch` and "
                f"lanes/android.py names its door {door!r}; this runner "
                f"opens \"notify_tap\", \"launch\" and \"link\" and nothing "
                f"else")
        if door and not two_act:
            die(f"run-emulator: lanes/android.py names a relaunch door "
                f"for {scene}, whose scene script has no `relaunch`")
        queue_leg(leg, selftest,
                  (apk, component, selftest, extras, remount_expect,
                   two_act),
                  tablet=bool(flags.get("tablet")))
    drain()
    check_real_prefs(suite, package,
                     [*SERIALS, TABLET_SERIAL] if suite == "compose"
                     else list(SERIALS))
    timing(f"legs-{suite}")


for _suite in lane.SUITES:
    if SUITE not in (_suite, "all"):
        continue
    if ONLY and not selected_legs(_suite):
        continue
    if not build_suite(_suite):
        sys.exit(1)
    run_suite_legs(_suite)

if ONLY and _selected == 0:
    die(f"run-emulator: KAYA_ONLY={ONLY!r} matched no leg of "
        f"{'every suite' if SUITE == 'all' else SUITE} — a filter that "
        f"selects nothing would print a verdict over a run of nothing")

# Suites accumulate failures rather than abort, so a truncated log must
# still end with the answer: a killed lane otherwise reads exactly like
# a complete one, which is how an ios run that reached no leg at all was
# read as a pass (2026-08-29). tools/check-gates.py holds all five
# runners to this.
exclusive.summary("android")
if ONLY:
    print(f"run-emulator: filtered run — KAYA_ONLY={ONLY}, {_selected} leg(s)")
print(f"run-emulator: the core's own diagnostics reached logcat on "
      f"{CORE_DIAG['seen']} of {CORE_DIAG['legs']} answered leg(s)")
if CORE_DIAG["legs"] and not CORE_DIAG["seen"]:
    print(f"run-emulator: FAIL — no leg's logcat carried `{CORE_DIAG_LINE}`: the "
          f"core's stderr bridge (crates/kaya/src/android.rs) is dead and every "
          f"KAYA_DIAG on this lane went to /dev/null again (docs/traps.md "
          f"2026-09-11)")
    status = 1
if status == 0:
    print("run-emulator: ALL PASS")
else:
    print("run-emulator: FAILURES ABOVE")
sys.exit(status)
