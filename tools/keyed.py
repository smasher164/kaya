#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT

# Run a gate, or skip it because nothing it reads has changed since it
# last passed.
#
#   tools/keyed.py <gate-name> -- <command...>
#
# OFF BY DEFAULT: without KAYA_FAST=1 this execs the command, so the
# matrix never consults a cache. Input sets and why they are
# deliberately over-approximate live in tools/build-id.py's GATES; a key
# that omits an input would skip a gate whose answer had changed.
# Failures are never stored.
#
# NO dev_shell_or_die, matching the shell body it replaces: the guard
# belongs to the GATE this launches, which prints its own refusal.

import os
import subprocess


def run_status(cmd):
    r = subprocess.run(cmd, check=False)
    # A signal death maps back to the shell's 128+N spelling, so the
    # caller reads the same status the old body handed it.
    return r.returncode if r.returncode >= 0 else 128 - r.returncode


def main(argv):
    if not argv or not argv[0]:
        print("usage: keyed.py <gate-name> -- <command...>",
              file=sys.stderr)
        return 1
    name = argv[0]
    rest = argv[1:]
    if rest[:1] != ["--"]:
        print("keyed.py: expected -- before the command", file=sys.stderr)
        return 2
    cmd = rest[1:]

    key_run = subprocess.run(
        [sys.executable, str(ROOT / "tools/build-id.py"), "--gate", name],
        stdout=subprocess.PIPE, text=True, encoding="utf-8", check=False)
    if key_run.returncode != 0:
        return 1
    key = key_run.stdout.strip()
    store = ROOT / "target/.kaya-gates"
    store.mkdir(parents=True, exist_ok=True)
    stamp = store / name

    if os.environ.get("KAYA_FAST", "0") != "1":
        # CONSULTS NOTHING — the matrix's run answers from the gate
        # alone — but a PASS is still recorded, so the first KAYA_FAST
        # run after a full sweep is warm instead of re-running
        # everything the sweep just proved (measured 2026-08-20: a cold
        # fast sweep cost 148s against 46s warm, and a day of full runs
        # had warmed nothing).
        status = run_status(cmd)
        if status == 0:
            stamp.write_text(key, encoding="utf-8")
        else:
            stamp.unlink(missing_ok=True)
        return status

    if stamp.is_file() and stamp.read_text(encoding="utf-8") == key:
        # Every skip says so, with its key: "why didn't that re-run"
        # must be answerable from the log alone.
        print(f"{name}: CACHED ({key}) — inputs unchanged since it "
              f"last passed")
        return 0

    status = run_status(cmd)
    if status == 0:
        stamp.write_text(key, encoding="utf-8")
        return 0
    stamp.unlink(missing_ok=True)
    return status


raise SystemExit(main(sys.argv[1:]))
