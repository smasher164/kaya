#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Build the Linux validation image and run the suites in it (GTK under
# Xvfb). Requires docker. The lane's tables live in
# tools/linux/run-suites.sh, which runs INSIDE the container and stays
# shell by the conversion ruling's boundary (an in-container payload;
# docs/runner-conversion-plan.md §6).

import os
import subprocess
import time


def run(argv, **kw):
    return subprocess.run(argv, check=False, **kw)


os.chdir(ROOT)

# ONE FILE UNDER THE ASSET ROOT IS DERIVED and never committed
# (guests/assets/market/README.md), so a fresh clone bind-mounts an
# incomplete root at /work. HERE AND NOT IN run-suites.sh, which is
# the lane's asset site: this is the only half that runs as the host
# user, and a stamp written by the container's root would then be one
# the gate sweep cannot rewrite.
if run([sys.executable, str(ROOT / "tools/gen-market.py"),
        "--ensure"]).returncode != 0:
    print("validate-linux: python3 tools/gen-market.py --ensure failed "
          "— the market", file=sys.stderr)
    print("  family's transactions.csv is derived, so the root mounted "
          "at /work is", file=sys.stderr)
    print("  incomplete and every guest that reads it fails inside its "
          "build closure", file=sys.stderr)
    sys.exit(1)

t0 = time.monotonic()
if run(["docker", "build", "-q", "-t", "kaya-linux",
        str(ROOT / "tools/linux")],
       stdout=subprocess.DEVNULL).returncode != 0:
    sys.exit(1)
print(f"TIMING image-build {int(time.monotonic() - t0)}s", flush=True)
t0 = time.monotonic()

# THE FLIGHT RECORDER'S HOME IS THE HOST'S, MOUNTED IN. The container
# is `--rm`, so a journal written to its own filesystem dies with it —
# and the recorder's whole point is that a leg which fails once and
# passes on the rerun leaves something behind. One home per MACHINE is
# also the design (tools/lib/flightrec.py): two lanes from two
# checkouts belong in one journal, and a per-container home would
# fragment it.
flightrec_home = pathlib.Path(
    os.environ.get("XDG_STATE_HOME",
                   str(pathlib.Path.home() / ".local/state"))) / "kaya"
flightrec_home.mkdir(parents=True, exist_ok=True)

# Hard ceiling on a suite that never returns. Generous: a cold
# container compiles everything from scratch.
rc = run(["timeout", "1800", "docker", "run", "--rm",
          "-v", f"{ROOT}:/work",
          "-v", f"{flightrec_home}:/flightrec-state/kaya",
          "-e", "XDG_STATE_HOME=/flightrec-state",
          "-e", f"KAYA_RECORD={os.environ.get('KAYA_RECORD', '')}",
          "-e", f"KAYA_JOBS={os.environ.get('KAYA_JOBS', '')}",
          "-e", f"KAYA_ONLY={os.environ.get('KAYA_ONLY', '')}",
          "kaya-linux", "bash", "/work/tools/linux/run-suites.sh"
          ]).returncode
print(f"TIMING container-suites {int(time.monotonic() - t0)}s",
      flush=True)
sys.exit(rc)
