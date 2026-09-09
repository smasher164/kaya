#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# THE APP GENERATOR (docs/packaging-plan.md §2): one command, one arm per
# platform, everything derived from guests/assets/identity.toml.
#
#   tools/package.py mac     <exe> [--out DIR] [--accessory]
#   tools/package.py linux   <exe> [--out DIR] [--install]
#   tools/package.py windows <exe> [--out DIR] [--arch A] [--lib PATH]
#   tools/package.py android        [--out DIR]
#   tools/package.py ios            [--out DIR]
#
# The arms live in tools/lib/packaging/ and are IMPORTED, never launched,
# so the mac lane's bundle wrapper and this command are one code path
# (P4) and gradle's res generation and the lane's are another (P6).
#
# WHAT NEEDS AN EXECUTABLE AND WHAT DOES NOT: mac, linux and windows wrap
# a program; android and ios generate the resources a platform's own
# build packages, and there is no program to name at that point.

import argparse

from packaging import android, ios, linux, mac

WRAPS_A_PROGRAM = {"mac", "linux", "windows"}
PLATFORMS = ("android", "ios", "linux", "mac", "windows")


def out_dir(args):
    return pathlib.Path(args.out) if args.out else (
        ROOT / "target/packages" / args.platform)


def main(argv):
    ap = argparse.ArgumentParser(
        prog="tools/package.py",
        description="Build one platform's app artifact from "
                    "guests/assets/identity.toml.")
    ap.add_argument("platform", choices=PLATFORMS)
    ap.add_argument("exe", nargs="?", default="",
                    help="the program to wrap (mac, linux, windows)")
    ap.add_argument("--out", default="",
                    help="where to write (default target/packages/<platform>)")
    ap.add_argument("--install", action="store_true",
                    help="linux: copy the staged tree under ~/.local/share")
    ap.add_argument("--accessory", action="store_true",
                    help="mac: LSUIElement, the lanes' accessory guests")
    ap.add_argument("--arch", default="arm64",
                    help="windows: the package's architecture")
    ap.add_argument("--lib", default="",
                    help="windows: a kaya.dll to stage in place of the "
                         "cross-built one (the App SDK bootstrap dll and "
                         "the MRT index come with it either way)")
    args = ap.parse_args(argv)

    if args.platform in WRAPS_A_PROGRAM and not args.exe:
        ap.error(f"the {args.platform} arm wraps a program: name the "
                 f"executable to package")
    if args.exe and args.platform not in WRAPS_A_PROGRAM:
        ap.error(f"the {args.platform} arm generates resources a platform "
                 f"build packages, and has no program to wrap")
    out = out_dir(args)

    if args.platform == "mac":
        app = mac.bundle(ROOT, args.exe, out, accessory=args.accessory)
        print(f"package mac: {app}")
    elif args.platform == "linux":
        exe = pathlib.Path(args.exe).resolve()
        if not exe.exists():
            raise SystemExit(
                f"package linux: {exe} does not exist — a desktop entry "
                f"whose Exec program cannot be resolved is refused by the "
                f"portal with \"App info not found\" and the app has no "
                f"activation route at all")
        written = linux.stage(ROOT, str(exe), out)
        print(f"package linux: {len(written)} files under {out}")
        if args.install:
            entry = linux.install(ROOT, out)
            print(f"package linux: installed {entry}")
    elif args.platform == "windows":
        # ANOTHER AGENT'S ARM (docs/packaging-plan.md P3), dispatched by
        # name: this command owns no MSIX knowledge.
        try:
            from packaging import windows
        except ImportError as exc:
            raise SystemExit(
                f"package windows: tools/lib/packaging/windows.py is not "
                f"importable ({exc}) — the MSIX arm and the unpackaged "
                f"self-registration live there (docs/packaging-plan.md P3)")
        made = windows.stage(ROOT, [args.exe], out, arch=args.arch,
                             lib=args.lib or None)
        print(f"package windows: {made}")
    elif args.platform == "android":
        written = android.write_res(ROOT, out)
        print(f"package android: {len(written)} mipmap files under {out}")
    else:
        base = ios.write_icon_family(ROOT, out)
        print(f"package ios: icon family {base} under {out}")


main(sys.argv[1:])
