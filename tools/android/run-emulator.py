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
import tomllib

from lanes import android as lane
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
# pool device is 320dp wide, an unambiguously COMPACT window, and
# Material shows two panes only at 840dp — so nothing else in this lane
# observes the list-detail SPLIT arm, and a wrong one compiled and
# passed everything.
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
# how long after an injection ends before the next is allowed. Three
# tries at ~1.5s each fit inside the verb's own 20s ack ceiling.
DRAG_INJECT_TRIES = 3
DRAG_INJECT_RETRY_S = 2.0


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
_torn = threading.Lock()


def kaya_teardown():
    if not _torn.acquire(blocking=False):
        return
    FR.flush()
    shutil.rmtree(LEGS_DIR, ignore_errors=True)
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


KAYA_IDENTITY_MANIFEST = ROOT / "guests/assets/identity.toml"
if not KAYA_IDENTITY_MANIFEST.is_file():
    die(f"run-emulator: {KAYA_IDENTITY_MANIFEST} is missing — the app "
        f"identity is declared there and the APK reads its icon and "
        f"label from it (docs/app-identity-plan.md ruling 4)")
ICON_REL = tomllib.loads(KAYA_IDENTITY_MANIFEST.read_text(
    encoding="utf-8")).get("icon")
if not isinstance(ICON_REL, str) or not ICON_REL.strip():
    die(f"run-emulator: {KAYA_IDENTITY_MANIFEST} declares no `icon`, "
        f"so there is no mark to push to any device")
