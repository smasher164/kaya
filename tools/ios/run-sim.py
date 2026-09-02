#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Build, install, and self-test the scenes in the iOS Simulator.
# Usage: tools/ios/run-sim.sh [swift|go|python|rust-swiftui|all]
#
# rust-swiftui - the Rust examples with the SwiftUI backend selected at
#                runtime (dylib embedded in the bundle)
# swift        - Swift over the C ABI function floor
# go           - Go over the same floor, cross-built with GOOS=ios and
#                owning the process main thread
# python       - CPython embedded in one bundle carrying every python
#                scene (docs/python-mobile-plan.md)
#
# The scene lists, declared-off lists and per-leg modifiers are DATA:
# tools/lib/lanes/ios.py, the one source the gates import too
# (docs/runner-conversion-plan.md §2, stage 2).
#
# The split/panels scenes are desktop-only BY DESIGN and deliberately
# not legs here: split drives resize_window, and a phone or tablet host
# does not command its own window size (the system owns surfaces;
# DESIGN.md, Windows); panels' create_window is capability-rejected on
# this host. The declared-off lists carry both.
#
# Requires full Xcode (simctl, the iOS SDK, and a downloaded simulator
# runtime); simulator builds are unsigned, so no developer account is
# involved.

import atexit
import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import tomllib
import urllib.parse

from lanes import ios as lane
import flightrec_lane

SELF = pathlib.Path(__file__).resolve()

TEXT = {"text": True, "encoding": "utf-8", "errors": "replace"}


def run(argv, **kw):
    return subprocess.run(argv, check=False, **kw)


def out_of(argv, timeout_s=None, env=None, stdin_text=None):
    """Captured stdout of a command (stderr dropped, as the shell's
    2>/dev/null captures were), decoded permissively — guest-origin
    text is not clean UTF-8 (docs/traps.md, "NOT UTF-8").

    INTO A FILE, NEVER A PIPE: `simctl spawn` hands the child's stdout
    to the simulator's launchd, which keeps the write end after simctl
    itself has exited, and a pipe read to EOF then waits on a launchd
    that answers nothing — the iOS lane hung 30 minutes on
    `launchctl list` that way, 0 legs (2026-09-01, docs/traps.md). A
    file has no other end to wait for, and every spawn here is
    bounded by `timeout` besides."""
    argv = (["timeout", str(timeout_s), *argv] if timeout_s else list(argv))
    with tempfile.NamedTemporaryFile(prefix="kaya-out-", delete=False) as tf:
        out_path = pathlib.Path(tf.name)
    try:
        with open(out_path, "w", encoding="utf-8") as out:
            subprocess.run(argv, stdout=out, stderr=subprocess.DEVNULL,
                           input=stdin_text, env=env, check=False, **TEXT)
        return out_path.read_text(encoding="utf-8", errors="replace")
    finally:
        out_path.unlink(missing_ok=True)


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


# Compile the ios target and typecheck the Swift guest before the
# simulator is involved.
for gate_cmd in ([str(ROOT / "tools/check-targets.sh"), "ios"],
                 [str(ROOT / "tools/swift-typecheck.sh")]):
    if run(gate_cmd).returncode != 0:
        sys.exit(1)

SUITE = sys.argv[1] if len(sys.argv) > 1 else "all"
if SUITE not in (*lane.SUITES, "all"):
    die(f"run-sim: unknown suite {SUITE!r} (one of: "
        f"{', '.join((*lane.SUITES, 'all'))})")

# The active developer dir may still be the Command Line Tools (simctl
# and the iOS SDK live only in Xcode); point at Xcode without sudo.
if run(["xcrun", "simctl", "help"], stdout=subprocess.DEVNULL,
       stderr=subprocess.DEVNULL).returncode != 0:
    for app in sorted(pathlib.Path("/Applications").glob("Xcode*.app")):
        if (app / "Contents/Developer").is_dir():
            os.environ["DEVELOPER_DIR"] = str(app / "Contents/Developer")
            break

TARGET_DIR = ROOT / "target/aarch64-apple-ios-sim/debug"
BUNDLES = ROOT / "target/ios-bundles"
# THE RESIDENT XCUITEST DRIVER (tools/ios/xcuidrive/KayaDrive.swift says
# what it is and why it is a test): built once per run into BUNDLES,
# started once per pool device right after the boot, proven before the
# first leg by xcuidrive_proof, stopped in cleanup.
XCUIDRIVE_SRC = ROOT / "tools/ios/xcuidrive"
XCUIDRIVE_BUILD = ROOT / "target/ios-xcuidrive"
# NOT under dev.kaya.: device preparation uninstalls every dev.kaya. app
# and refuses any that remains, and the driver is installed by xcodebuild
# while that runs (measured 2026-09-02, the first run of this driver).
XCUIDRIVE_RUNNER_ID = "dev.kayalane.drive.runner"
IOS_MIN = "16.0"
os.chdir(ROOT)

# The swift and rust-swiftui suites compile against kaya.h and the
# generated Swift bindings; fail loudly if either has drifted.
for gen in ("gen-header", "gen-bindings"):
    if run([str(ROOT / f"tools/{gen}.sh"), "--check"]).returncode != 0:
        sys.exit(1)


def built_tool(rel):
    """A host-side helper's path, from its own build.sh (in-toolchain
    launcher shapes stay shell; docs/runner-conversion-plan.md §6)."""
    got = subprocess.run([str(ROOT / rel)], stdout=subprocess.PIPE,
                         check=False, **TEXT)
    path = got.stdout.strip().splitlines()[-1] if got.stdout.strip() else ""
    if got.returncode != 0 or not path:
        die(f"run-sim: {rel} failed to produce its tool")
    return path


# The admission probe's app, built ONCE per run and before any leg. It
# exercises the LocalStorage export path itself (docs/traps.md records
# why a live FileProvider pid is not enough); the hands that drive its
# sheet are the resident xcui driver's (xcuidrive_build, below), which
# replaced the host-side simdrive walker and the spawned clipctl
# process on 2026-09-02 (docs/xcuidrive-plan.md).
EXPORT_PROBE_APP = built_tool("tools/ios/exportprobe/build.sh")
EXPORT_PROBE_BUNDLE = "dev.kaya.exportpreflight"
KAYA_BUNDLE_PREFIX = "dev.kaya."

# WHERE EACH DIALOG LEG'S SIMDRIVE TIMING LANDS, and deliberately NOT
# in LEGS_DIR: that directory is deleted on exit, and a GREEN run's
# numbers are the healthy baseline a starved run is read against
# (docs/deferred.md's iOS-sheets WATCH entry). Cleared per run.
SIMDRIVE_LOG_DIR = ROOT / "target/ios-simdrive-logs"
shutil.rmtree(SIMDRIVE_LOG_DIR, ignore_errors=True)
SIMDRIVE_LOG_DIR.mkdir(parents=True)


def now_ms():
    return int(time.time() * 1000)


# THE DECLARED APP IDENTITY, READ ONCE, FROM THE ONE PLACE IT IS
# WRITTEN (docs/app-identity-plan.md ruling 4) — never retyped;
# check-app-identity C6 holds this file to it.
KAYA_IDENTITY_MANIFEST = ROOT / "guests/assets/identity.toml"
if not KAYA_IDENTITY_MANIFEST.is_file():
    die(f"run-sim: {KAYA_IDENTITY_MANIFEST} is missing — the app identity "
        f"is declared there and this lane's bundles read their icon and "
        f"display name from it (docs/app-identity-plan.md ruling 4)")
_decl = tomllib.loads(KAYA_IDENTITY_MANIFEST.read_text(encoding="utf-8"))
for _key in ("icon", "name"):
    if not isinstance(_decl.get(_key), str) or not _decl[_key].strip():
        die(f"run-sim: {KAYA_IDENTITY_MANIFEST} declares no `{_key}`, so "
            f"the bundles this lane assembles would carry half an identity")
ICON_REL = _decl["icon"]
IDENTITY_NAME = _decl["name"]
ICON_SRC = ROOT / ICON_REL
ICON_IN_BUNDLE = pathlib.Path(ICON_REL).name
if not ICON_SRC.is_file():
    die(f"run-sim: the declared app mark {ICON_REL} is missing from this "
        f"tree")

# THE ASSET ROOT, INTO EVERY BUNDLE. This is the one lane where staging
# and PACKAGING are the same act: an iOS app resolves its resources out
# of its own bundle (docs/assets-plan.md A4's iOS row and A5.3).
#
# NO KAYA_ASSET_DIR HERE, AND THAT IS THE POINT: the core asks
# `Bundle.main` for its resource directory before it falls back to
# anything (crates/kaya/src/assets.rs, route 2). If the bundle copy
# stops happening the guest gets the core's miss sentence, not a stale
# file. THE WHOLE ROOT, not the files a scene happens to want (A5.1).
# AND ONE FILE UNDER IT IS DERIVED, never committed
# (guests/assets/market/README.md).
if run([sys.executable, str(ROOT / "tools/gen-market.py"),
        "--ensure"]).returncode != 0:
    print("run-sim: python3 tools/gen-market.py --ensure failed — the "
          "market", file=sys.stderr)
    print("  family's transactions.csv is derived, so every bundle this "
          "lane", file=sys.stderr)
    print("  assembles would carry an incomplete asset root",
          file=sys.stderr)
    sys.exit(1)
ASSET_SRC = ROOT / "guests/assets"
if not ASSET_SRC.is_dir():
    die(f"run-sim: the asset root {ASSET_SRC} is missing — every bundle "
        f"this lane assembles carries it, and a guest calling asset() "
        f"would get the core's miss sentence on every leg")


