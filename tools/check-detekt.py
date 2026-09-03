#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# detekt's unused family over every hand-written Kotlin source; the
# compiler cannot serve here (CLAUDE.md's gate list; docs/traps.md:
# detekt's UnusedImports has no type resolution). tools/detekt.yml is the
# WHOLE config, not an overlay on
# detekt's defaults.

import subprocess

CONFIG = ROOT / "tools/detekt.yml"
# Deliberately NOT `android`: that would sweep the gradle build
# directories, where generated sources would decide this gate's verdict.
SOURCES = [
    "android/kaya/src/main/kotlin",
    "android/rusthost/src/main/kotlin",
    "android/javahost/src/main/kotlin",
    "android/gohost/src/main/kotlin",
]

for src in SOURCES:
    if not (ROOT / src).is_dir():
        print(f"check-detekt: no such source tree: {src}")
        sys.exit(1)

# WHAT UnusedImports DOES NOT COVER, since the self-test below would
# otherwise read as a guarantee: it is a TEXT heuristic, so a dead
# import whose short name collides with any identifier in the file stays
# green (docs/traps.md: detekt's UnusedImports has no type resolution).
# The self-test demands every rule fire on a sample that violates all of
# them: a renamed rule in a detekt bump turns a curated config green.
SAMPLE = """\
package sample

import java.util.ArrayList

private class NeverUsed

class Selftest {
    private fun neverCalled() = 1

    // The real defect this gate exists for: computed, then applied
    // nowhere.
    fun render(flag: Boolean, neverRead: Int): String {
        val a11y = if (flag) "id" else ""
        return "rendered"
    }
}
"""

RULES = ["UnusedImports", "UnusedParameter", "UnusedPrivateClass",
         "UnusedPrivateMember", "UnusedPrivateProperty"]

with scratch_dir("check-detekt-") as tmp:
    (tmp / "KayaDetektSelftest.kt").write_text(SAMPLE, encoding="utf-8")
    probe = subprocess.run(
        ["detekt", "--config", str(CONFIG), "--input", str(tmp)],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, check=False)
    missing = [r for r in RULES if f"[{r}]" not in probe.stdout]
    if missing:
        print("check-detekt: self-test failed — these rules did not fire on "
              "a sample that violates every one of them: "
              + " ".join(missing))
        print(probe.stdout, end="")
        sys.exit(1)

run = subprocess.run(
    ["detekt", "--config", str(CONFIG), "--input", ",".join(SOURCES)],
    cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    text=True, check=False)
if run.returncode != 0:
    print(run.stdout.rstrip("\n"))
    print("check-detekt: FAIL (dead code in the Kotlin sources)")
    sys.exit(1)
print("check-detekt: OK")