# Derived rather than retyped: apk_icon_verify hashes it against what
# gradle packaged.
ICON_SRC = ROOT / ICON_REL


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
               remount_expect, log, rebooted=False):
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
                              extras, remount_expect, log, rebooted=True)
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
    for _ in range(120):
        dump = out_of(["timeout", "10", "adb", "-s", serial, "logcat",
                       "-d", "-s", "kaya:*"])
        m = re.search(r"^.*KAYA_SELFTEST: (?:OK|FAILED).*$", dump, re.M)
        if m:
            out = m.group(0)
            break
        acked = set(re.findall(r"KAYA_ACK: draganddrop (\d+)", dump))
        starts = len(re.findall(r"KAYA_DRAG_STARTED: draganddrop", dump))
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
            began = time.monotonic()
            rc = run(["timeout", "60", "adb", "-s", serial, "shell",
                      "input", "draganddrop", *point],
                     stdout=log, stderr=log).returncode
            served[seq] = (tries + 1, time.monotonic(),
                           starts_at if tries else starts)
            print(f"{name}: draganddrop #{seq} try {tries + 1} "
                  f"{' '.join(point)} -> rc={rc} in "
                  f"{int((time.monotonic() - began) * 1000)}ms", file=log)
        time.sleep(0.5)
    print(out, file=log)
    if "KAYA_SELFTEST: FAILED" in out and served:
        # The drag WATCH's instrument, beside the injections: every drag
        # event the app saw, so "drag ended none" under a matrix says which
        # target the pointer entered and where the drop landed.
        for line in re.findall(r"^.*KAYA_DRAG_EVENT: .*$", dump, re.M):
            print(f"{name}: {line.split('KAYA_DRAG_EVENT: ', 1)[1]}", file=log)
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
        dur = out_of(["ffprobe", "-v", "quiet", "-show_entries",
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
    _leg_names.append(name)
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
    """THE PHONE-EXPRESSIBLE PREFIX of a shared scene: everything above
    the CUT VERB. THE SHARED FILE STAYS BYTE-FROZEN — the prefix is its
    own bytes, and the steps this lane did NOT run are printed. THE TWO
    WAYS A CUT GOES QUIET, BOTH REFUSED: the cut verb leaving the scene
    (the cut is then stale), and the cut swallowing the very assertion
    the leg exists for — so the KEEP VERBS are mandatory and compared
    against the WHOLE file. `verb=target` holds one HANDLE's
    assertions; buying the same-verb drop costs an EXTRA that
    re-asserts the verb in its always-true-here form. THE iOS LANE
    TAKES THE SAME LIST AND THE SAME GRAMMAR — two mobile lanes, one
    question, and two answers is how lanes drift."""
    path = ROOT / f"tools/scenes/{scene}.steps"
    keeps = keep.split()
    if not keeps:
        die(f"run-emulator: cutting {path} at `{cut}` with no `keep` "
            f"verb — say which assertions this cut may not take with "
            f"it, or the leg can be trimmed until it asserts nothing")
    lines = [line.strip() for line in
             path.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    verbs = [(line.split() or [""])[0] for line in lines]
    if cut not in verbs:
        die(f"run-emulator: {path} has no `{cut}` step, so this lane's "
            f"cut is stale — the scene was reshaped and nobody re-read "
            f"what the phone can express. Fix the leg, do not widen "
            f"the cut.")
    at = verbs.index(cut)
    prefix, dropped = lines[:at], lines[at:]

    def asserted(seq, verb, target=None):
        return {" ".join(line.split()) for line in seq
                if (p := line.split()) and p[0] == verb
                and (target is None or (len(p) > 1 and p[1] == target))}

    extra_verbs = {(line.split() or [""])[0]
                   for line in extra.splitlines()}
    for tok in keeps:
        verb, _, target = tok.partition("=")
        whole = asserted(lines, verb, target or None)
        kept = asserted(prefix, verb, target or None)
        if not kept:
            die(f"run-emulator: cutting {path} at `{cut}` leaves no "
                f"`{tok}` step at all — the leg would pass without "
                f"asserting the thing it exists for")
        if kept != whole:
            die(f"run-emulator: cutting {path} at `{cut}` drops "
                f"{sorted(whole - kept)} — the cut may not take an "
                f"assertion of `{tok}` with it")
        if target and asserted(dropped, verb) and verb not in extra_verbs:
            die(f"run-emulator: cutting {path} at `{cut}` takes "
                f"`{verb}` assertions the targeted keep `{tok}` does "
                f"not hold, and the leg's extra asserts no `{verb}` — "
                f"re-assert it there or hold them with the keep")
    for line in dropped:
        print(f"run-emulator: NOT RUN on this host (after `{cut}`): "
              f"{line}", file=sys.stderr)
    return ";".join(prefix) + ";"


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
    print(f"run-emulator: drop_block refused {reds} bad drops", flush=True)


drop_block_selftest()


def scene_script_drop(scene, specs, keep, why):
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
    block, which is the same `drag_file` cut (docs/dnd-plan.md D9)."""
    path = ROOT / f"tools/scenes/{scene}.steps"
    lines = [" ".join(line.split()) for line in
             path.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    try:
        kept, gone = drop_block(lines, specs, keep)
    except ValueError as e:
        die(f"run-emulator: {path}: {e}")
    for line in gone:
        print(f"run-emulator: NOT RUN on this host ({why}): {line}",
              file=sys.stderr)
    return ";".join(kept) + ";"


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
            specs, keep, why = mods["drop"]
            text = scene_script_drop(scene, specs, keep, why)
        else:
            text = scene_script(scene)
        _scripts[scene] = text + mods.get("append", "")
    return _scripts[scene]


for _scene in sorted({lane.scene_of(_leg) for _leg in lane.legs()}):
    script_for(_scene)


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
    """The bytes INSIDE the apk gradle just wrote against the bytes
    guests/assets/identity.toml declares. HERE AND NOT IN A GATE, so the
    wall is on the path nobody can avoid (invariant 3). The entry name
    is android/build.gradle.kts's, which pins isCrunchPngs = false so
    aapt cannot re-encode behind this."""
    if run(["unzip", "-l", str(apk), "res/mipmap/kaya_mark.png"],
           stdout=subprocess.DEVNULL,
           stderr=subprocess.DEVNULL).returncode != 0:
        print(f"run-emulator: {apk} carries no res/mipmap/kaya_mark.png "
              f"— the app", file=sys.stderr)
        print("  identity's picture never reached the package, so its "
              "launcher icon", file=sys.stderr)
        print("  is whatever Android draws for an app that declares "
              "none", file=sys.stderr)
        print(f"  (android/build.gradle.kts is the reader; {ICON_REL} "
              f"is the source)", file=sys.stderr)
        return False
    declared = hashlib.sha256(ICON_SRC.read_bytes()).hexdigest()
    packaged_bytes = subprocess.run(
        ["unzip", "-p", str(apk), "res/mipmap/kaya_mark.png"],
        stdout=subprocess.PIPE, check=False).stdout
    packaged = hashlib.sha256(packaged_bytes).hexdigest()
    if declared != packaged:
        print(f"run-emulator: the mark inside {apk} is not the declared "
              f"one.", file=sys.stderr)
        print(f"  declared ({ICON_REL}): {declared}", file=sys.stderr)
        print(f"  packaged (res/mipmap/kaya_mark.png): {packaged}",
              file=sys.stderr)
        print("  One picture is the picture on all five platforms "
              "(ruling 1); two", file=sys.stderr)
        print("  readers that disagree is the failure ruling 4 exists "
              "to prevent.", file=sys.stderr)
        return False
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
    if not apk_assets_verify(apk):
        return False
    if suite != "compose":
        timing(f"build-{suite}")
    targets = ([*SERIALS, TABLET_SERIAL] if suite == "compose"
               else list(SERIALS))
    return stage_suite_apk(suite, apk, package, targets)


def run_suite_legs(suite):
    """Every leg from the lane module's roster, in its order, one drain
    at the end. The bare suite legs launch with KAYA_SELFTEST=1 (the
    unprefixed milestone2 arm); everything else passes its scene name.
    The tablet leg, the remount legs and the per-leg extras are
    lanes/android.py's FLAGS."""
    apk_rel, package, activity = lane.SUITE_APPS[suite]
    apk = ROOT / apk_rel
    component = f"{package}/{activity}"
    for leg in lane.suite_legs(suite):
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
        queue_leg(leg, selftest,
                  (apk, component, selftest, extras, remount_expect),
                  tablet=bool(flags.get("tablet")))
    drain()
    timing(f"legs-{suite}")


for _suite in lane.SUITES:
    if SUITE not in (_suite, "all"):
        continue
    if not build_suite(_suite):
        sys.exit(1)
    run_suite_legs(_suite)

# Suites accumulate failures rather than abort, so a truncated log must
# still end with the answer: a killed lane otherwise reads exactly like
# a complete one, which is how an ios run that reached no leg at all was
# read as a pass (2026-08-29). tools/check-gates.py holds all five
# runners to this.
if status == 0:
    print("run-emulator: ALL PASS")
else:
    print("run-emulator: FAILURES ABOVE")
sys.exit(status)
