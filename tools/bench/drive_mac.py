#!/usr/bin/env python3
"""The macOS rung: launch the bench guest on the SwiftUI interpreter and
time launch -> harness verdict.

Transcribed from the 2026-08-24 rig (docs/measurements/
choke-macos-2026-08-24.txt records the recipe it implements). Three
numbers per run, the same three that report used:

    wall          launch -> the KAYA_SELFTEST verdict line
    script_start  launch -> "KAYA_HARNESS: epoch"   (interpreter is up)
    submit_done   launch -> the guest's last transaction

Opens real windows: rung 3 of CLAUDE.md's validation ladder, so it needs
a logged-in GUI session. tools/bench-tables.sh probes for that and for a
running matrix before this runs.

--dry-run builds the environment, resolves and checks every artifact,
builds the harness expectation and prints the exact command — then stops
without launching. It proves the plumbing, not a number.
"""

import argparse
import os
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import record  # noqa: E402
from cells import cells  # noqa: E402

CAP = 120.0  # the 2026-08-24 cap, kept so a capped run means what it did

ARTIFACTS = {
    "KAYA_LIB": "target/debug/libkaya.dylib",
    "KAYA_SWIFTUI_LIB": "target/swiftui/libkaya_swiftui.dylib",
}


def harness_script(n):
    """The two steps the mac baseline was taken against."""
    last = "|".join(cells(n - 1))
    return "\n".join([
        'expect_columns column#0 "Date|Ticker|Side|Total"',
        'expect_order row#last "%s"' % last,
    ])


def guest_env(n, chunk):
    env = dict(os.environ)
    env.update({
        "PYTHONPATH": os.path.join(ROOT, "bindings/python"),
        "KAYA_SELFTEST": "rows",
        "KAYA_SELFTEST_SCRIPT": harness_script(n),
        "KAYA_ROWS": str(n),
        "KAYA_CHUNK": str(chunk),
    })
    for key, rel in ARTIFACTS.items():
        env[key] = os.path.join(ROOT, rel)
    return env


def one_run(n, chunk):
    """Returns (wall, script_start, submit_done, verdict, rc)."""
    env = guest_env(n, chunk)
    start = time.time()
    proc = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "rows_guest.py")],
        cwd=ROOT, env=env, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, bufsize=1)
    script_start = submit_done = verdict = wall = None
    tail = []
    while True:
        line = proc.stdout.readline()
        if not line:
            break
        tail = (tail + [line])[-25:]
        now = time.time() - start
        if script_start is None and "KAYA_HARNESS: epoch" in line:
            script_start = now
        if submit_done is None and "KAYA_BENCH: submit_done" in line:
            submit_done = now
        if verdict is None and "KAYA_SELFTEST:" in line:
            verdict, wall = line.strip(), now
        if time.time() - start > CAP:
            proc.kill()
            break
    rc = proc.wait()
    if wall is None:
        wall = time.time() - start
    if verdict is None:
        sys.stderr.write("".join(tail))
    return wall, script_start, submit_done, verdict, rc


def secs(v):
    return "n/a" if v is None else "%.2fs" % v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", default="500,2500,10000,20000")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--chunk", type=int, default=100,
                    help="rows per transaction; 0 = one transaction (PART A)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    counts = [int(x) for x in args.rows.split(",") if x.strip()]
    argv = ["tools/bench/drive_mac.py", "--rows", args.rows,
            "--repeats", str(args.repeats), "--chunk", str(args.chunk)]
    if args.dry_run:
        argv.append("--dry-run")

    missing = [rel for rel in ARTIFACTS.values()
               if not os.path.exists(os.path.join(ROOT, rel))]
    extra = [("chunk", "%d rows per transaction%s" % (
        args.chunk, " (PART A: one transaction)" if args.chunk <= 0 else "")),
        ("cap", "%.0fs per run, then SIGKILL" % CAP)]
    for key, rel in ARTIFACTS.items():
        extra.append((key, rel + (" — MISSING" if rel in missing else "")))
    if args.dry_run:
        extra.append(("dry-run", "YES — nothing was launched, no row was "
                                 "stamped, no number below is a measurement"))
    print(record.header(ROOT, "platform=macos (SwiftUI interpreter)", argv,
                        extra=extra))

    if missing:
        sys.stderr.write("drive_mac: missing artifact(s): %s\n"
                         "  build with: cargo build --locked --lib && "
                         "tools/swiftui/build-dylib.sh\n" % ", ".join(missing))
        return 1

    if args.dry_run:
        n = counts[0]
        env = guest_env(n, args.chunk)
        print("# dry run: the command that a real run would launch, and the")
        print("# harness expectation built from tools/bench/cells.py:")
        print("#   %s %s" % (sys.executable,
                             os.path.join(HERE, "rows_guest.py")))
        for key in sorted(["KAYA_LIB", "KAYA_SWIFTUI_LIB", "KAYA_SELFTEST",
                           "KAYA_ROWS", "KAYA_CHUNK", "PYTHONPATH"]):
            print("#   %s=%s" % (key, env[key]))
        for step in harness_script(n).splitlines():
            print("#   step: %s" % step)
        print(record.line(platform="macos", N=n, repeat="0/0", wall="dry-run",
                          script_start="dry-run", submit_done="dry-run",
                          verdict="NOT-RUN", rc="n/a"))
        return 0

    walls = {}
    for n in counts:
        samples = []
        for r in range(args.repeats):
            wall, script_start, submit_done, verdict, rc = one_run(
                n, args.chunk)
            capped = wall >= CAP
            samples.append(wall)
            print(record.line(
                platform="macos", N=n,
                repeat="%d/%d" % (r + 1, args.repeats),
                wall=secs(wall), script_start=secs(script_start),
                submit_done=secs(submit_done),
                verdict=("CAP-%.0fs" % CAP if capped else
                         "PASS" if verdict and "OK" in verdict else "FAIL"),
                rc=rc), flush=True)
            if verdict:
                print("#   %s" % verdict, flush=True)
        walls[n] = statistics.median(samples)

    print("#")
    for n in counts:
        print(record.line(platform="macos", N=n,
                          median_wall="%.2fs" % walls[n]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