def verify_bundle_assets(src, dst, leg):
    """What arrived is what was sent, by hash: the local copy cannot
    half-land the way a push over adb can, but it CAN copy a stale tree
    if the destination was not cleared."""
    def digest(f):
        return hashlib.sha256(f.read_bytes()).hexdigest()
    here = {f.relative_to(src).as_posix(): digest(f)
            for f in sorted(src.rglob("*")) if f.is_file()}
    there = {f.relative_to(dst).as_posix(): digest(f)
             for f in sorted(dst.rglob("*")) if f.is_file()}
    if not here:
        die(f"run-sim: the tree's asset root is empty, so the {leg} "
            f"bundle's copy would agree with anything")
    bad = [f"  {n}: " + ("never arrived" if n not in there
                         else f"is {there[n][:12]}, the tree has {h[:12]}")
           for n, h in sorted(here.items()) if there.get(n) != h]
    bad += [f"  {n}: is in the bundle and not in the tree"
            for n in sorted(set(there) - set(here))]
    if bad:
        print(f"run-sim: the {leg} bundle's asset root does not match the "
              f"tree:", file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        sys.exit(1)


def make_bundle(name, bundle_id, executable_path, identity=""):
    """One .app: Info.plist from the template, the asset root, the
    executable. A non-empty `identity` puts the declared identity into
    THIS bundle — OPT-IN AND NOT GLOBAL: `expect_app_icon` reads this
    artifact and holds it equal to what the guest declared over the
    wire, so a bundle carrying an identity its guest never declared
    would let the read report one for an app with no declaration."""
    app = BUNDLES / f"{name}.app"
    shutil.rmtree(app, ignore_errors=True)
    app.mkdir(parents=True)
    icon_keys = ""
    if identity:
        shutil.copy2(ICON_SRC, app / ICON_IN_BUNDLE)
        icon_keys = ICON_IN_BUNDLE
    tpl = (ROOT / "tools/ios/Info.plist.in").read_text(encoding="utf-8")
    # The icon file name carries its extension in the bundle and NOT in
    # CFBundleIconFiles: iOS matches the entry against the bundle root
    # by base name, which is what lets one entry stand for the @2x/@3x
    # family an asset catalog would emit.
    block = "" if not icon_keys else (
        "<key>CFBundleDisplayName</key>\n"
        f"    <string>{IDENTITY_NAME}</string>\n"
        "    <key>CFBundleIcons</key>\n"
        "    <dict>\n"
        "        <key>CFBundlePrimaryIcon</key>\n"
        "        <dict>\n"
        "            <key>CFBundleIconFiles</key>\n"
        "            <array>\n"
        f"                <string>{icon_keys.rsplit('.', 1)[0]}</string>\n"
        "            </array>\n"
        "        </dict>\n"
        "    </dict>")
    (app / "Info.plist").write_text(
        tpl.replace("@EXECUTABLE@", name).replace("@BUNDLE_ID@", bundle_id)
           .replace("@NAME@", name).replace("@IDENTITY@", block),
        encoding="utf-8")
    shutil.copytree(ASSET_SRC, app / "assets")
    verify_bundle_assets(ASSET_SRC, app / "assets", name)
    shutil.copy2(executable_path, app / name)
    return app


# A pool of dedicated simulators (kaya-sim-0..N-1, KAYA_IOS_SIMS wide)
# runs the legs in parallel; devices are created on first use, stay
# booted across runs, and never touch the user's own simulators. One
# iPad alongside, for one reason: the phone pool is ALWAYS a compact
# horizontal size class, so nothing else in this lane observes the
# regular-width lowering. Form-factor coverage, not device-matrix
# breadth.
POOL = int(os.environ.get("KAYA_IOS_SIMS", "3"))
UDIDS = []
PAD_UDID = ""


def device_of(name, dtype, runtime):
    """Resolve a pool device by name, RECREATING it if its type has
    drifted: a device created under a different selector or Xcode keeps
    its old type forever, so the pool silently goes heterogeneous. For
    the iPad it is worse than flaky — a stale kaya-sim-pad of the wrong
    type makes the form-factor gate VACUOUS while still reporting
    PASS."""
    listing = out_of(["xcrun", "simctl", "list", "devices"])
    udid = ""
    for line in listing.splitlines():
        if f"{name} (" in line:
            m = re.search(r"[0-9A-F-]{36}", line)
            udid = m.group(0) if m else ""
            break
    if udid:
        devices = json.loads(
            out_of(["xcrun", "simctl", "list", "devices", "-j"]) or "{}")
        have = ""
        for devs in devices.get("devices", {}).values():
            for x in devs:
                if x.get("udid") == udid:
                    have = x.get("deviceTypeIdentifier", "")
        if have != dtype:
            print(f"recreating {name}: type drifted ({have} != {dtype})",
                  file=sys.stderr)
            run(["xcrun", "simctl", "delete", udid],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            udid = ""
    if not udid:
        udid = out_of(["xcrun", "simctl", "create", name, dtype,
                       runtime]).strip()
    return udid


def boot_pool():
    global PAD_UDID
    # simctl lists device types NEWEST FIRST, so `head -1` is the
    # newest and `tail -1` the oldest. The phone selector below says
    # "newest" and takes the tail, which resolves to an iPhone 11 Pro —
    # a real (pre-existing) mismatch between its comment and its
    # behavior. Left alone deliberately: changing the phone changes the
    # screen size every geometry expectation in this lane was frozen
    # against, so it wants its own slice with a full iOS re-validation.
    # Do not copy the tail idiom.
    types = out_of(["xcrun", "simctl", "list", "devicetypes"])
    phone_lines = [ln for ln in types.splitlines()
                   if re.search(r"iPhone [0-9]+ Pro \(", ln)]
    m = (re.search(r"com.apple.CoreSimulator.SimDeviceType[^)]*",
                   phone_lines[-1]) if phone_lines else None)
    dtype = m.group(0) if m else ""
    # Large iPad Pro: unambiguously a regular width in full screen. The
    # trailing `(com` keeps the "(16GB)" memory variants out.
    pad_lines = [ln for ln in types.splitlines()
                 if re.search(r"iPad Pro [0-9]+-inch \(M[0-9]+\) \(com", ln)]
    m = (re.search(r"com.apple.CoreSimulator.SimDeviceType[^)]*",
                   pad_lines[0]) if pad_lines else None)
    pad_dtype = m.group(0) if m else ""
    m = re.search(r"com.apple.CoreSimulator.SimRuntime.iOS[0-9-]+",
                  out_of(["xcrun", "simctl", "list", "runtimes"]))
    runtime = m.group(0) if m else ""
    if not dtype or not runtime:
        die("no iPhone device type / iOS runtime; install one in Xcode")
    if not pad_dtype:
        die("no M-series iPad Pro device type; install one in Xcode")
    for i in range(POOL):
        udid = device_of(f"kaya-sim-{i}", dtype, runtime)
        run(["xcrun", "simctl", "boot", udid], stderr=subprocess.DEVNULL)
        UDIDS.append(udid)
    PAD_UDID = device_of("kaya-sim-pad", pad_dtype, runtime)
    run(["xcrun", "simctl", "boot", PAD_UDID], stderr=subprocess.DEVNULL)
    for udid in [*UDIDS, PAD_UDID]:
        # Bounded: bootstatus blocks forever on a wedged device.
        if run(["timeout", "180", "xcrun", "simctl", "bootstatus", udid,
                "-b"], stdout=subprocess.DEVNULL).returncode != 0:
            die(f"simulator {udid} did not boot within 180s")


# ------------------------------------------------------------ recording
# Recording mode (KAYA_RECORD=1): ONE suite-long recording per
# simulator contains every leg in sequence — per-leg start/stop WEDGES
# (the device-side session of a stopped recording lingers and later
# recorders fail with "Host recording is already in progress"). Each
# leg notes its launch anchor; extraction happens after the recorder
# stops. recordVideo's own clock is unrecoverable from either end, so a
# per-device FIDUCIAL (an appearance flip, stamped when the flip is
# VISIBLE) anchors film time to wall time. The flip is an EDGE, never
# an absolute level: the home screen's icon tiles held "dark" at YAVG
# ~107, so an absolute test concluded the flip never rendered while
# staring at it (measured delta 68; threshold 25).
REC_ROOT = ROOT / "target/recordings/ios"
REC_RUN = ""
REC_PIDS = []
T_MARKS = {}
L_MARKS = {}
REC_DIRS = {}


def _luma_of(png):
    got = out_of(["ffprobe", "-v", "quiet", "-f", "lavfi",
                  f"movie={png},signalstats", "-show_entries",
                  "frame_tags=lavfi.signalstats.YAVG", "-of", "csv=p=0"])
    first = got.splitlines()[0] if got.splitlines() else ""
    return int(first.split(".")[0]) if first.split(".")[0].isdigit() else None


def _await_flip(udid, base, down, rec_i):
    probe = REC_ROOT / ".flip-probe.png"
    for _ in range(50):
        run(["xcrun", "simctl", "io", udid, "screenshot", str(probe)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        luma = _luma_of(probe)
        if luma is not None and (
                luma <= base - 25 if down else luma >= base + 25):
            return True
        time.sleep(0.2)
    word = "dark" if down else "light"
    print(f"recording: {word} fiducial never rendered on device {rec_i} "
          f"(base {base})", file=sys.stderr)
    return False


def rec_suite_start(retry=False):
    global REC_RUN
    if not os.environ.get("KAYA_RECORD"):
        return
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        die("recording mode needs ffmpeg/ffprobe — run inside nix develop")
    if run([str(ROOT / "tools/harness-extract.sh"),
            "--selftest"]).returncode != 0:
        sys.exit(1)
    REC_ROOT.mkdir(parents=True, exist_ok=True)
    # A STAMP rather than a wipe: `run-sim.sh swift` must not delete
    # the rust-swiftui suite's films; this run's legs carry its id and
    # extraction ignores everything else.
    REC_RUN = f"{os.getpid()}-{int(time.time())}"
    for stale in REC_ROOT.iterdir():
        if stale.is_dir() and not (stale / "run").is_file():
            shutil.rmtree(stale, ignore_errors=True)
    REC_PIDS.clear()
    for i, udid in enumerate(UDIDS):
        log = open(REC_ROOT / f"rec-{i}.log", "w", encoding="utf-8")
        p = subprocess.Popen(
            ["xcrun", "simctl", "io", udid, "recordVideo", "--codec",
             "h264", "--force", str(REC_ROOT / f"suite-{i}.mov")],
            stdout=log, stderr=log)
        REC_PIDS.append(p)
    time.sleep(2)
    wedged = any("already in progress" in
                 (REC_ROOT / f"rec-{i}.log").read_text(encoding="utf-8",
                                                       errors="replace")
                 for i in range(len(UDIDS))
                 if (REC_ROOT / f"rec-{i}.log").is_file())
    if wedged and not retry:
        # A killed prior run orphans host-side recording sessions; the
        # remedy is known and mechanical: reset the simulator service,
        # reboot the pool, try once more.
        print("recording: stale simctl sessions; resetting "
              "CoreSimulatorService and retrying")
        for p in REC_PIDS:
            p.kill()
        run(["killall", "-9",
             "com.apple.CoreSimulator.CoreSimulatorService"],
            stderr=subprocess.DEVNULL)
        time.sleep(3)
        UDIDS.clear()
        boot_pool()
        rec_suite_start(retry=True)
        return
    if wedged:
        die("recording: sessions still wedged after a service reset; "
            "giving up")
    # simctl announces capture in its own log ("Recording started") and
    # the output file stays ZERO bytes until finalize; flipping the
    # fiducial before the announcement films neither edge.
    for i in range(len(UDIDS)):
        for tries in range(76):
            text = (REC_ROOT / f"rec-{i}.log").read_text(
                encoding="utf-8", errors="replace")
            if "Recording started" in text:
                break
            if tries == 75:
                die(f"recording: recorder {i} never announced "
                    f"'Recording started'")
            time.sleep(0.4)
    # The pool's appearance is whatever the previous run left behind,
    # and a drop edge cannot fire from a dark base: normalize to light
    # first; this pre-flip is never stamped.
    for udid in UDIDS:
        run(["xcrun", "simctl", "ui", udid, "appearance", "light"])
    time.sleep(2)
    probe = REC_ROOT / ".flip-probe.png"
    for i, udid in enumerate(UDIDS):
        run(["xcrun", "simctl", "io", udid, "screenshot", str(probe)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        base = _luma_of(probe) or 175
        run(["xcrun", "simctl", "ui", udid, "appearance", "dark"])
        if not _await_flip(udid, base, down=True, rec_i=i):
            sys.exit(1)
        T_MARKS[i] = now_ms()
        (REC_ROOT / f"t_mark-{i}").write_text(f"{T_MARKS[i]}\n",
                                              encoding="utf-8")
    # The flip BACK is a second fiducial: a recorder that attaches
    # mid-flip produces a film that OPENS dark, so the dark EDGE is not
    # in it at all. With both edges stamped, extraction anchors on
    # whichever edge the film contains.
    for i, udid in enumerate(UDIDS):
        run(["xcrun", "simctl", "io", udid, "screenshot", str(probe)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        base = _luma_of(probe) or 107
        run(["xcrun", "simctl", "ui", udid, "appearance", "light"])
        if not _await_flip(udid, base, down=False, rec_i=i):
            sys.exit(1)
        L_MARKS[i] = now_ms()
        (REC_ROOT / f"l_mark-{i}").write_text(f"{L_MARKS[i]}\n",
                                              encoding="utf-8")
    time.sleep(1)
    probe.unlink(missing_ok=True)


def _film_edge_ms(movie, down):
    """The first frame whose average luma steps by 25 in the wanted
    direction; its presentation time in ms is the fiducial edge. The
    whole stream is read (the shell drained it for pipefail's sake)."""
    got = out_of(["ffprobe", "-v", "quiet", "-f", "lavfi",
                  f"movie={movie},select=gt(scene\\,0.3),signalstats",
                  "-show_entries",
                  "frame=pts_time:frame_tags=lavfi.signalstats.YAVG",
                  "-of", "csv=p=0"])
    prev = None
    for line in got.splitlines():
        parts = line.strip().split(",")
        if len(parts) < 2:
            continue
        try:
            pts, luma = float(parts[0]), float(parts[1])
        except ValueError:
            continue
        if prev is not None and (luma <= prev - 25 if down
                                 else luma >= prev + 25):
            return int(pts * 1000)
        prev = luma
    return None


def rec_suite_stop():
    if not os.environ.get("KAYA_RECORD"):
        return True
    # simctl itself must receive the SIGINT to finalize each file, and
    # the xcrun wrapper does not forward signals — hit the children
    # first, then the wrapper, bounded.
    for p in REC_PIDS:
        run(["pkill", "-INT", "-P", str(p.pid)], stderr=subprocess.DEVNULL)
        try:
            p.send_signal(signal.SIGINT)
        except OSError:
            print("recording: a recorder was already gone", file=sys.stderr)
    for p in REC_PIDS:
        try:
            p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            p.kill()
    anchors = {}
    for i in range(len(UDIDS)):
        movie = REC_ROOT / f"suite-{i}.mov"
        t_flip = _film_edge_ms(movie, down=True)
        if t_flip is not None:
            anchors[i] = T_MARKS[i] - t_flip
        else:
            t_flip = _film_edge_ms(movie, down=False)
            if t_flip is None:
                print(f"recording: no fiducial edge in suite-{i}.mov")
                return False
            anchors[i] = L_MARKS[i] - t_flip
        (REC_ROOT / f"anchor-{i}").write_text(f"{anchors[i]}\n",
                                              encoding="utf-8")
    # Each leg extracts from the film of the simulator it ran on.
    failed = False
    threads = []
    results = {}

    def _extract(dirp, slot):
        log = dirp / "extract.log"
        with open(log, "w", encoding="utf-8") as lf:
            rc = run([str(ROOT / "tools/harness-extract.sh"),
                      str(REC_ROOT / f"suite-{slot}.mov"),
                      str(dirp / "leg.log"), str(anchors[slot]),
                      str(dirp / "steps")],
                     stdout=lf, stderr=subprocess.STDOUT).returncode
        results[dirp] = rc == 0

    for dirp in REC_ROOT.iterdir():
        if not (dirp / "leg.log").is_file():
            continue
        if (dirp / "run").read_text(encoding="utf-8").strip() != REC_RUN:
            continue
        slot_text = ((dirp / "sim").read_text(encoding="utf-8").strip()
                     if (dirp / "sim").is_file() else "0")
        t = threading.Thread(target=_extract,
                             args=(dirp, int(slot_text or "0")))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    for dirp, ok in sorted(results.items()):
        log = dirp / "extract.log"
        if log.is_file():
            print(log.read_text(encoding="utf-8", errors="replace"),
                  end="")
        if not ok:
            failed = True
    if failed:
        print("recording: extraction failures above")
        return False
    return True


def rec_start(name, slot):
    # The pad is NOT filmed: the fiducial scheme indexes films by
    # phone-pool slot and the pad has none — a pad leg is a state gate,
    # not a visual record (the shell body unset KAYA_RECORD there).
    if not os.environ.get("KAYA_RECORD") or slot == "pad":
        return
    rec_dir = REC_ROOT / name
    rec_dir.mkdir(parents=True, exist_ok=True)
    # Which simulator's film covers this leg, and which run recorded it.
    (rec_dir / "sim").write_text(f"{slot}\n", encoding="utf-8")
    (rec_dir / "run").write_text(f"{REC_RUN}\n", encoding="utf-8")
    REC_DIRS[name] = rec_dir


def rec_finish(name, out):
    if not os.environ.get("KAYA_RECORD") or name not in REC_DIRS:
        return
    # The transcript's own epoch line anchors the leg inside its
    # simulator's recording; nothing to measure here.
    (REC_DIRS[name] / "leg.log").write_text(out + "\n", encoding="utf-8")


# ------------------------------------------------------------ clipboard
# THE CLIPBOARD SCENE'S FOREIGN SIDE, ON THE HOST: iOS has no child
# processes, so the interpreter cannot run the foreign tools the mac
# arm runs. Both directions are a SPAWNED PROCESS on the device
# (tools/ios/clipctl), never a simctl pasteboard tool, and the macOS
# pasteboard is never in the path — every rule here was measured
# (docs/clipboard-plan.md §8).



def clip_decode(b64):
    return base64.b64decode(b64)


def clip_encode(data):
    return base64.b64encode(data).decode()


def clip_press(udid):
    """Answer the per-clip paste prompt, or report there was none — an
    own-content read never raises one, so "none" is an answer. Pressed
    until the press verb FAILS (nothing carries the label), because the
    alert leaving the screen is the only proof a tap landed. None means
    the alert never left; the caller carries the sentence to the guest.
    The press is the driver's, on SpringBoard's tree — the one that is
    always readable while the app's own blocked read holds the alert
    (docs/clipboard-plan.md §8 finding 2)."""
    did = False
    for _ in range(6):
        ok, _body = xcuidrive(udid, "press Allow Paste", timeout=20)
        if not ok:
            return "pressed" if did else "none"
        did = True
    return None


def clip_seed(udid, kind, b64, legs_dir):
    """Put content on the device clipboard FROM OUTSIDE the guest: the
    resident driver writes it, as another principal. THE WRITER IS
    ALIVE FOR THE WHOLE LANE by construction — the pasteboard daemon
    serves item DATA by fetching it from the setter, and a writer that
    exits at once left a reader empty 1-in-5 (docs/clipboard-plan.md
    §8 finding 6); the spawned holder processes, their release files
    and their census that this replaced are gone with the need."""
    if kind in ("text", "html"):
        payload = b64
    elif kind == "image":
        path = pathlib.Path(clip_decode(b64).decode("utf-8", "replace"))
        if not path.is_file():
            return None, f"the image seed's file is missing: {path}"
        payload = clip_encode(path.read_bytes())
    elif kind == "files":
        path = pathlib.Path(clip_decode(b64).decode("utf-8", "replace"))
        if not path.is_file():
            return None, f"the files seed's file is missing: {path}"
        payload = b64
    else:
        return None, f"clipboard_seed cannot write {kind} from outside " \
                     f"the app"
    ok, body = xcuidrive(udid, f"pb_write {kind} {payload}")
    if not ok:
        return None, f"the driver refused the {kind} seed on {udid}: {body}"
    if "types=" not in body:
        return None, f"the {kind} seed never reported its write on {udid}"
    return "ok", ""


def clip_read(udid, kind_b64, legs_dir):
    """Read the device clipboard back FROM OUTSIDE the guest, in one
    representation, answering what expect_clipboard compares. The
    driver reads it off its own test thread and presses the paste
    prompt itself (a foreign clip prompts per clip, §8 finding 2), so
    the read and its remedy no longer race across two processes."""
    kind = clip_decode(kind_b64).decode("utf-8", "replace")
    if not kind:
        return None, "clip_read needs a kind"
    ok, body = xcuidrive(udid, f"pb_read {kind}", timeout=40)
    if not ok:
        return None, body
    # THE MISSING LINE IS THE DIAGNOSIS: a kind the board does not
    # carry still prints an EMPTY `S b64=`; no line at all means the
    # read never returned — an unanswered prompt, not an empty board.
    m = re.search(r"^S b64=(.*)$", body, re.M)
    if m is None:
        tm = re.search(r"^S types=.*$", body, re.M)
        return None, (f"the {kind} read returned no data line; the "
                      f"board offered {tm.group(0) if tm else ''}")
    b64 = m.group(1)
    if kind == "image":
        # TWO OF APPLE'S TOOLS, the mac arm's own answer: sips reports
        # the DECODED SIZE. WxH rather than a byte count, because every
        # host re-encodes freely.
        if not b64:
            return "", ""
        png = legs_dir / f"clipread-{udid}.png"
        png.write_bytes(clip_decode(b64))
        sized = out_of(["sips", "-g", "pixelWidth", "-g", "pixelHeight",
                        str(png)])
        size = dict(re.findall(r"^\s+(pixelWidth|pixelHeight):\s*(\d+)",
                               sized, re.M))
        answer = (f"{size['pixelWidth']}x{size['pixelHeight']}"
                  if len(size) == 2 else "")
        return clip_encode(answer.encode()), ""
    if kind == "files":
        # BASENAMES, never paths: the expected string is compared byte
        # for byte across lanes whose containers are at different
        # paths.
        names = []
        for line in clip_decode(b64).decode("utf-8",
                                            "replace").splitlines():
            if line:
                parsed = urllib.parse.urlparse(line)
                names.append(os.path.basename(
                    urllib.parse.unquote(parsed.path.rstrip("/"))))
        return clip_encode("\n".join(names).encode()), ""
    # text, html and any custom id ARE their own answer.
    return b64, ""


def clip_relay_check(a, b):
    """THE DEVICE PASTEBOARD IS NOT ALWAYS THE DEVICE'S: Simulator.app's
    Automatically Sync Pasteboard relays the macOS pasteboard into and
    out of every booted simulator (measured 2026-08-03: a host-side
    copy replaced a booted device's clip in 260ms). So MEASURE isolation
    before any leg: two devices, two different clips, each keeping its
    own — types only, which is prompt-free (§8 finding 2). Through the
    two devices' drivers, which are up before this runs."""
    xcuidrive(a, f"pb_write html {clip_encode(b'<b>kaya relay check</b>')}")
    xcuidrive(b, f"pb_write text {clip_encode(b'kaya relay check')}")
    seen_a = seen_b = ""
    for _ in range(3):
        time.sleep(1)
        ok_a, seen_a = xcuidrive(a, "pb_types")
        ok_b, seen_b = xcuidrive(b, "pb_types")
        if not ok_a or not ok_b:
            seen_a = seen_a if ok_a else ""
            seen_b = seen_b if ok_b else ""
            continue
        shared = ("public.html" not in seen_a) or ("public.html" in seen_b)
        if not shared:
            continue
        print("the simulator clipboards are NOT separate boards:",
              file=sys.stderr)
        print(f"  {a} offers {seen_a}", file=sys.stderr)
        print(f"  {b} offers {seen_b}", file=sys.stderr)
        print("Simulator.app is relaying the macOS pasteboard into every "
              "booted", file=sys.stderr)
        print("simulator (Edit > Automatically Sync Pasteboard, on by "
              "default).", file=sys.stderr)
        print("The clipboard legs cannot run against a board the mac lane",
              file=sys.stderr)
        print("rewrites throughout the matrix. Quit Simulator.app — this "
              "lane", file=sys.stderr)
        print("boots its devices headless with simctl and never needs it "
              "— or", file=sys.stderr)
        print("turn that menu item off, or run", file=sys.stderr)
        print("  defaults write com.apple.iphonesimulator "
              "PasteboardAutomaticSync -bool NO", file=sys.stderr)
        print("and RELAUNCH it: a running Simulator.app reads that pref "
              "only at", file=sys.stderr)
        print("launch. Then re-run.", file=sys.stderr)
        return False
    if not seen_a or not seen_b:
        print(f"the relay check could not read a clipboard on {a} / {b}",
              file=sys.stderr)
        return False
    return True

# --------------------------------------------------------------- picker
# THE FIRST PICKER A DEVICE SHOWS AFTER A BOOT OPENS IN THE WRONG
# DIRECTORY (docs/traps.md): the app's reveal races DocumentManager's
# own default-location strategy, and whichever lands LAST wins
# (measured 2026-08-03: first picker on boot lands at the ROOT every
# time; any picker after that at the asked-for directory). So WARM THE
# STACK before any leg with the system's own Files app; the device says
# when it is done — com.apple.FileProvider carries no pid until
# something on that boot has used the document stack.

def doc_daemon_pid(udid):
    got = out_of(["xcrun", "simctl", "spawn", udid, "launchctl", "list"])
    for line in got.splitlines():
        parts = line.rstrip("\n").split("\t")
        if (len(parts) >= 3 and parts[2] == "com.apple.FileProvider"
                and parts[0].isdigit()):
            return parts[0]
    return ""


def picker_warm(udid):
    if doc_daemon_pid(udid):
        return True
    if run(["timeout", "60", "xcrun", "simctl", "launch", udid,
            "com.apple.DocumentsApp"], stdout=subprocess.DEVNULL,
           stderr=subprocess.DEVNULL).returncode != 0:
        print(f"the stock Files app would not launch on {udid} — this "
              f"lane warms the", file=sys.stderr)
        print("document stack with it so the filedialog scene's first "
              "picker opens", file=sys.stderr)
        print("where it was aimed (docs/traps.md). Check the runtime has",
              file=sys.stderr)
        print(f"com.apple.DocumentsApp: xcrun simctl listapps {udid}",
              file=sys.stderr)
        return False
    for _ in range(80):
        if doc_daemon_pid(udid):
            break
        time.sleep(0.25)
    if not doc_daemon_pid(udid):
        print(f"the file provider daemon never came up on {udid} after "
              f"launching Files", file=sys.stderr)
        return False
    # The daemon answering is the edge; the local-storage tree fills in
    # behind it. Measured: the resolution the picker waits on drops
    # 708ms -> 294ms across this pause.
    time.sleep(3)
    run(["timeout", "60", "xcrun", "simctl", "terminate", udid,
         "com.apple.DocumentsApp"], stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    return True


def kaya_installed_apps(udid):
    listing = out_of(["timeout", "60", "xcrun", "simctl", "listapps",
                      udid])
    converted = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", "--", "-"],
        input=listing, stdout=subprocess.PIPE, check=False, **TEXT)
    try:
        apps = json.loads(converted.stdout)
    except ValueError:
        apps = None
    if not isinstance(apps, dict) or not apps:
        print(f"run-sim: could not census installed apps on {udid}",
              file=sys.stderr)
        return None
    return [b for b in sorted(apps) if b.startswith(KAYA_BUNDLE_PREFIX)]


def picker_cleanup(udid):
    bundles = kaya_installed_apps(udid)
    if bundles is None:
        return False
    removed = 0
    for bundle in bundles:
        if not bundle.startswith("dev.kaya."):
            print(f"run-sim: refusing to uninstall non-kaya app {bundle} "
                  f"from {udid}", file=sys.stderr)
            return False
        if run(["timeout", "60", "xcrun", "simctl", "uninstall", udid,
                bundle], stdout=subprocess.DEVNULL,
               stderr=subprocess.DEVNULL).returncode != 0:
            print(f"run-sim: could not uninstall prior-run app {bundle} "
                  f"from {udid}", file=sys.stderr)
            return False
        removed += 1
    remaining = kaya_installed_apps(udid)
    if remaining is None:
        return False
    if remaining:
        print(f"run-sim: prior-run kaya apps remain on {udid} after "
              f"cleanup:", file=sys.stderr)
        print("\n".join(remaining), file=sys.stderr)
        return False
    print(f"run-sim: removed {removed} prior-run kaya app(s) from {udid}")
    return True


def picker_export_probe(udid):
    """0 healthy, 75 the measured LocalStorage failure, 76 the flow that
    did not finish in time (a slow host, not a stale export — the two
    read alike under matrix load, and the second erased a healthy
    device twice, 2026-09-01), 1 otherwise."""
    probe_name = f"kaya-export-preflight-{os.getpid()}-{now_ms()}"
    run(["timeout", "60", "xcrun", "simctl", "terminate", udid,
         EXPORT_PROBE_BUNDLE], stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    if run(["timeout", "60", "xcrun", "simctl", "install", udid,
            EXPORT_PROBE_APP], stdout=subprocess.DEVNULL,
           stderr=subprocess.DEVNULL).returncode != 0:
        print(f"run-sim: the LocalStorage export probe would not install "
              f"on {udid}", file=sys.stderr)
        return 1
    container = out_of(["timeout", "60", "xcrun", "simctl",
                        "get_app_container", udid, EXPORT_PROBE_BUNDLE,
                        "data"]).strip()
    if not container:
        print(f"run-sim: the LocalStorage export probe has no data "
              f"container on {udid}", file=sys.stderr)
        return 1
    result_file = pathlib.Path(container) / \
        "Library/Caches/kaya-export-preflight-result"
    ready_file = pathlib.Path(container) / \
        "Library/Caches/kaya-export-preflight-ready"
    result_file.unlink(missing_ok=True)
    ready_file.unlink(missing_ok=True)
    started = time.strftime("%Y-%m-%d %H:%M:%S%z")
    launch = subprocess.run(
        ["timeout", "60", "xcrun", "simctl", "launch", udid,
         EXPORT_PROBE_BUNDLE],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env=dict(os.environ,
                 SIMCTL_CHILD_KAYA_EXPORT_NAME=probe_name),
        check=False, **TEXT)
    if launch.returncode != 0:
        print(f"run-sim: the LocalStorage export probe would not launch "
              f"on {udid}: {launch.stdout}", file=sys.stderr)
        return 1
    pid = ""
    for line in reversed(launch.stdout.splitlines()):
        m = re.search(r":\s*([0-9]+)\s*$", line)
        if m:
            pid = m.group(1)
            break
    if not pid:
        print(f"run-sim: the LocalStorage export probe launch named no "
              f"pid on {udid}: {launch.stdout}", file=sys.stderr)
        return 1
    for _ in range(240):
        if ready_file.is_file() and ready_file.stat().st_size:
            break
        time.sleep(0.25)
    if not (ready_file.is_file() and ready_file.stat().st_size):
        print(f"run-sim: the LocalStorage export probe never presented "
              f"its picker on {udid} within 60s", file=sys.stderr)
        run(["timeout", "60", "xcrun", "simctl", "terminate", udid,
             EXPORT_PROBE_BUNDLE], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        return 76
    # THE SHEET IS DRIVEN BY THE RESIDENT DRIVER, attached to the probe
    # app: the name typed and read back, Save pressed and the sheet
    # required gone — the verbs the legs use, so admission is the
    # driver's first proof on every run.
    ok, drive_out = xcuidrive(udid, f"attach {EXPORT_PROBE_BUNDLE}")
    if ok:
        ok, drive_out = xcuidrive(udid, f"savename {probe_name}", timeout=90)
    if ok:
        ok, drive_out = xcuidrive(udid, "savepress", timeout=90)
    drive_rc = 0 if ok else 1
    result = ""
    # A drive that failed cannot finish the flow: a short grace for a
    # late result, not the full minute — two slow phones held the
    # admission join 99s past the builds on 2026-09-01's fifth matrix.
    for _ in range(240 if drive_rc == 0 else 20):
        if result_file.is_file() and result_file.stat().st_size:
            result = result_file.read_text(
                encoding="utf-8", errors="replace").splitlines()[0]
            break
        time.sleep(0.25)
    run(["timeout", "60", "xcrun", "simctl", "terminate", udid,
         EXPORT_PROBE_BUNDLE], stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    if result == "ok":
        return 0
    if not result and drive_rc != 0:
        # What the drive said, since its log dies with the run.
        print(f"run-sim: the drive's last words on {udid}: "
              + " | ".join(drive_out.strip().splitlines()[-3:]),
              file=sys.stderr)
        # The flow never finished: nothing here says the export is
        # stale, only that the host was slow. The log below may well
        # carry an FP -1005 from the Files app's own warm-up, which is
        # what made this read as 75 and erase a healthy device.
        print(f"run-sim: the LocalStorage export probe did not finish on "
              f"{udid} (drive rc={drive_rc}); a slow host, not a verdict",
              file=sys.stderr)
        return 76
    logq = subprocess.run(
        ["timeout", "30", "xcrun", "simctl", "spawn", udid, "log",
         "show", "--style", "compact", "--start", started, "--predicate",
         'eventMessage CONTAINS "FP -1005" OR eventMessage CONTAINS '
         '"Index out of sync" OR eventMessage CONTAINS '
         '"didPickDocumentURLs called with nil or 0 URLS"'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        **TEXT)
    system_log = (logq.stdout if logq.returncode == 0 else
                  f"log query failed with rc={logq.returncode}: "
                  f"{logq.stdout}")
    haystack = f"{result}:{system_log}"
    if (result == "empty" or "FP -1005" in haystack
            or "Index out of sync" in haystack
            or "didPickDocumentURLs called with nil or 0 URLS"
            in haystack):
        print(f"run-sim: LocalStorage export health failed on {udid} "
              f"({result})", file=sys.stderr)
        if system_log:
            print(system_log, file=sys.stderr)
        return 75
    print(f"run-sim: LocalStorage export probe failed on {udid}",
          file=sys.stderr)
    print(f"  result={result or 'missing'} drive_rc={drive_rc} "
          f"drive={drive_out or '<empty>'}", file=sys.stderr)
    if system_log:
        print(system_log, file=sys.stderr)
    return 1


def picker_reseed(udid):
    xcuidrive_stop(udid)
    run(["timeout", "60", "xcrun", "simctl", "shutdown", udid],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for argv, t in ((["xcrun", "simctl", "erase", udid], "180"),
                    (["xcrun", "simctl", "boot", udid], "60"),
                    (["xcrun", "simctl", "bootstatus", udid, "-b"],
                     "180")):
        if run(["timeout", t, *argv], stdout=subprocess.DEVNULL,
               stderr=subprocess.DEVNULL).returncode != 0:
            return False
    # The device is new; so is its driver.
    xcuidrive_start(udid)
    return _drive_results.get(udid, "").startswith("ready in")


def picker_prepare(udid):
    if not picker_cleanup(udid):
        return 1
    if not picker_warm(udid):
        return 1
    rc = picker_export_probe(udid)
    if rc == 76:
        # Once more before any verdict: the first attempt's slowness is
        # the host's, and the second reads the device it left warm
        # (check-steps holds this to ONE re-run on that code alone).
        print(f"run-sim: re-probing {udid} after a slow export flow",
              file=sys.stderr)
        rc = picker_export_probe(udid)
    if rc == 0:
        return 0
    if rc != 75:
        return rc
    print(f"run-sim: reseeding {udid} after a stale LocalStorage export",
          file=sys.stderr)
    if not picker_reseed(udid) or not picker_warm(udid):
        return 1
    rc = picker_export_probe(udid)
    if rc == 76:
        print(f"run-sim: re-probing {udid} after a slow export flow on "
              f"the reseeded device", file=sys.stderr)
        rc = picker_export_probe(udid)
    if rc == 0:
        return 0
    if rc == 75:
        print(f"run-sim: LocalStorage export stayed unhealthy after "
              f"reseeding {udid} once", file=sys.stderr)
    return 1


# ------------------------------------------------------ simdrive watch
def clip_verb(udid, parts):
    """The clipboard verbs, dispatched off the request line's tokens.
    Returns (rc, body)."""
    verb = parts[0]
    if verb == "clip_seed":
        got, err = clip_seed(udid, parts[1] if len(parts) > 1 else "",
                             parts[2] if len(parts) > 2 else "", LEGS_DIR)
    elif verb == "clip_read":
        got, err = clip_read(udid, parts[1] if len(parts) > 1 else "",
                             LEGS_DIR)
    elif verb == "clip_press":
        got = clip_press(udid)
        err = "the paste alert is still up after 6 presses" \
            if got is None else ""
    else:
        return 1, f"unknown clipboard verb {verb}"
    if got is None:
        return 1, err
    return 0, got


def simdrive_watch(udid, bundle_id, docs_dir, log_path, stop):
    """Answer the guest's simdrive requests for the life of one leg.
    The protocol is two files: the guest writes `kaya-simdrive-request`
    holding one verb, this writes `kaya-simdrive-response` whose FIRST
    LINE is ok/err — written aside and RENAMED, atomic, so a guest
    reading mid-write keeps waiting rather than acting on half an
    answer. The app's pid is resolved per request: simdrive needs it to
    tell the picker's process from the app's, and the app is launched
    after this starts. This thread captures simdrive's whole output as
    the response the guest parses; the timing side channel is the log
    file KAYA_SIMDRIVE_LOG names (docs/deferred.md's iOS-sheets WATCH
    entry)."""
    docs = pathlib.Path(docs_dir)
    request = docs / "kaya-simdrive-request"
    response = docs / "kaya-simdrive-response"
    docs.mkdir(parents=True, exist_ok=True)
    request.unlink(missing_ok=True)
    response.unlink(missing_ok=True)
    attached = False
    with open(log_path, "a", encoding="utf-8") as lg:
        lg.write(f"KAYA_SIMDRIVE: at={now_ms()} src=watch ev=watch_start "
                 f"clock=epochrealtime app={bundle_id}\n")
        lg.flush()
        while not stop.is_set():
            if request.is_file():
                verb = request.read_text(encoding="utf-8",
                                         errors="replace").strip()
                request.unlink(missing_ok=True)
                parts = verb.split()
                started = now_ms()
                pid, pid_ms = "", "none"
                if parts and parts[0].startswith("clip_"):
                    rc, body = clip_verb(udid, parts)
                else:
                    # THE PICKER VERBS GO TO THE DEVICE'S DRIVER, attached
                    # to this leg's app on the first ask (the app is
                    # launched after this watcher starts); re-attached if
                    # a verb finds no app, since a leg's app is one bundle.
                    pid_started = now_ms()
                    ok = attached
                    if not ok:
                        ok, body = xcuidrive(udid, f"attach {bundle_id}")
                        attached = ok
                        pid = "attached" if ok else "unattached"
                    pid_ms = str(now_ms() - pid_started)
                    if attached:
                        ok, body = xcuidrive(udid, verb, timeout=90)
                        if not ok and "no app attached" in body:
                            attached = False
                    rc = 0 if ok else 1
                lg.write(f"KAYA_SIMDRIVE: at={now_ms()} src=watch "
                         f"ev=request verb={parts[0] if parts else ''} "
                         f"rc={rc} ms={now_ms() - started} "
                         f"pid_ms={pid_ms} pid={pid or 'none'}\n")
                lg.flush()
                part = docs / "kaya-simdrive-response.part"
                part.write_text(
                    ("ok\n" if rc == 0 else "err\n") + body + "\n",
                    encoding="utf-8")
                part.rename(response)
            time.sleep(0.05)


# --------------------------------------------- scene script transforms
def scene_script_cut(scene, cut, keep, extra):
    """THE PHONE-EXPRESSIBLE PREFIX: everything above the first `cut`
    verb, both quiet failure modes refused — a cut verb the scene no
    longer has is STALE, and the cut may not take the assertions the
    leg exists for (`keep`, a list; `verb=target` holds one target's
    and buys the same-verb drop only if the extra re-asserts that verb).
    The dropped steps are PRINTED."""
    path = ROOT / f"tools/scenes/{scene}.steps"
    keeps = keep.split()
    if not keeps:
        die(f"run-sim: cutting {path} at `{cut}` with no `keep` verb — "
            f"say which assertions this cut may not take with it, or the "
            f"leg can be trimmed until it asserts nothing")
    lines = [line for line in
             path.read_text(encoding="utf-8").splitlines()
             if not line.lstrip().startswith("#")]
    verbs = [(line.split() or [""])[0] for line in lines]
    if cut not in verbs:
        die(f"run-sim: {path} has no `{cut}` step, so this lane's cut is "
            f"stale — the scene was reshaped and nobody re-read what the "
            f"phone can express. Fix the leg, do not widen the cut.")
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
            die(f"run-sim: cutting {path} at `{cut}` leaves no `{tok}` "
                f"step at all — the leg would pass without asserting the "
                f"thing it exists for")
        if kept != whole:
            die(f"run-sim: cutting {path} at `{cut}` drops "
                f"{sorted(whole - kept)} — the cut may not take an "
                f"assertion of `{tok}` with it")
        if target and asserted(dropped, verb) and verb not in extra_verbs:
            die(f"run-sim: cutting {path} at `{cut}` takes `{verb}` "
                f"assertions the targeted keep `{tok}` does not hold, "
                f"and the leg's extra asserts no `{verb}` — re-assert it "
                f"there or hold them with the keep")
    for line in dropped:
        if line.strip():
            print(f"run-sim: NOT RUN on this host (after `{cut}`): {line}",
                  file=sys.stderr)
    return "\n".join(prefix)


def scene_script_drop(scene, verb, target, keep):
    """DROP ONE STEP, not a suffix — for a step out of reach on this
    host while everything AFTER it is expressible. The same two guards
    the cut carries: a drop that matches no step is STALE, and the
    `keep` verbs name the assertions the drop may not take with it."""
    path = ROOT / f"tools/scenes/{scene}.steps"
    keeps = keep.split()
    if not keeps:
        die(f"run-sim: dropping `{verb} {target}` from {path} with no "
            f"`keep` verb — say which assertions this drop may not take "
            f"with it, or the leg can be trimmed until it asserts "
            f"nothing")
    lines = [" ".join(line.split()) for line in
             path.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    hits = [i for i, line in enumerate(lines)
            if line.split()[:2] == [verb, target]]
    if len(hits) != 1:
        die(f"run-sim: {path} has {len(hits)} `{verb} {target}` steps "
            f"and this lane drops exactly one — the scene was reshaped "
            f"and nobody re-read what the phone can express. Fix the "
            f"leg, do not widen the drop.")
    kept = lines[:hits[0]] + lines[hits[0] + 1:]

    def asserted(seq, v):
        return {line for line in seq if line.split()[:1] == [v]}

    for v in keeps:
        whole, survived = asserted(lines, v), asserted(kept, v)
        if not survived:
            die(f"run-sim: dropping `{verb} {target}` from {path} leaves "
                f"no `{v}` step at all — the leg would pass without "
                f"asserting the thing it exists for")
        if survived != whole:
            die(f"run-sim: dropping `{verb} {target}` from {path} takes "
                f"{sorted(whole - survived)} — the drop may not take an "
                f"assertion of `{v}` with it")
    print(f"run-sim: NOT RUN on this host (no auxiliary windows): "
          f"{lines[hits[0]]}", file=sys.stderr)
    return "\n".join(kept)


# ------------------------------------------------------------- the leg
def run_swiftui_on(udid, slot, app, bundle_id, name, selftest, scene,
                   extra="", cut="", keep="", drop_verb="", drop_target="",
                   appearance="", log=None):
    """Install the bundle on the claimed simulator and launch with the
    scene script from the environment. The picker/clipboard scenes get
    the simdrive watcher — THE HARNESS'S EYES AND HANDS OUTSIDE THIS
    APP: iOS's document picker is a remote view controller whose UI
    belongs to another process, and the clipboard's foreign side cannot
    run in-process at all; both meet the guest through files in the
    app's own data container (docs/traps.md). Started per leg and
    killed with it."""
    if cut and drop_verb:
        print(f"run-sim: {name} asks for both a cut at `{cut}` and a "
              f"drop of `{drop_verb} {drop_target}` — pick one", file=log)
        return False
    run(["xcrun", "simctl", "install", udid, str(app)],
        stdout=log, stderr=log)
    container = out_of(["xcrun", "simctl", "get_app_container", udid,
                        bundle_id, "app"]).strip()
    rec_start(name, slot)
    if cut:
        script = scene_script_cut(scene, cut, keep, extra)
    elif drop_verb:
        script = scene_script_drop(scene, drop_verb, drop_target, keep)
    else:
        script = "\n".join(
            line for line in (ROOT / f"tools/scenes/{scene}.steps")
            .read_text(encoding="utf-8").splitlines()
            if not line.startswith("#"))
    if extra:
        script = f"{script}\n{extra}"
    watcher_stop = None
    watcher = None
    simdrive_log = None
    if scene in ("filedialog", "clipboard", "save", "editor"):
        data_container = out_of(["xcrun", "simctl", "get_app_container",
                                 udid, bundle_id, "data"]).strip()
        simdrive_log = SIMDRIVE_LOG_DIR / f"{name}.log"
        simdrive_log.write_text("", encoding="utf-8")
        watcher_stop = threading.Event()
        watcher = threading.Thread(
            target=simdrive_watch,
            args=(udid, bundle_id, f"{data_container}/Documents",
                  simdrive_log, watcher_stop))
        watcher.start()
    # NO MARK IS STAGED FOR THE GUEST: the identity guest names the mark
    # as an asset and the core resolves it out of THIS BUNDLE'S OWN
    # Resources; `expect_app_icon` decodes the icon-keys copy
    # make_bundle wrote from the manifest — two files, two steps, held
    # equal by the interpreter (ruling 4).
    env = dict(os.environ,
               SIMCTL_CHILD_KAYA_SELFTEST=selftest,
               SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT=script,
               SIMCTL_CHILD_KAYA_SWIFTUI_LIB=(
                   f"{container}/libkaya_swiftui.dylib"))
    # THE HARNESS APPEARANCE, when the leg asks for one: a simulator
    # child sees only SIMCTL_CHILD_-prefixed variables. Unset adds no
    # variable at all, which is what keeps every other leg
    # byte-identical to before.
    if appearance:
        env["SIMCTL_CHILD_KAYA_APPEARANCE"] = appearance
    # THE VERB TRACE AND THE PANIC LOG, both RELATIVE names: the
    # interpreter resolves one under its Documents and the core the
    # other under $HOME/Documents — the same container directory —
    # because this runner cannot name the container before the launch
    # without a simctl call on every passing leg. Both are written on a
    # failure alone and pulled below (crates/kaya/src/vtrace.rs,
    # fault.rs's KAYA_PANIC_LOG).
    env["SIMCTL_CHILD_KAYA_VERB_TRACE"] = f"verb-trace-{name}.txt"
    env["SIMCTL_CHILD_KAYA_PANIC_LOG"] = f"panic-{name}.txt"
    got = subprocess.run(
        ["timeout", "120", "xcrun", "simctl", "launch", "--console-pty",
         udid, bundle_id],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
        check=False, **TEXT)
    out = got.stdout
    if watcher is not None:
        watcher_stop.set()
        watcher.join()
    print(out, file=log)
    rec_finish(name, out)
    # (NO PER-LEG SCREENSHOT: `--console-pty` returns only when the
    # guest EXITS, so any capture here photographs the home screen.
    # KAYA_RECORD=1 is the visual record.)
    ok = "KAYA_SELFTEST: OK" in out
    if not ok:
        pull_container_files(udid, bundle_id, name, log)
    if simdrive_log is not None:
        # THE NUMBERS GO WHERE THE LANE'S OTHER FAILURE EVIDENCE GOES:
        # target/ios-simdrive-logs is cleared by the NEXT run, and the
        # sighting this family needs is a rerun away.
        lines = (len(simdrive_log.read_text(
            encoding="utf-8", errors="replace").splitlines())
            if simdrive_log.is_file() else 0)
        if lines < 1:
            print(f"run-sim: {name} wrote nothing to {simdrive_log} — "
                  f"the watcher never reached its first line, so this "
                  f"leg has no dialog timing at all", file=log)
        elif lines < 2:
            print(f"run-sim: {name} made no simdrive request (only the "
                  f"watcher's own line is in {simdrive_log}): either the "
                  f"scene never reached a dialog verb, or the requests "
                  f"never arrived", file=log)
        elif not ok:
            keep_dir = ROOT / "target/validate-failures"
            keep_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(simdrive_log,
                         keep_dir / f"ios-{name}-simdrive.log")
            print(f"== simdrive timing, last 40 of {lines} lines ==",
                  file=log)
            tail = simdrive_log.read_text(
                encoding="utf-8", errors="replace").splitlines()[-40:]
            print("\n".join(tail), file=log)
            print(f"whole simdrive timing log kept at "
                  f"target/validate-failures/ios-{name}-simdrive.log",
                  file=log)
    return ok


def pull_container_files(udid, bundle_id, name, log):
    """A failed leg's verb trace and panic log, copied out of the app's
    data container beside the leg's log for the flight recorder to adopt
    (IosRecorder.ios_leg). FAIL TIME ONLY — the container lookup is a
    simctl call, and the pass path pays nothing."""
    data_container = out_of(["xcrun", "simctl", "get_app_container",
                             udid, bundle_id, "data"]).strip()
    for src_name, suffix in ((f"verb-trace-{name}.txt", ".vtrace"),
                             (f"panic-{name}.txt", ".panic")):
        src = pathlib.Path(data_container) / "Documents" / src_name
        if not src.is_file():
            continue
        dest = (LEGS_DIR / f"{name}.log").with_suffix(suffix)
        shutil.copy2(src, dest)
        print(f"run-sim: {name} kept {src_name} from the app container "
              f"({dest.stat().st_size} bytes)", file=log)


# ------------------------------------------------------ the xcui driver
_drive_procs = {}
_drive_threads = []
_drive_results = {}
_drive_dirs = {}
_drive_serial = {}
_drive_lock = threading.Lock()


def _plist_write(path, value):
    with open(path, "wb") as f:
        plistlib.dump(value, f)


def xcuidrive_build():
    """The test bundle, its runner and the stub target app, by hand: a
    .xctest is a dylib plus an Info.plist, XCTRunner.app is shipped in
    the platform's Agents dir as a template, and xcodebuild's
    test-without-building takes an xctestrun that names them
    (`man 5 xcodebuild.xctestrun`) — no project anywhere. The Swift
    overlay for XCTest lives in the platform's usr/lib, which is why
    the -I/-L pair is there; Testing.framework needs lib_TestingInterop
    beside it or the runner dies at load (measured 2026-09-02)."""
    plat = out_of(["xcrun", "-sdk", "iphonesimulator",
                   "--show-sdk-platform-path"]).strip()
    dev = pathlib.Path(plat) / "Developer"
    build = XCUIDRIVE_BUILD
    shutil.rmtree(build, ignore_errors=True)
    xctest = build / "KayaDrive.xctest"
    xctest.mkdir(parents=True)
    if run(["xcrun", "-sdk", "iphonesimulator", "swiftc", "-target",
            "arm64-apple-ios17.0-simulator", "-parse-as-library",
            "-emit-library", "-module-name", "KayaDrive",
            "-F", str(dev / "Library/Frameworks"),
            "-F", str(dev / "Library/PrivateFrameworks"),
            "-I", str(dev / "usr/lib"), "-L", str(dev / "usr/lib"),
            "-lXCTestSwiftSupport", "-framework", "XCTest",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            "-Xlinker", "-rpath", "-Xlinker", "@loader_path/Frameworks",
            "-o", str(xctest / "KayaDrive"),
            str(XCUIDRIVE_SRC / "KayaDrive.swift")]).returncode != 0:
        return "the xcui driver did not compile (tools/ios/xcuidrive)"
    _plist_write(xctest / "Info.plist", {
        "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": "KayaDrive",
        "CFBundleIdentifier": "dev.kayalane.drive",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "KayaDrive",
        "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "DTPlatformName": "iphonesimulator", "MinimumOSVersion": "17.0",
        "XCTContainsUITests": True})
    target = build / "KayaDriveTarget.app"
    target.mkdir()
    if run(["xcrun", "-sdk", "iphonesimulator", "swiftc", "-target",
            "arm64-apple-ios17.0-simulator", "-parse-as-library",
            "-framework", "UIKit", "-o", str(target / "KayaDriveTarget"),
            str(XCUIDRIVE_SRC / "Target.swift")]).returncode != 0:
        return "the xcui driver's target app did not compile"
    _plist_write(target / "Info.plist", {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "KayaDriveTarget",
        "CFBundleIdentifier": "dev.kayalane.drive.target",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "KayaDriveTarget", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
        "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "DTPlatformName": "iphonesimulator", "LSRequiresIPhoneOS": True,
        "MinimumOSVersion": "17.0", "UIDeviceFamily": [1, 2]})
    runner = build / "KayaDrive-Runner.app"
    shutil.copytree(dev / "Library/Xcode/Agents/XCTRunner.app", runner,
                    symlinks=True)
    (runner / "XCTRunner").rename(runner / "KayaDrive-Runner")
    info = plistlib.loads((runner / "Info.plist").read_bytes())
    info.update(CFBundleExecutable="KayaDrive-Runner",
                CFBundleIdentifier=XCUIDRIVE_RUNNER_ID,
                CFBundleName="KayaDrive-Runner")
    _plist_write(runner / "Info.plist", info)
    shutil.copytree(xctest, runner / "PlugIns/KayaDrive.xctest")
    fw = runner / "Frameworks"
    fw.mkdir()
    # The whole Testing stack, not a hand-picked few: libXCTestSwiftSupport
    # reexports XCTest and links Testing and _Testing_Foundation, Testing
    # links lib_TestingInterop, and a member missing from THIS bundle is
    # resolved from the runtime root by luck on some devices and not
    # others — a driver that loaded standalone died in the pool
    # (measured 2026-09-02). Copying the family closes that.
    for name in ("XCTest", "XCUIAutomation", "Testing",
                 "_Testing_Foundation", "_Testing_CoreGraphics",
                 "_Testing_CoreImage", "_Testing_UIKit"):
        shutil.copytree(dev / f"Library/Frameworks/{name}.framework",
                        fw / f"{name}.framework", symlinks=True)
    for name in ("XCTestCore", "XCTestSupport", "XCTAutomationSupport"):
        shutil.copytree(dev / f"Library/PrivateFrameworks/{name}.framework",
                        fw / f"{name}.framework", symlinks=True)
    for lib in ("libXCTestSwiftSupport.dylib", "libXCTestBundleInject.dylib",
                "lib_TestingInterop.dylib"):
        shutil.copy2(dev / "usr/lib" / lib, fw / lib)
    for argv in (["codesign", "--force", "--sign", "-",
                  str(runner / "PlugIns/KayaDrive.xctest")],
                 ["codesign", "--force", "--sign", "-", "--entitlements",
                  str(runner / "RunnerEntitlements.plist"), str(runner)],
                 ["codesign", "--force", "--sign", "-", str(target)]):
        if run(argv, stdout=subprocess.DEVNULL,
               stderr=subprocess.DEVNULL).returncode != 0:
            return f"codesign failed: {' '.join(argv)}"
    return ""


def xcuidrive_start(udid):
    """One resident driver on one device: its own request dir, its own
    xctestrun, one xcodebuild. Ready when the test's loop has written
    `ready`; a driver that never gets there fails the LANE at prep_join,
    since a lane whose hands are missing must not run legs that assume
    them. Restartable: a reseeded device calls this again and gets a
    fresh directory and result bundle."""
    with _drive_lock:
        _drive_serial[udid] = _drive_serial.get(udid, 0) + 1
        serial = _drive_serial[udid]
    d = DRIVE_DIR / f"{udid}-{serial}"
    d.mkdir(parents=True, exist_ok=True)
    _drive_dirs[udid] = d
    testrun = XCUIDRIVE_BUILD / f"kayadrive-{udid}-{serial}.xctestrun"
    _plist_write(testrun, {"KayaDrive": {
        "TestBundlePath": "__TESTHOST__/PlugIns/KayaDrive.xctest",
        "TestHostPath": "__TESTROOT__/KayaDrive-Runner.app",
        "TestHostBundleIdentifier": XCUIDRIVE_RUNNER_ID,
        "UITargetAppPath": "__TESTROOT__/KayaDriveTarget.app",
        "IsUITestBundle": True, "IsXCTRunnerHostedTestBundle": True,
        "ProductModuleName": "KayaDrive",
        "TestingEnvironmentVariables": {
            "DYLD_FRAMEWORK_PATH": "__TESTROOT__/KayaDrive-Runner.app/Frameworks",
            "DYLD_LIBRARY_PATH": "__TESTROOT__/KayaDrive-Runner.app/Frameworks",
            "KAYA_DRIVE_DIR": str(d)},
        "DependentProductPaths": ["__TESTROOT__/KayaDrive-Runner.app",
                                  "__TESTROOT__/KayaDriveTarget.app"],
        "SystemAttachmentLifetime": "deleteOnSuccess",
        "UserAttachmentLifetime": "deleteOnSuccess"}})
    # xcodebuild reads SDKROOT, and the dev shell's names a nix macOS SDK.
    env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
    with open(d / "xcodebuild.log", "w", encoding="utf-8") as log:
        proc = subprocess.Popen(
            ["xcodebuild", "test-without-building", "-xctestrun",
             str(testrun), "-destination",
             f"platform=iOS Simulator,id={udid}", "-resultBundlePath",
             str(d / "result.xcresult")],
            stdout=log, stderr=subprocess.STDOUT, env=env)
    _drive_procs[udid] = proc
    started = time.monotonic()
    while not (d / "ready").is_file():
        if proc.poll() is not None or time.monotonic() - started > 150:
            tail = (d / "xcodebuild.log").read_text(
                encoding="utf-8", errors="replace").splitlines()[-25:]
            _drive_results[udid] = (
                f"xcodebuild exit={proc.poll()} after "
                f"{int(time.monotonic() - started)}s with no ready file; "
                "last lines:\n" + "\n".join(tail))
            return
        time.sleep(0.2)
    _drive_results[udid] = f"ready in {int(time.monotonic() - started)}s"


def xcuidrive_launch_all():
    """Build once, then one driver per pool device (the pad included),
    each in its own thread; _prep waits for its device's, prep_join for
    all. Started right after the boot, BEFORE admission, since admission
    is the first thing that needs hands (picker_export_probe)."""
    err = xcuidrive_build()
    if err:
        die(f"run-sim: {err}")
    for udid in (*UDIDS, PAD_UDID):
        th = threading.Thread(target=xcuidrive_start, args=(udid,))
        th.start()
        _drive_threads.append(th)


def xcuidrive_wait(udid):
    """Block until this device's driver is ready, or die with what
    xcodebuild said: a lane whose hands are missing must not run a leg
    that assumes them."""
    for _ in range(900):
        got = _drive_results.get(udid, "")
        if got:
            break
        time.sleep(0.2)
    got = _drive_results.get(udid, "never started")
    print(f"run-sim: xcui driver on {udid}: {got.splitlines()[0]}",
          file=sys.stderr, flush=True)
    if not got.startswith("ready in"):
        die(f"run-sim: the xcui driver on {udid} is not serving:\n{got}")


def xcuidrive_join():
    for th in _drive_threads:
        th.join()
    _drive_threads.clear()
    for udid in (*UDIDS, PAD_UDID):
        xcuidrive_wait(udid)


def xcuidrive_stop(udid):
    """One device's driver told to quit, then killed if it lingers."""
    proc = _drive_procs.pop(udid, None)
    if proc is None:
        return
    if proc.poll() is None:
        xcuidrive(udid, "quit", timeout=5)
    deadline = time.monotonic() + 20
    while proc.poll() is None and time.monotonic() < deadline:
        time.sleep(0.1)
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    run(["xcrun", "simctl", "terminate", udid, XCUIDRIVE_RUNNER_ID],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _drive_results.pop(udid, None)


def xcuidrive_census():
    """At the verdict: every pool device's driver is still serving. A
    driver that died mid-run left its later legs without hands, and
    their failures would read as backend bugs."""
    dead = [udid for udid, proc in _drive_procs.items()
            if proc.poll() is not None]
    print(f"run-sim: xcui drivers at the verdict: {len(_drive_procs)} "
          f"started, {len(dead)} dead", flush=True)
    for udid in dead:
        print(f"run-sim: the xcui driver on {udid} exited "
              f"{_drive_procs[udid].returncode} before the verdict",
              file=sys.stderr)
    return not dead


def xcuidrive(udid, verb, timeout=30):
    """One verb to the device's driver: (ok, body)."""
    d = _drive_dirs.get(udid)
    if d is None:
        return False, f"no driver was ever started on {udid}"
    resp = d / "response"
    resp.unlink(missing_ok=True)
    part = d / "request.part"
    part.write_text(verb + "\n", encoding="utf-8")
    part.rename(d / "request")
    started = time.monotonic()
    while not resp.is_file():
        proc = _drive_procs.get(udid)
        if proc is not None and proc.poll() is not None:
            return False, f"the driver on {udid} exited {proc.returncode}"
        if time.monotonic() - started > timeout:
            return False, f"no answer to `{verb}` within {timeout}s"
        time.sleep(0.02)
    lines = resp.read_text(encoding="utf-8").splitlines()
    resp.unlink(missing_ok=True)
    return bool(lines) and lines[0] == "ok", "\n".join(lines[1:])


def _frame_of(body):
    x, y, w, h = (int(v) for v in body.split()[0].split(","))
    return x, y, w, h


def xcuidrive_proof(udid, log, app, bundle_id):
    """A REAL TAP REACHES A REAL KAYA WIDGET AND THE MODEL REACTS, before
    the first leg: the milestone2 guest's `step` button is found by its
    label, tapped at its centre, and the two changes its handler makes —
    the status label to `step 1` and the inserted `Work` group — are read
    back, all through the platform's accessibility, none of it through
    kaya's harness. The linux lane's dragprobe.py, on this lane's terms;
    it was watched failing with the driver answering nothing (a dead
    runner) and with the tap aimed off the button (the label never
    changes). DRAG is not asserted here: a synthetic pan does not move
    kaya's SwiftUI ScrollView (docs/traps.md, the same class as the
    simdrive pan chore), and no draggable widget exists yet — the drag
    verb is proven when the iOS drag arm lands (docs/dnd-plan.md §5)."""
    run(["xcrun", "simctl", "install", udid, str(app)], stdout=log,
        stderr=log)
    run(["xcrun", "simctl", "terminate", udid, bundle_id],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # LIVE, not a self-test: no KAYA_SELFTEST, so the interpreter shows
    # the scene and stays up for the driver to touch. The interpreter
    # dylib is found by absolute path, exactly as a leg's launch does it
    # (run_swiftui_on) — the default leaf-name dlopen does not search the
    # bundle root, so an unset lib is an app that exits at once.
    container = out_of(["xcrun", "simctl", "get_app_container", udid,
                        bundle_id]).strip()
    penv = dict(os.environ,
                SIMCTL_CHILD_KAYA_SWIFTUI_LIB=f"{container}/libkaya_swiftui.dylib")
    if run(["xcrun", "simctl", "launch", udid, bundle_id], stdout=log,
           stderr=log, env=penv).returncode != 0:
        print(f"xcuidrive-proof: {bundle_id} would not launch", file=log)
        return False
    try:
        ok, body = xcuidrive(udid, f"attach {bundle_id}")
        print(f"xcuidrive-proof: attach -> {ok} {body}", file=log)
        if not ok:
            return False
        # The button, by label; retried, since the app was launched a
        # moment ago.
        button = None
        for _ in range(50):
            ok, body = xcuidrive(udid, "find step")
            if ok:
                button = _frame_of(body)
                break
            time.sleep(0.1)
        print(f"xcuidrive-proof: step button -> {ok} {body}", file=log)
        if not ok:
            return False
        bx, by, bw, bh = button
        ok, body = xcuidrive(udid, f"tap {bx + bw // 2} {by + bh // 2}")
        if not ok:
            print(f"xcuidrive-proof: tap -> {body}", file=log)
            return False
        # The two model changes the click makes: the status label and the
        # inserted group. Read back, retried for the transaction to apply.
        for want in ("step 1", "Work"):
            found = False
            for _ in range(30):
                ok, body = xcuidrive(udid, f"find {want}")
                if ok:
                    found = True
                    break
                time.sleep(0.1)
            print(f"xcuidrive-proof: after the tap, find {want!r} -> "
                  f"{ok} {body}", file=log)
            if not found:
                print(f"xcuidrive-proof: the tap did not reach the button "
                      f"({want!r} never appeared)", file=log)
                return False
        print(f"xcuidrive-proof: TAP LANDED on {bundle_id} through the "
              f"resident driver (status became `step 1`, `Work` inserted)",
              file=log)
        return True
    finally:
        run(["xcrun", "simctl", "terminate", udid, bundle_id],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def xcuidrive_stop_all():
    """Every resident runner told to quit, then killed if it lingers,
    then SHOWN gone: a leaked xcodebuild would sit on the pool device
    into the next run."""
    if not _drive_procs:
        return
    count = len(_drive_procs)
    for udid in list(_drive_procs):
        xcuidrive_stop(udid)
    left = subprocess.run(["pgrep", "-fl", "KayaDrive-Runner"],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          check=False, **TEXT).stdout.strip()
    print(f"run-sim: xcui drivers stopped ({count}); runner "
          f"processes left: {left or 'none'}", file=sys.stderr, flush=True)
    _drive_procs.clear()


# ------------------------------------------------------------- the pool
# Legs run in a pool as wide as the simulator pool: each claims a
# device, runs against it, and reports through a verdict file; drain()
# prints in submission order. The iPad's legs are tracked apart from
# the phone pool's — a running pad leg must not count against the
# phone pool's saturation gate.
LEGS_DIR = pathlib.Path(tempfile.mkdtemp())
PREP_DIR = pathlib.Path(tempfile.mkdtemp())
DRIVE_DIR = pathlib.Path(tempfile.mkdtemp())

# THE FLIGHT RECORDER. This lane had none while it was the lane with
# the intermittent legs, so every rerun erased the only evidence; the
# recorder stays (docs/deferred.md's ios-flaky entry). Its python half
# is tools/lib/flightrec_lane.py since the runner conversion.
FR = flightrec_lane.IosRecorder(ROOT)

_dev_slots = list(range(POOL))
_slots_lock = threading.Condition()
_pad_lock = threading.Lock()
_leg_names = []
_leg_threads = []
_pad_threads = []
_prep_results = {}
_prep_threads = []
_prep_joined = False
status = 0


def cleanup():
    xcuidrive_stop_all()
    FR.flush()
    shutil.rmtree(LEGS_DIR, ignore_errors=True)
    shutil.rmtree(PREP_DIR, ignore_errors=True)


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))


def _claim_device():
    with _slots_lock:
        while not _dev_slots:
            _slots_lock.wait()
        return _dev_slots.pop(0)


def _release_device(slot):
    with _slots_lock:
        _dev_slots.append(slot)
        _slots_lock.notify()


def prep_join():
    """Join the backgrounded per-device preparation before ANY leg
    claims a device, then measure clipboard isolation against the final
    device state. Idempotent, so forty calls cost one join."""
    global _prep_joined
    if _prep_joined:
        return
    _prep_joined = True
    _join_started = time.monotonic()
    for t in _prep_threads:
        t.join()
    print(f"run-sim: device preparation joined after waiting "
          f"{int(time.monotonic() - _join_started)}s past the builds",
          file=sys.stderr, flush=True)
    for udid in UDIDS:
        rc = _prep_results.get(udid, "missing")
        if rc != 0:
            die(f"run-sim: device preparation failed (picker-{udid} "
                f"rc={rc})")
    xcuidrive_join()
    if not clip_relay_check(UDIDS[0], PAD_UDID):
        sys.exit(1)


def _leg_worker(name, args, kwargs, pad):
    with open(LEGS_DIR / f"{name}.log", "w", encoding="utf-8",
              errors="replace", buffering=1) as log:
        if pad:
            _pad_lock.acquire()
            udid, slot = PAD_UDID, "pad"
        else:
            slot = _claim_device()
            udid = UDIDS[slot]
        t0 = time.monotonic()
        try:
            ok = run_swiftui_on(udid, slot, *args, log=log, **kwargs)
        finally:
            if pad:
                _pad_lock.release()
            else:
                _release_device(slot)
        secs = int(time.monotonic() - t0)
        (LEGS_DIR / f"{name}.secs").write_text(f"{secs}\n",
                                               encoding="utf-8")
        (LEGS_DIR / f"{name}.verdict").write_text(
            f"{'PASS' if ok else 'FAIL'}\n", encoding="utf-8")


def _proof_worker(name, app, bundle_id):
    with open(LEGS_DIR / f"{name}.log", "w", encoding="utf-8",
              errors="replace", buffering=1) as log:
        slot = _claim_device()
        t0 = time.monotonic()
        try:
            ok = xcuidrive_proof(UDIDS[slot], log, app, bundle_id)
        finally:
            _release_device(slot)
        secs = int(time.monotonic() - t0)
        (LEGS_DIR / f"{name}.secs").write_text(f"{secs}\n",
                                               encoding="utf-8")
        (LEGS_DIR / f"{name}.verdict").write_text(
            f"{'PASS' if ok else 'FAIL'}\n", encoding="utf-8")


def queue_xcuidrive_proof(app, bundle_id):
    """The driver's app-widget proof rides the pool like a leg and
    reports like one (admission is its dialog proof)."""
    prep_join()
    name = "xcuidrive-proof"
    _leg_names.append(name)
    th = threading.Thread(target=_proof_worker, args=(name, app, bundle_id))
    th.start()
    _leg_threads.append(th)


def queue_leg(name, *args, pad=False, **kwargs):
    prep_join()
    _leg_names.append(name)
    # Recording is suppressed on the pad: the fiducial scheme indexes
    # films by phone-pool slot and the pad has none — the pad leg is a
    # state gate, not a visual record. (rec_start is a no-op there
    # because KAYA_RECORD rides the env; the shell unset it in the pad
    # subshell — here the pad's rec_start writes sim="pad" which no
    # extraction slot matches, and leg.log is keyed by the same run, so
    # the extraction skip is by slot. Suppress explicitly instead.)
    if pad:
        t = threading.Thread(target=_leg_worker,
                             args=(name, args, kwargs, True))
        t.start()
        _pad_threads.append(t)
        return
    t = threading.Thread(target=_leg_worker,
                         args=(name, args, kwargs, False))
    t.start()
    _leg_threads.append(t)
    # Watchdog: a wedged pool must die loudly in minutes, not silently
    # absorb tens of legs (the deadlock class this gate once had). No
    # slot freeing for 3 minutes is never legitimate — legs are bounded
    # far tighter.
    spins = 0
    while sum(t.is_alive() for t in _leg_threads) >= len(UDIDS):
        spins += 1
        if spins > 900:
            die(f"pool wedged: {sum(t.is_alive() for t in _leg_threads)} "
                f"legs running, none finishing; "
                f"queued={len(_leg_names)}")
        time.sleep(0.2)


def drain():
    global status
    for t in [*_leg_threads, *_pad_threads]:
        t.join()
    _leg_threads.clear()
    _pad_threads.clear()
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
        print(f"{name}: {verdict} ({secs}s)", flush=True)
        # THE JOURNAL TAKES EVERY LEG, pass or fail: an intermittent
        # leg is only legible against its own history. The BUNDLE is
        # collected on a failure alone.
        FR.ios_leg(name, verdict, 0 if secs == "?" else int(secs),
                   LEGS_DIR / f"{name}.log")
    _leg_names.clear()


_t0 = time.monotonic()


def timing(phase):
    global _t0
    print(f"TIMING {phase} {int(time.monotonic() - _t0)}s", flush=True)
    _t0 = time.monotonic()


# The guests must know they are being filmed: the harness holds its
# window briefly after the last step when recording, and a simulator
# child only sees SIMCTL_CHILD_-prefixed variables.
if os.environ.get("KAYA_RECORD"):
    os.environ["SIMCTL_CHILD_KAYA_RECORD"] = "1"
boot_pool()
xcuidrive_launch_all()
# BEFORE ANY LEG, and on every run: can each phone export and reopen a
# file through LocalStorage? BACKGROUNDED here and JOINED IN queue_leg
# (prep_join): this needs only booted devices, while the build phase
# that follows needs no devices.
for _udid in UDIDS:
    def _prep(u=None):
        # Timed per device: the admission is off the critical path only
        # while it finishes under the swift build it overlaps, and a
        # slow-flow re-probe (76) costs a minute — the 551s iOS lane of
        # 2026-09-01's fourth matrix carried two of them.
        xcuidrive_wait(u)
        _prep_started = time.monotonic()
        _prep_results[u] = picker_prepare(u)
        print(f"run-sim: LocalStorage admission on {u} took "
              f"{int(time.monotonic() - _prep_started)}s (rc="
              f"{_prep_results[u]})", file=sys.stderr, flush=True)
    _t = threading.Thread(target=_prep, kwargs={"u": _udid})
    _t.start()
    _prep_threads.append(_t)
# A recovery erases and reboots one device; recording mode cannot start
# its suite-long sessions until that possibility has been retired.
if os.environ.get("KAYA_RECORD"):
    prep_join()
rec_suite_start()
timing("boot")

SDKROOT_SIM = out_of(["xcrun", "-sdk", "iphonesimulator",
                      "--show-sdk-path"]).strip()

# Clean slate: bundles are derived artifacts with no history worth
# keeping, and a stale main.swift once put the LAYOUT guest inside the
# milestone2 bundle.
shutil.rmtree(BUNDLES, ignore_errors=True)


def cargo_ios(args):
    if run(["cargo", *args],
           env=dict(os.environ, SDKROOT=SDKROOT_SIM)).returncode != 0:
        sys.exit(1)


def verify_built(path):
    if run([str(ROOT / "tools/build-id.sh"), "--verify",
            str(path)]).returncode != 0:
        sys.exit(1)


def build_swiftui_dylib():
    """The one iOS backend is the SwiftUI interpreter: every bundle
    embeds its dylib, whatever language the guest is written in. Always
    built fresh — a stale interpreter under a new guest is the
    stale-artifact class. Same marker contract as the mac dylib
    (tools/swiftui/build-dylib.sh), generated here so this lane does
    not depend on the mac lane having run."""
    BUNDLES.mkdir(parents=True, exist_ok=True)
    marker = BUNDLES / "KayaBuildId.swift"
    swiftui_id = out_of([str(ROOT / "tools/build-id.sh"),
                         "swiftui"]).strip()
    marker.write_text(
        "// Generated by tools/ios/run-sim.py. Do not edit, do not "
        "commit.\n"
        f'public let kayaSwiftUIBuildIdMarker = '
        f'"kaya-build-id:{swiftui_id}"\n', encoding="utf-8")
    if run(["xcrun", "-sdk", "iphonesimulator", "swiftc",
            "-emit-library", "-target", "arm64-apple-ios17.0-simulator",
            "-import-objc-header", "crates/kaya/include/kaya.h",
            "-pch-output-dir", str(BUNDLES / ".pch"),
            "swift/KayaSwiftUI.swift", "swift/KayaSwiftUIEntry.swift",
            str(marker), "-framework", "UIKit", "-framework",
            "Foundation", "-o",
            str(BUNDLES / "libkaya_swiftui_ios.dylib")]).returncode != 0:
        sys.exit(1)
    if run([str(ROOT / "tools/build-id.sh"), "--verify",
            "--component", "swiftui",
            str(BUNDLES / "libkaya_swiftui_ios.dylib")]).returncode != 0:
        sys.exit(1)


def with_dylib(app):
    shutil.copy2(BUNDLES / "libkaya_swiftui_ios.dylib",
                 app / "libkaya_swiftui.dylib")
    return app


def queue_scene_leg(suite, scene, name, app, bundle_id, selftest,
                    scene_arg, pad=False, appearance=""):
    """One leg from the module's tables: the MODS entry supplies the
    cut/drop/keep/extra the leg asserts (tools/lib/lanes/ios.py)."""
    mods = lane.MODS.get((suite, scene), {})
    drop = mods.get("drop", ("", ""))
    extra = lane.PAD_EXTRAS.get(scene, "") if pad else mods.get("extra",
                                                                "")
    queue_leg(name, app, bundle_id, name, selftest, scene_arg,
              extra, mods.get("cut", ""), mods.get("keep", ""),
              drop[0], drop[1], appearance, pad=pad)


def suite_end(phase):
    """The interleave rule (2026-08-20): under `all` the phases
    interleave — draining between families queued the ~75s clipboard
    whales behind each other and the serialization was the whole
    matrix's bound. A single-suite run and recording mode keep the old
    serial shape (a film wants its legs in order)."""
    if SUITE == "all" and not os.environ.get("KAYA_RECORD"):
        timing(f"{phase}-built+queued")
    else:
        drain()
        timing(f"{phase}-build+legs")


if SUITE in ("swift", "all"):
    cargo_ios(["build", "--locked", "--target", "aarch64-apple-ios-sim",
               "--lib"])
    # Every app bundle below links this archive; verify it once, here,
    # rather than trusting the copies downstream.
    verify_built(TARGET_DIR / "libkaya.a")
    build_swiftui_dylib()
    # With more than one input file, swiftc only allows top-level code
    # in a file named main.swift — each scene stages its own. The
    # per-scene compiles are INDEPENDENT so they pool; legs queue only
    # after every binary exists.
    builds = []
    for entry in lane.SWIFT_ENTRIES:
        guest, src = lane.swift_scene(entry)
        stage = BUNDLES / f".stage-{guest}"
        stage.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / f"guests/swift/{src}.swift",
                     stage / "main.swift")
        companions = []
        if (ROOT / f"guests/swift/{src}+Kaya.swift").is_file():
            companions = [f"guests/swift/{src}+Kaya.swift"]
        blog = open(stage / "build.log", "w", encoding="utf-8")
        p = subprocess.Popen(
            ["xcrun", "-sdk", "iphonesimulator", "swiftc", "-target",
             f"arm64-apple-ios{IOS_MIN}-simulator",
             "-import-objc-header", "crates/kaya/include/kaya.h",
             "-pch-output-dir", str(BUNDLES / ".pch"),
             "bindings/swift/KayaWire.swift",
             "bindings/swift/KayaApp.swift",
             "bindings/swift/KayaRecords.swift",
             "bindings/swift/KayaSums.swift",
             *companions, str(stage / "main.swift"),
             str(TARGET_DIR / "libkaya.a"),
             "-framework", "UIKit", "-framework", "Foundation",
             "-framework", "CoreFoundation", "-framework",
             "CoreGraphics", "-framework", "QuartzCore",
             "-o", str(BUNDLES / f"{guest}swift-bin")],
            stdout=blog, stderr=blog)
        builds.append((guest, p))
    swift_ok = True
    for guest, p in builds:
        if p.wait() != 0:
            print(f"swift guest build FAILED: {guest}", file=sys.stderr)
            print((BUNDLES / f".stage-{guest}/build.log").read_text(
                encoding="utf-8", errors="replace"), file=sys.stderr)
            swift_ok = False
    for stage in BUNDLES.glob(".stage-*"):
        shutil.rmtree(stage, ignore_errors=True)
    if not swift_ok:
        sys.exit(1)
    # AND EACH BINARY MUST CARRY THE MARKER ITSELF: the id lives in
    # libkaya.a, so it is in this executable only if the archive really
    # was linked in — `-L -lkaya` would let ld64 prefer the .dylib
    # beside it, and the bundle would name a build-machine path outside
    # itself and tell nobody.
    for entry in lane.SWIFT_ENTRIES:
        guest, _src = lane.swift_scene(entry)
        verify_built(BUNDLES / f"{guest}swift-bin")
    for entry in lane.SWIFT_ENTRIES:
        guest, _src = lane.swift_scene(entry)
        # THE DECLARED IDENTITY GOES INTO ONE BUNDLE, the one whose
        # guest declares an identity (make_bundle's opt-in).
        ident = "identity" if guest == "identity" else ""
        app = with_dylib(make_bundle(f"{guest}swift",
                                     f"dev.kaya.{guest}swift",
                                     BUNDLES / f"{guest}swift-bin",
                                     ident))
        if guest == "milestone2":
            queue_xcuidrive_proof(app, "dev.kaya.milestone2swift")
            queue_scene_leg("swift", guest, "swift", app,
                            "dev.kaya.milestone2swift", "1", "milestone2")
        elif guest == "canvas":
            # BOTH APPEARANCES, one bundle: every simulator this lane
            # boots is light, so the dark half of expect_ink's frozen
            # string was never evaluated here without the dark leg
            # (docs/canvas-plan.md phase 4).
            queue_scene_leg("swift", guest, "canvas-swift", app,
                            "dev.kaya.canvasswift", guest, guest)
            queue_scene_leg("swift", guest, "canvasdark-swift", app,
                            "dev.kaya.canvasswift", guest, guest,
                            appearance="dark")
        else:
            queue_scene_leg("swift", guest, f"{guest}-swift", app,
                            f"dev.kaya.{guest}swift", guest, guest)
    suite_end("swift")

# The Go guest suite: the same C ABI floor the swift suite reaches,
# THE SCENE LIST THE SWIFT SUITE'S ENTRY FOR ENTRY (minus the rust-only
# canvas scenes) — same bundle, same embedded interpreter, same verdict
# grep, so the two are comparable leg for leg (invariant 1). NOT
# NARROWER, and nothing enforces this: check-steps' wired() keys on
# scene x runner and never on language, so any future divergence has to
# be written down in the module.
if SUITE in ("go", "all"):
    cargo_ios(["build", "--locked", "--target", "aarch64-apple-ios-sim",
               "--lib"])
    verify_built(TARGET_DIR / "libkaya.a")
    build_swiftui_dylib()
    # cgo needs a cross compiler; both the triple and sysroot ride CC
    # because cgo uses CC to LINK as well as compile.
    clang = out_of(["xcrun", "-sdk", "iphonesimulator", "-f",
                    "clang"]).strip()
    go_cc = (f"{clang} -target arm64-apple-ios{IOS_MIN}-simulator "
             f"-isysroot {SDKROOT_SIM}")
    # ONE CROSS-BUILD FOR THE WHOLE SUITE: guests/go/cmd is the guest
    # tree's only main package; it imports every scene library and
    # picks one from KAYA_SELFTEST.
    if run(["go", "build", "-o", str(BUNDLES / "go-bin"),
            "dev.kaya/guests/go/cmd"],
           env=dict(os.environ, CGO_ENABLED="1", GOOS="ios",
                    GOARCH="arm64", CC=go_cc)).returncode != 0:
        sys.exit(1)
    # The marker test: the id is in this executable only if libkaya.a
    # really was linked in (the go #cgo line's -force_load shape).
    verify_built(BUNDLES / "go-bin")
    for guest in lane.GO_SCENES:
        ident = "identity" if guest == "identity" else ""
        app = with_dylib(make_bundle(f"{guest}go", f"dev.kaya.{guest}go",
                                     BUNDLES / "go-bin", ident))
        if guest == "milestone2":
            queue_scene_leg("go", guest, "go", app,
                            "dev.kaya.milestone2go", "1", "milestone2")
        else:
            queue_scene_leg("go", guest, f"{guest}-go", app,
                            f"dev.kaya.{guest}go", guest, guest)
    # THE TEXT EDITOR — the only script on this lane that drives an APP
    # rather than a feature, Go with no swift guest to mirror
    # (docs/editor-plan.md); its cut and keep ride the module's MODS.
    app = with_dylib(make_bundle("editorgo", "dev.kaya.editorgo",
                                 BUNDLES / "go-bin"))
    queue_scene_leg("go", "editor", "editor-go", app, "dev.kaya.editorgo",
                    "editor", "editor")
    suite_end("go")

# THE PYTHON GUEST SUITE (docs/python-mobile-plan.md): CPython embedded
# in ONE bundle carrying every python scene, booted by a C host
# (pyhost.c) whose main thread enters kaya_run exactly as every iOS
# guest does. The framework comes off the flake's pin
# (KAYA_CPYTHON_IOS); the stdlib stages as plain directories (§D5's
# simulator exemption).
if SUITE in ("python", "all"):
    cpython = os.environ.get("KAYA_CPYTHON_IOS", "")
    if not cpython or not pathlib.Path(cpython).is_dir():
        print("run-sim: KAYA_CPYTHON_IOS is unset or not a directory — "
              "the dev", file=sys.stderr)
        print("  shell exports it (flake.nix's cpythonIos); re-enter nix "
              "develop", file=sys.stderr)
        sys.exit(1)
    pyfw = pathlib.Path(cpython) / "ios-arm64_x86_64-simulator"
    cargo_ios(["build", "--locked", "--target", "aarch64-apple-ios-sim",
               "--lib"])
    verify_built(TARGET_DIR / "libkaya.a")
    build_swiftui_dylib()
    if run(["xcrun", "-sdk", "iphonesimulator", "clang", "-target",
            f"arm64-apple-ios{IOS_MIN}-simulator", "tools/ios/pyhost.c",
            "-I", str(pyfw / "Python.framework/Headers"), "-F",
            str(pyfw), "-framework", "Python", "-Wl,-rpath,@executable_path/Frameworks",
            f"-Wl,-force_load,{TARGET_DIR / 'libkaya.a'}",
            "-framework", "UIKit", "-framework", "Foundation",
            "-framework", "CoreFoundation", "-framework", "CoreGraphics",
            "-framework", "QuartzCore", "-o",
            str(BUNDLES / "pyhost-bin")]).returncode != 0:
        sys.exit(1)
    # THE FORCE_LOAD WALL (plan §D3, measured both directions): without
    # it the link keeps only what the host itself calls, and
    # ctypes.CDLL(None) resolves NOTHING — silently. Checked on the
    # path nobody can avoid, by the export the binding's spec handshake
    # reads first.
    exports = out_of(["nm", "-gU", str(BUNDLES / "pyhost-bin")])
    if not any(line.endswith(" _kaya_spec_hash")
               for line in exports.splitlines()):
        print("run-sim: pyhost-bin does not export kaya_spec_hash — "
              "libkaya.a", file=sys.stderr)
        print("  was linked without -Wl,-force_load, and every ctypes "
              "lookup in", file=sys.stderr)
        print("  the guest would answer NULL with no error anywhere",
              file=sys.stderr)
        sys.exit(1)
    verify_built(BUNDLES / "pyhost-bin")
    # The home, assembled once: the shared pure stdlib minus its test
    # weight (172 of 233 MB), then the sim slice's arch files over it.
    # Store paths are read-only; the bundle copy must be writable for
    # simctl install's copyfile.
    pyhome = BUNDLES / "py-home"
    shutil.rmtree(pyhome, ignore_errors=True)
    (pyhome / "lib/python3.15").mkdir(parents=True)
    for rsync_args in (
            [f"{cpython}/lib/python3.15/",
             str(pyhome / "lib/python3.15/")],
            [f"{pyfw}/lib-arm64/python3.15/",
             str(pyhome / "lib/python3.15/")]):
        if run(["rsync", "-a", "--exclude", "test", "--exclude",
                "idlelib", "--exclude", "tkinter", "--exclude",
                "turtledemo", "--exclude", "__pycache__",
                *rsync_args]).returncode != 0:
            sys.exit(1)
    run(["chmod", "-R", "u+w", str(pyhome)])
    app = with_dylib(make_bundle("pyhost", "dev.kaya.pyhost",
                                 BUNDLES / "pyhost-bin"))
    (app / "Frameworks").mkdir(exist_ok=True)
    (app / "app").mkdir(exist_ok=True)
    shutil.copytree(pyfw / "Python.framework",
                    app / "Frameworks/Python.framework")
    run(["chmod", "-R", "u+w", str(app / "Frameworks")])
    shutil.copytree(pyhome, app / "python")
    shutil.copy2(ROOT / "tools/pyhost-main.py", app / "app/main.py")
    for entry in lane.PYTHON_SCENES:
        shutil.copy2(ROOT / f"guests/python/{entry}.py",
                     app / f"app/{entry}.py")
    shutil.copytree(ROOT / "bindings/python/kaya", app / "app/kaya")
    shutil.rmtree(app / "app/kaya/__pycache__", ignore_errors=True)
    for entry in lane.PYTHON_SCENES:
        queue_scene_leg("python", entry, f"{entry}-python", app,
                        "dev.kaya.pyhost", entry, entry)
    suite_end("python")

if SUITE in ("rust-swiftui", "all"):
    # Rust entrypoints + SwiftUI backend: one cargo example per scene,
    # the bundle executable is the example's main, kaya::run dlopens
    # the embedded dylib. The scene order, the per-leg cuts and the
    # iPad siblings all come off the module's tables; the leg comments
    # the shell body carried per scene live in the plans each MODS
    # entry names.
    build_swiftui_dylib()
    for scene in lane.RUST_SCENES:
        example = lane.rust_example(scene)
        cargo_ios(["build", "--locked", "--target",
                   "aarch64-apple-ios-sim", "--example", example])
        if scene == "milestone2":
            app = with_dylib(make_bundle(
                "milestone2rs-swiftui", "dev.kaya.rustswiftui",
                TARGET_DIR / f"examples/{example}"))
            queue_scene_leg("rust-swiftui", scene, "rust-swiftui", app,
                            "dev.kaya.rustswiftui", "1", "milestone2")
            continue
        # THE DECLARED IDENTITY GOES INTO ONE BUNDLE, the one whose
        # guest declares an identity — make_bundle's opt-in, and
        # exactly what expect_app_icon reads (the leg went red the one
        # time this argument was dropped in conversion).
        ident = "identity" if scene == "identity" else ""
        app = with_dylib(make_bundle(
            f"{scene}rs-swiftui", f"dev.kaya.{scene}swiftui",
            TARGET_DIR / f"examples/{example}", ident))
        queue_scene_leg("rust-swiftui", scene, f"{scene}-swiftui", app,
                        f"dev.kaya.{scene}swiftui", scene, scene)
        if scene in lane.PAD_EXTRAS:
            # The iPad sibling — the only observations of the
            # regular-width lowering (the module's PAD_EXTRAS carries
            # what each asserts; table's is empty by decision 5's
            # design, buying that the native path executes at all).
            queue_scene_leg("rust-swiftui", scene,
                            f"{scene}-swiftui-pad", app,
                            f"dev.kaya.{scene}swiftui", scene, scene,
                            pad=True)
    suite_end("swiftui")

# The interleaved pool's one collection point (empty lists no-op for
# the serial shapes, which drained inside their phases).
drain()
if SUITE == "all" and not os.environ.get("KAYA_RECORD"):
    timing("all-legs-drained")

if not rec_suite_stop():
    status = 1
timing("stills-extraction")
if not xcuidrive_census():
    status = 1
# The one-line verdict (run-suites.sh's rule): suites accumulate
# failures rather than abort, so a truncated log must still end with
# the answer — a killed lane or a lost pipe otherwise reads exactly
# like a complete one, which is how an ios run that reached no leg at
# all was read as a pass (2026-08-29). tools/check-gates.sh holds all
# five runners to this.
if status == 0:
    print("run-sim: ALL PASS")
else:
    print("run-sim: FAILURES ABOVE")
sys.exit(status)
