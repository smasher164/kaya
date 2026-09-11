#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Build, sign, install and launch the canvas GPU probe on a PAIRED IPHONE,
# then pull its report back. NOT A LANE: it needs hardware (the record is
# owed a phone-class core, docs/canvas-gpu-plan.md §11). The recipe is
# tools/ios/scopeprobe/build.sh's: full Xcode for devicectl and the SDK, an
# Apple Development identity, one downloaded profile that DECIDES the
# bundle id, the phone unlocked with developer mode on.
#
# Usage: tools/ios/gpuprobe/build.py [--out FILE] [--device ID] [--mac]
#   --mac runs the same probe on this host instead (no phone needed).

import json
import os
import plistlib
import shutil
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
CRATE = HERE / "probe"
args = sys.argv[1:]
out = None
device = os.environ.get("KAYA_IOS_DEVICE", "")
mac = False
while args:
    if args[0] == "--out" and len(args) > 1:
        out = pathlib.Path(args[1])
        args = args[2:]
    elif args[0] == "--device" and len(args) > 1:
        device = args[1]
        args = args[2:]
    elif args[0] == "--mac":
        mac = True
        args = args[1:]
    else:
        sys.exit("usage: build.py [--out FILE] [--device ID] [--mac]")


def run(argv, **kw):
    return subprocess.run(argv, check=False, **kw)


def out_of(argv, **kw):
    return subprocess.run(argv, check=True, stdout=subprocess.PIPE, text=True,
                          encoding="utf-8", **kw).stdout


if mac:
    r = run(["cargo", "run", "--release", "--locked", "--manifest-path",
             str(CRATE / "Cargo.toml")], stdout=subprocess.PIPE, text=True,
            encoding="utf-8")
    if out:
        out.write_text(r.stdout, encoding="utf-8")
    sys.stdout.write(r.stdout)
    sys.exit(r.returncode)

# Full Xcode: the dev shell's DEVELOPER_DIR is a nix apple-sdk with no
# devicectl and no iOS SDK (tools/lib/swift-toolchain.sh).
env = dict(os.environ)
env.pop("SDKROOT", None)
for app in sorted(pathlib.Path("/Applications").glob("Xcode*.app")):
    if (app / "Contents/Developer").is_dir():
        env["DEVELOPER_DIR"] = str(app / "Contents/Developer")
        break
