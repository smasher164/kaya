#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# Typecheck the JS binding and every JS guest with tsc — the compiler
# the guests never otherwise meet, since node strips their types and
# checks nothing (docs/js-plan.md §5). The binding's own tsconfig is
# strict; the guests' extends it.
#
# THE WORKSPACE LINK IS MADE HERE, on the path nobody can avoid: the
# guests import "kaya-gui", which resolves through
# guests/js/node_modules/kaya-gui -> bindings/js, and `npm install
# --offline` is what writes that symlink (a file: dependency needs no
# registry). Idempotent and ~100ms once linked.

import os
import subprocess

g = Gate("js-typecheck")

types = os.environ.get("KAYA_NODE_TYPES", "")
if not types or not (pathlib.Path(types) / "node").is_dir():
    g.refuse("KAYA_NODE_TYPES does not name a directory holding node/ — "
             "flake.nix's nodeTypes pin exports it; re-enter the dev shell")

link = subprocess.run(
    ["npm", "install", "--offline", "--no-audit", "--no-fund",
     "--no-package-lock", "--silent"],
    cwd=ROOT / "guests/js", check=False)
if link.returncode != 0:
    g.finding("npm install --offline failed in guests/js — the workspace "
              "link (node_modules/kaya-gui -> bindings/js) was not made")
    g.verdict()
if not (ROOT / "guests/js/node_modules/kaya-gui/package.json").is_file():
    g.refuse("guests/js/node_modules/kaya-gui does not resolve to "
             "bindings/js after npm install — the link this gate relies "
             "on is not there")

# WHAT EACH PASS COMPILED, said out loud: an OK over an unstated file
# set is how swift-typecheck twice claimed a layer it had never read.
binding_files = sorted((ROOT / "bindings/js/kaya").glob("*.ts"))
guest_files = sorted(p for p in (ROOT / "guests/js").glob("*.ts"))
g.counted("binding sources", binding_files, floor=3)
g.counted("guest sources", guest_files, floor=4)

for project in ("bindings/js", "guests/js"):
    r = subprocess.run(["tsc", "-p", project, "--typeRoots", types],
                       cwd=ROOT, check=False)
    if r.returncode != 0:
        g.finding(f"tsc -p {project} reported errors above")

g.verdict(f"{len(binding_files)} binding + {len(guest_files)} guest "
          f"sources, strict, types from KAYA_NODE_TYPES")
