#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# The packaging gate: build the kaya-gui wheel fresh, install it into a
# throwaway venv, and import through the INSTALLED package. The suites
# run the working tree via PYTHONPATH, so only this leg sees what the
# wheel actually ships.

import os
import subprocess

SMOKE = """\
import kaya
import kaya.wire
import kaya.runtime

assert isinstance(kaya.wire.SPEC_HASH, int)
assert hasattr(kaya, "collection") and hasattr(kaya, "for_each")
"""

with scratch_dir("check-wheel-") as tmp:
    # --no-isolation keeps the build offline and pinned to the flake.
    log = tmp / "build.log"
    with log.open("w", encoding="utf-8") as out:
        built = subprocess.run(
            [sys.executable, "-m", "build", "--wheel", "--no-isolation",
             "--outdir", str(tmp / "dist"), "bindings/python"],
            cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, check=False)
    if built.returncode != 0:
        print("check-wheel: wheel build failed", file=sys.stderr)
        tail = log.read_text(encoding="utf-8").splitlines()[-5:]
        for line in tail:
            print(line, file=sys.stderr)
        sys.exit(1)

    if subprocess.run([sys.executable, "-m", "venv", str(tmp / "venv")],
                      check=False).returncode != 0:
        sys.exit(1)

    # Empty PYTHONPATH: the venv's installed wheel must be the ONLY
    # import mechanism here, or a packaging hole hides behind the
    # working tree.
    bare = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    wheels = [str(p) for p in sorted((tmp / "dist").glob("kaya_gui-*.whl"))]
    if subprocess.run(
            [str(tmp / "venv/bin/pip"), "install", "--quiet", "--no-index",
             *wheels],
            env=bare, check=False).returncode != 0:
        print("check-wheel: wheel install failed", file=sys.stderr)
        sys.exit(1)

    smoke_env = dict(bare, KAYA_LIB=str(ROOT / "target/debug/libkaya.dylib"))
    if subprocess.run([str(tmp / "venv/bin/python"), "-c", SMOKE],
                      env=smoke_env, check=False).returncode != 0:
        print("check-wheel: installed package failed its import smoke",
              file=sys.stderr)
        sys.exit(1)

print("check-wheel: OK")
