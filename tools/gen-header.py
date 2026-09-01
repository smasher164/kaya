#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# Regenerate crates/kaya/include/kaya.h from the Rust source — the one
# spelling of the cbindgen invocation.
#
# Usage: tools/gen-header.sh [--check]   (--check fails on a stale
# header and touches nothing)

import os
import subprocess

os.chdir(ROOT)

HEADER = "crates/kaya/include/kaya.h"

if sys.argv[1:2] == ["--check"]:
    with scratch_dir("gen-header-") as tmp:
        out = tmp / "kaya.h"
        r = subprocess.run(
            ["cbindgen", "--config", "crates/kaya/cbindgen.toml",
             "--crate", "kaya", "--output", str(out), "crates/kaya"],
            stderr=subprocess.DEVNULL, check=False)
        if r.returncode != 0:
            sys.exit(r.returncode)
        if (pathlib.Path(HEADER).read_bytes() != out.read_bytes()):
            # The real diff, for the reader; the verdict came from the
            # byte comparison above.
            subprocess.run(["diff", "-u", HEADER, str(out)],
                           check=False)
            print(f"{HEADER} is stale; regenerate with "
                  f"tools/gen-header.sh", file=sys.stderr)
            sys.exit(1)
else:
    r = subprocess.run(
        ["cbindgen", "--config", "crates/kaya/cbindgen.toml",
         "--crate", "kaya", "--output", HEADER, "crates/kaya"],
        check=False)
    if r.returncode != 0:
        sys.exit(r.returncode)