xcrun = ["/usr/bin/xcrun"]
if run(xcrun + ["devicectl", "list", "devices"], env=env,
       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
    sys.exit("gpuprobe: devicectl unavailable — full Xcode is required")

identity = ""
for line in out_of(["security", "find-identity", "-p", "codesigning", "-v"]).splitlines():
    if "Apple Development" in line:
        identity = line.split('"')[1]
        break
if not identity:
    sys.exit("gpuprobe: no codesigning identity. Add an Apple ID in Xcode > "
             "Settings > Accounts, then build any app for the device once so "
             "a profile is minted.")

profile = None
for d in (pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
          pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles"):
    if d.is_dir():
        found = sorted(d.glob("*.mobileprovision"))
        if found:
            profile = found[0]
            break
if profile is None:
    sys.exit("gpuprobe: no provisioning profile on disk. Build any app for "
             "this device from Xcode once; that is what mints one.")

work = pathlib.Path(tempfile.mkdtemp(prefix="kaya-gpuprobe-"))
try:
    prof = plistlib.loads(out_of(["security", "cms", "-D", "-i", str(profile)]).encode("utf-8"))
    ent = prof["Entitlements"]
    appid = ent["application-identifier"]
    team = ent.get("com.apple.developer.team-identifier", appid.split(".")[0])
    bundle_id = appid.split(".", 1)[1]
    if bundle_id == "*":
        bundle_id = "cc.akhil.gpuprobe"
        appid = team + "." + bundle_id
    (work / "ent.plist").write_bytes(plistlib.dumps({
        "application-identifier": appid,
        "com.apple.developer.team-identifier": team,
        "get-task-allow": True,
    }))

    # THE RUST HALF, a static library for the device target: the crate's
    # own workspace and lockfile, locked like every cargo call here.
    sdk = out_of(xcrun + ["--sdk", "iphoneos", "--show-sdk-path"], env=env).strip()
    cargo_env = dict(env, SDKROOT=sdk)
    if run(["cargo", "build", "--release", "--locked", "--target", "aarch64-apple-ios",
            "--manifest-path", str(CRATE / "Cargo.toml")], env=cargo_env).returncode != 0:
        sys.exit("gpuprobe: the Rust probe did not build for aarch64-apple-ios")
    staticlib = CRATE / "target/aarch64-apple-ios/release/libkaya_gpuprobe.a"
    if not staticlib.is_file():
        sys.exit(f"gpuprobe: {staticlib} is missing after the build")

    bundle = work / "gpuprobe.app"
    bundle.mkdir()
    if run(xcrun + ["--sdk", "iphoneos", "swiftc", "-target", "arm64-apple-ios17.0",
                    "-sdk", sdk, "-parse-as-library",
                    "-L", str(staticlib.parent), "-lkaya_gpuprobe",
                    "-framework", "UIKit", "-framework", "Metal",
                    "-framework", "QuartzCore", "-framework", "Foundation",
                    "-lc++", "-o", str(bundle / "gpuprobe"),
                    str(HERE / "main.swift")], env=env).returncode != 0:
        sys.exit("gpuprobe: the Swift host did not compile")
    (bundle / "Info.plist").write_text(
        (HERE / "Info.plist.in").read_text(encoding="utf-8").replace("@BUNDLE_ID@", bundle_id),
        encoding="utf-8")
    shutil.copy2(profile, bundle / "embedded.mobileprovision")
    if run(["codesign", "--force", "--sign", identity, "--entitlements",
            str(work / "ent.plist"), "--timestamp=none", str(bundle)]).returncode != 0:
        sys.exit("gpuprobe: codesign refused the bundle")

    if not device:
        run(xcrun + ["devicectl", "list", "devices", "--json-output",
                     str(work / "devices.json")], env=env, stdout=subprocess.DEVNULL)
        devices = json.loads((work / "devices.json").read_text(encoding="utf-8"))["result"]["devices"]
        live = [d for d in devices
                if d.get("connectionProperties", {}).get("tunnelState") != "unavailable"]
        if len(live) != 1:
            names = ", ".join(d["deviceProperties"]["name"] for d in live) or "none"
            sys.exit(f"gpuprobe: expected exactly one connected device, found: {names} "
                     f"— pass --device ID")
        device = live[0]["identifier"]

    if run(xcrun + ["devicectl", "device", "install", "app", "--device", device,
                    str(bundle)], env=env).returncode != 0:
        sys.exit("gpuprobe: install failed")
    # A LOCKED PHONE INSTALLS FINE AND REFUSES TO LAUNCH (scopeprobe's
    # finding): say so in one line. THE CONSOLE STAYS ATTACHED: the launch
    # streams the report's lines as the app prints them and returns the
    # moment the process ends — a crash is known in seconds with its panic
    # text, a finished run when the app exits on its own (main.swift). The
    # first device run polled a copy of the report for 900s against an app
    # that had aborted at once.
    launch = run(xcrun + ["devicectl", "device", "process", "launch", "--console",
                          "--terminate-existing", "--device", device, bundle_id],
                 env=env, timeout=900)
    if launch.returncode != 0:
        print("gpuprobe: the launch returned nonzero. If the dump above says "
              "Locked, unlock the phone and re-run — nothing needs rebuilding; "
              "a panic above is the probe's own.", file=sys.stderr)
    report = work / "gpuprobe.txt"
    run(xcrun + ["devicectl", "device", "copy", "from", "--device", device,
                 "--domain-type", "appDataContainer", "--domain-identifier", bundle_id,
                 "--source", "Documents/gpuprobe.txt", "--destination", str(report)],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    body = report.read_text(encoding="utf-8", errors="replace") if report.is_file() else ""
    if "== done ==" not in body:
        sys.exit("gpuprobe: the report did not reach `== done ==`; the console "
                 "above carries what the probe said before it stopped")
    if out:
        out.write_text(body, encoding="utf-8")
        print(f"gpuprobe: report written to {out}")
    else:
        sys.stdout.write(body)
finally:
    shutil.rmtree(work, ignore_errors=True)
