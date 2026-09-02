#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# ONE MAC LEG BY HAND, THROUGH THE LANE'S OWN MAPPING, AFTER THE LANE'S
# OWN VERIFICATION. A hand run that spelled its env line by line pointed
# KAYA_SWIFTUI_LIB at an interpreter built from older sources and spent a
# failure on "no such target" that was the stale dylib, not the arm
# (2026-09-01, docs/traps.md): swift-typecheck compiles the interpreter
# and builds nothing, so the dylib on disk is whatever last built it. This
# refuses a stale libkaya or interpreter NAMING THE BUILD, or rebuilds
# both with --build, and then runs the leg exactly as validate-mac would.
#
#   tools/run-leg.py <scene> <lang> [--build] [--appearance dark]

import os
import subprocess

from lanes import mac as lane

args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = [a for a in sys.argv[1:] if a.startswith("--")]
if len(args) != 2:
    print("usage: tools/run-leg.py <scene> <lang> [--build] [--appearance dark]",
          file=sys.stderr)
    sys.exit(2)
scene, lang = args
appearance = ""
for f in flags:
    if f.startswith("--appearance="):
        appearance = f.split("=", 1)[1]
if "--appearance" in flags:
    print("run-leg: spell it --appearance=dark", file=sys.stderr)
    sys.exit(2)
if not (ROOT / f"tools/scenes/{scene}.steps").is_file():
    print(f"run-leg: no tools/scenes/{scene}.steps", file=sys.stderr)
    sys.exit(2)
if (scene, lang) not in {(s, lg) for _n, s, lg in lane.legs()}:
    print(f"run-leg: {scene}-{lang} is not a leg of tools/lib/lanes/mac.py's "
          f"roster — this runs what the lane runs, nothing else",
          file=sys.stderr)
    sys.exit(2)

LIB = ROOT / "target/debug/libkaya.dylib"
DYLIB = ROOT / "target/swiftui/libkaya_swiftui.dylib"
if "--build" in flags:
    for cmd in (["cargo", "build", "--locked", "--lib"],
                [str(ROOT / "tools/swiftui/build-dylib.sh")]):
        if subprocess.run(cmd, cwd=ROOT).returncode != 0:
            print(f"run-leg: build failed: {' '.join(cmd)}", file=sys.stderr)
            sys.exit(1)
# THE WALL: both artifacts carry the id of the sources they came from,
# and a hand run gets the lane's refusal, not a stale answer.
for what, path, fix in (("libkaya", LIB, "cargo build --locked --lib"),
                        ("the SwiftUI interpreter", DYLIB,
                         "tools/swiftui/build-dylib.sh")):
    verify = [str(ROOT / "tools/build-id.sh"), "--verify"]
    if what != "libkaya":
        verify += ["--component", "swiftui"]
    got = subprocess.run(verify + [str(path)], cwd=ROOT)
    if got.returncode != 0:
        print(f"run-leg: {what} is stale or missing for this tree — run "
              f"`{fix}` (or re-run with --build)", file=sys.stderr)
        sys.exit(1)


def hs_bin(name):
    got = subprocess.run(["cabal", "list-bin", name, "-v0"],
                         cwd=ROOT / "guests/haskell", stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, check=False, text=True,
                         encoding="utf-8", errors="replace")
    return got.stdout.strip()


argv = lane.leg_argv(scene, lang, hs_bin)
env = dict(os.environ)
env.update(lane.leg_env(ROOT, scene, lang, appearance))
print(f"run-leg: {scene}-{lang}: {' '.join(argv)}", flush=True)
rc = subprocess.run(argv, cwd=ROOT, env=env).returncode
print(f"run-leg: exit {rc}")
sys.exit(rc)
