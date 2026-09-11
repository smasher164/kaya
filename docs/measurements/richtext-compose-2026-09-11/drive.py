#!/usr/bin/env python3
"""Drive the rtprobe app: broadcast commands, real key input, read the log back."""
import subprocess, sys, time

ADB = "/nix/store/1v2sgmkh7qjmbd9b81gdipjsxwlxpy5r-androidsdk/libexec/android-sdk/platform-tools/adb"
DEV = "emulator-5554"
PKG = "dev.kayaprobe.richtext"


def adb(*args, quiet=True):
    r = subprocess.run([ADB, "-s", DEV] + list(args), capture_output=True, text=True)
    if not quiet:
        print(r.stdout, r.stderr)
    return r.stdout


def cmd(line):
    adb("shell", "am", "broadcast", "-a", "dev.kayaprobe.RT", "-p", PKG, "--es", "cmd", "'" + line + "'")
    time.sleep(0.35)


def type_text(s):
    adb("shell", "input", "text", s)
    time.sleep(0.6)


def key(code):
    adb("shell", "input", "keyevent", str(code))
    time.sleep(0.4)


def clear():
    adb("logcat", "-c")


def dump():
    return adb("logcat", "-d", "-s", "RTPROBE:I")


def run(steps, label=""):
    clear()
    for s in steps:
        kind, arg = s[0], s[1]
        if kind == "cmd":
            cmd(arg)
        elif kind == "type":
            type_text(arg)
        elif kind == "key":
            key(arg)
        elif kind == "sleep":
            time.sleep(float(arg))
        elif kind == "sh":
            adb(*arg)
    out = dump()
    print(f"===== {label} =====")
    for line in out.splitlines():
        if "RTPROBE" in line:
            print(line.split("RTPROBE : ", 1)[-1] if "RTPROBE : " in line else line)
    return out


if __name__ == "__main__":
    pass
