#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# ONE MAC LEG BY HAND, THROUGH THE LANE'S OWN MAPPING, AFTER THE LANE'S
# OWN VERIFICATION (docs/traps.md, 2026-09-01: a hand-spelled env line
# pointed KAYA_SWIFTUI_LIB at an interpreter built from older sources and
# spent a failure on "no such target"). swift-typecheck compiles the
# interpreter and builds nothing, so the dylib on disk is whatever last
# built it: this refuses a stale one NAMING THE BUILD, or rebuilds with
# --build.
#
#   tools/run-leg.py <scene> <lang> [--build] [--appearance dark]

import os
import shutil
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
    verify = [str(ROOT / "tools/build-id.py"), "--verify"]
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


# A RUST GUEST CARRIES ITS OWN CORE: the example links the crate statically,
# so the two verified artifacts above vouch for nothing it runs. Build it
# and stage it the lane's way, every run — cargo's no-op is the verify.
if lang == "rust":
    stem = lane.guest_stem(scene)
    build = ["cargo", "build", "--locked", "-p", "kaya", "--example", stem]
    if subprocess.run(build, cwd=ROOT).returncode != 0:
        print(f"run-leg: build failed: {' '.join(build)}", file=sys.stderr)
        sys.exit(1)
    staged = ROOT / lane.RUST_GUESTS / stem
    staged.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / f"target/debug/examples/{stem}", staged)

argv = lane.leg_argv(scene, lang, hs_bin)
env = dict(os.environ)
env.update(lane.leg_env(ROOT, scene, lang, appearance))
print(f"run-leg: {scene}-{lang}: {' '.join(argv)}", flush=True)
rc = subprocess.run(argv, cwd=ROOT, env=env).returncode
print(f"run-leg: exit {rc}")
sys.exit(rc)
