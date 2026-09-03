#!/usr/bin/env python3
"""A standalone launcher for the resident XCUITest driver
(tools/ios/xcuidrive/KayaDrive.swift), so a PROBE can borrow the lane's
hands without importing tools/ios/run-sim.py — that file has no
`__main__` guard and running it runs the whole lane.

The build here is run-sim.py's xcuidrive_build() verbatim in shape; the
driver SOURCE is the lane's own, never a copy.

  drive.py build [lane|probe]   lane = tools/ios/xcuidrive (default),
                                probe = DragDrive.swift beside this file
  drive.py start <udid>          detached; writes pid, waits for `ready`
  drive.py send  <udid> <verb…>  one request, prints the response
  drive.py stop  <udid>          `quit`, then kill, then census
  drive.py ps                    what this probe still has running
"""
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
LANE_SRC = ROOT / "tools/ios/xcuidrive/KayaDrive.swift"
PROBE_SRC = pathlib.Path(__file__).resolve().parent / "DragDrive.swift"
SRC = ROOT / "tools/ios/xcuidrive"
BUILD = ROOT / "target/ios-dragprobe/drive"
RUNNER_ID = "dev.kayalane.drive.runner"


def run(argv, **kw):
    return subprocess.run(argv, check=False, **kw)


def out_of(argv):
    got = subprocess.run(argv, check=False, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True,
                         encoding="utf-8", errors="replace")
    return got.stdout


def _plist_write(path, value):
    with open(path, "wb") as f:
        plistlib.dump(value, f)


def build(which="lane"):
    plat = out_of(["xcrun", "-sdk", "iphonesimulator",
                   "--show-sdk-platform-path"]).strip()
    dev = pathlib.Path(plat) / "Developer"
    shutil.rmtree(BUILD, ignore_errors=True)
    xctest = BUILD / "KayaDrive.xctest"
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
            str(LANE_SRC if which == "lane" else PROBE_SRC)]).returncode != 0:
        sys.exit("drive: the xcui driver did not compile")
    _plist_write(xctest / "Info.plist", {
        "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": "KayaDrive",
        "CFBundleIdentifier": "dev.kayalane.drive",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "KayaDrive",
        "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "DTPlatformName": "iphonesimulator", "MinimumOSVersion": "17.0",
        "XCTContainsUITests": True})
    target = BUILD / "KayaDriveTarget.app"
    target.mkdir()
    if run(["xcrun", "-sdk", "iphonesimulator", "swiftc", "-target",
            "arm64-apple-ios17.0-simulator", "-parse-as-library",
            "-framework", "UIKit", "-o", str(target / "KayaDriveTarget"),
            str(SRC / "Target.swift")]).returncode != 0:
        sys.exit("drive: the target app did not compile")
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
    runner = BUILD / "KayaDrive-Runner.app"
    shutil.copytree(dev / "Library/Xcode/Agents/XCTRunner.app", runner,
                    symlinks=True)
    (runner / "XCTRunner").rename(runner / "KayaDrive-Runner")
    info = plistlib.loads((runner / "Info.plist").read_bytes())
    info.update(CFBundleExecutable="KayaDrive-Runner",
                CFBundleIdentifier=RUNNER_ID,
                CFBundleName="KayaDrive-Runner")
    _plist_write(runner / "Info.plist", info)
    shutil.copytree(xctest, runner / "PlugIns/KayaDrive.xctest")
    fw = runner / "Frameworks"
    fw.mkdir()
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
            sys.exit(f"drive: codesign failed: {' '.join(argv)}")
    print("drive: built", BUILD)


def dirof(udid):
    return BUILD / f"session-{udid}"


def start(udid):
    d = dirof(udid)
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    testrun = BUILD / f"kayadrive-{udid}.xctestrun"
    _plist_write(testrun, {"KayaDrive": {
        "TestBundlePath": "__TESTHOST__/PlugIns/KayaDrive.xctest",
        "TestHostPath": "__TESTROOT__/KayaDrive-Runner.app",
        "TestHostBundleIdentifier": RUNNER_ID,
        "UITargetAppPath": "__TESTROOT__/KayaDriveTarget.app",
        "IsUITestBundle": True, "IsXCTRunnerHostedTestBundle": True,
        "ProductModuleName": "KayaDrive",
        "TestingEnvironmentVariables": {
            "DYLD_FRAMEWORK_PATH":
                "__TESTROOT__/KayaDrive-Runner.app/Frameworks",
            "DYLD_LIBRARY_PATH":
                "__TESTROOT__/KayaDrive-Runner.app/Frameworks",
            "KAYA_DRIVE_DIR": str(d)},
        "DependentProductPaths": ["__TESTROOT__/KayaDrive-Runner.app",
                                  "__TESTROOT__/KayaDriveTarget.app"],
        "SystemAttachmentLifetime": "deleteOnSuccess",
        "UserAttachmentLifetime": "deleteOnSuccess"}})
    env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
    log = open(d / "xcodebuild.log", "w", encoding="utf-8")
    proc = subprocess.Popen(
        ["xcodebuild", "test-without-building", "-xctestrun", str(testrun),
         "-destination", f"platform=iOS Simulator,id={udid}",
         "-resultBundlePath", str(d / "result.xcresult")],
        stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    (d / "pid").write_text(f"{proc.pid}\n", encoding="utf-8")
    started = time.monotonic()
    while not (d / "ready").is_file():
        if proc.poll() is not None or time.monotonic() - started > 180:
            tail = (d / "xcodebuild.log").read_text(
                encoding="utf-8", errors="replace").splitlines()[-25:]
            sys.exit(f"drive: no ready file (exit={proc.poll()}):\n"
                     + "\n".join(tail))
        time.sleep(0.2)
    print(f"drive: ready in {int(time.monotonic() - started)}s "
          f"pid={proc.pid} dir={d}")


def send(udid, verb, timeout=60):
    d = dirof(udid)
    resp = d / "response"
    resp.unlink(missing_ok=True)
    part = d / "request.part"
    part.write_text(verb + "\n", encoding="utf-8")
    part.rename(d / "request")
    started = time.monotonic()
    while not resp.is_file():
        if time.monotonic() - started > timeout:
            return False, f"timeout after {timeout}s"
        time.sleep(0.02)
    body = resp.read_text(encoding="utf-8", errors="replace")
    head, _, rest = body.partition("\n")
    return head.strip() == "ok", rest.rstrip("\n")


def stop(udid):
    d = dirof(udid)
    if (d / "ready").is_file():
        send(udid, "quit", timeout=10)
    pid = 0
    if (d / "pid").is_file():
        pid = int((d / "pid").read_text(encoding="utf-8").strip() or 0)
    deadline = time.monotonic() + 20
    while pid and time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except OSError:
            pid = 0
            break
        time.sleep(0.2)
    if pid:
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except OSError:
            pass
    run(["xcrun", "simctl", "terminate", udid, RUNNER_ID],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"drive: stopped {udid}")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "build":
        build(sys.argv[2] if len(sys.argv) > 2 else "lane")
    elif cmd == "start":
        start(sys.argv[2])
    elif cmd == "send":
        ok, body = send(sys.argv[2], " ".join(sys.argv[3:]))
        print("ok" if ok else "err")
        print(body)
        sys.exit(0 if ok else 1)
    elif cmd == "stop":
        stop(sys.argv[2])
    elif cmd == "ps":
        print(out_of(["pgrep", "-fl", "xcodebuild|KayaDrive"]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
