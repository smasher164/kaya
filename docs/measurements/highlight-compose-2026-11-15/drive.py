#!/usr/bin/env python3
"""Install the highlight probe, run it light and dark, photograph it, read the
log, uninstall. usage: drive.py <serial> <outdir>"""
import pathlib, subprocess, sys, time

DEV, OUT = sys.argv[1], pathlib.Path(sys.argv[2])
PKG = "dev.kayaprobe.hl"
APK = pathlib.Path(__file__).resolve().parent / "app/build/outputs/apk/debug/app-debug.apk"


def adb(*a, out=None):
    r = subprocess.run(["adb", "-s", DEV, *a], capture_output=True, timeout=120)
    if out:
        out.write_bytes(r.stdout)
    return r.stdout.decode(errors="replace")


print(adb("install", "-r", str(APK)).strip())
for mode in ("0", "1"):
    adb("logcat", "-c")
    adb("shell", "am", "start", "-W", "-n", f"{PKG}/.MainActivity", "--es", "dark", mode)
    for _ in range(30):
        if "READY" in adb("logcat", "-d", "-s", "HLPROBE:I"):
            break
        time.sleep(0.5)
    time.sleep(0.5)
    adb("exec-out", "screencap", "-p", out=OUT / f"shot-{'dark' if mode == '1' else 'light'}.png")
    log = adb("logcat", "-d", "-s", "HLPROBE:I")
    (OUT / f"log-{'dark' if mode == '1' else 'light'}.txt").write_text(log)
    print(log)
    adb("shell", "am", "force-stop", PKG)
print(adb("uninstall", PKG).strip())
print("packages left:", adb("shell", "pm", "list", "packages", PKG).strip() or "none")
