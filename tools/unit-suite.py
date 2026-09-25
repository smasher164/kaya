#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# RUNG 1, RUN BY THE SWEEP'S BUILD PHASE.
# `cargo test -p kaya --features harness --locked`
# is the validation ladder's first rung and NOTHING automatic ran it: the
# windows lane runs the core's tests on the GUEST filtered to
# `capi::picked_tests`, the gate sweep never compiled a test binary, and
# the mac suite is a command someone types. So two tests went red on main
# and stayed red across four commits, under a matrix that read ALL PASS
# each time — the spec round trip lost an op when scroll_to_row's record
# was added to the writer and not to the expected list, and
# `park_table_row` was factored out from under its fault guard (found
# 2026-09-24 while the windows drag was being measured).
#
# NOT A GATE, and the reason is mechanical: `cargo test` builds the lib,
# which RELINKS target/debug/libkaya.dylib, and a gate may not — the mac
# lane's guests and the pool's probes load that library by path and a
# launch inside the relink dies in dyld before main (tools/gates.py's
# relink refusal, docs/traps.md 2026-09-21). BUILD is that library's one
# writer, so this runs there, before any gate, and tools/gates.py is its
# one caller.
#
# THE FEATURE IS THE POINT: `harness` is off by default so shipped apps
# carry no scene interpreter, and without it the harness tests SILENTLY
# VANISH rather than failing (CLAUDE.md's ladder). A count that collapses
# is therefore a refusal here, not a pass.

import re
import subprocess

sys.stdout.reconfigure(line_buffering=True)

g = Gate("unit-suite")

# The suite's three binaries on this tree: the lib, the integration test
# and the doc-tests. A floor under the total, not an equality — tests are
# added and removed, and what this must catch is a COLLAPSE.
FLOOR = 600
RESULT = re.compile(r"^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed", re.M)


def census(text, code, floor=FLOOR):
    """The findings in one `cargo test` transcript, and what it counted."""
    bad = []
    runs = RESULT.findall(text)
    if not runs:
        bad.append(
            "cargo test printed no `test result:` line at all — the suite did "
            "not build, and a gate that reads nothing agrees with everything"
        )
        return bad, 0
    passed = sum(int(p) for _, p, _ in runs)
    for verdict, _, failed in runs:
        if verdict != "ok" or int(failed):
            bad.append(
                f"the unit suite is RED: {failed} failed in one of its "
                f"binaries — run `cargo test -p kaya --features harness "
                f"--locked` and read the failures, which this gate does not "
                f"repeat because cargo already printed them above"
            )
            break
    if code != 0 and not bad:
        bad.append(
            f"cargo test left with {code} while every `test result:` line read "
            f"ok — something outside the tests failed (a build script, a "
            f"doc-test compile), and the transcript above says what"
        )
    # THE COLLAPSE, which is the harness feature's own wall: without
    # `--features harness` the 22 harness tests VANISH rather than
    # failing, and a suite reporting a fraction of itself passes
    # everything above.
    if passed < floor:
        bad.append(
            f"the suite reported {passed} passed, below the floor of {floor} "
            f"— a suite that collapsed is not a suite that passed, and the "
            f"first thing to check is whether `--features harness` reached it"
        )
    return bad, passed


if __name__ == "__main__":
    # THE NEGATIVES FIRST, on transcripts rather than on a second cargo
    # run: each is a shape this gate exists to refuse, and a gate whose
    # refusals nobody has watched is a gate nobody has seen work.
    green = "test result: ok. 670 passed; 0 failed; 0 ignored\n"
    for label, text, code, want in (
        ("a red binary reported as a pass",
         green + "test result: FAILED. 12 passed; 2 failed; 0 ignored\n", 101,
         "the unit suite is RED"),
        ("a suite that did not build",
         "error[E0433]: failed to resolve\n", 101,
         "printed no `test result:` line"),
        ("cargo leaving nonzero with every line green",
         green, 101, "left with 101"),
    ):
        g.negative(label, lambda t=text, c=code: census(t, c)[0], want=want)
    # AND THE COLLAPSE, through the census itself: 172 is what the suite
    # reported the last time the harness feature went missing.
    g.negative("the harness tests silently gone",
               lambda: census("test result: ok. 172 passed; 0 failed\n", 0)[0],
               want="below the floor")
    g.negatives_ran(4)

    print("unit-suite: cargo test -p kaya --features harness --locked",
          flush=True)
    run = subprocess.run(
        ["cargo", "test", "-p", "kaya", "--features", "harness", "--locked"],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", check=False)
    transcript = run.stdout + run.stderr
    findings, passed = census(transcript, run.returncode)
    if findings:
        print(transcript, file=sys.stderr)
    for line in findings:
        g.finding(line)
    g.counted("tests passed", passed, FLOOR)
    g.verdict(f"{passed} tests passed across the suite's binaries")
