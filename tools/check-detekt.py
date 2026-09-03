#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# The dead-code gate for the Kotlin layer: detekt's unused family over
# every hand-written Kotlin source. tools/detekt.yml is the WHOLE
# config, not an overlay on detekt's defaults.
#
# The Kotlin compiler cannot serve here: K2 moved the UNUSED_*
# diagnostics into IDE inspections (KT-69698, docs/traps.md), so a
# computed-and-never-applied local compiles clean.

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

# WHAT UnusedImports DOES NOT COVER, stated here because the self-test
# below passes for it and would otherwise read as a guarantee. The rule
# is a TEXT heuristic — it has no type resolution, so an import counts
# as used if its short name appears anywhere in the file, whoever owns
# that name. Measured 2026-07-27: the Compose split arm stopped calling
# `Modifier.width()`, the `androidx.compose.foundation.layout.width`
# import went dead, and this gate stayed green because the file is full
# of unrelated `bitmap.width` / `root.width` property reads. A
# word-boundary check written here would miss it for the same reason;
# only running detekt with --classpath (the full Android + Compose
# classpath, which this deliberately standalone gate does not have)
# distinguishes the extension from the property. So: dead imports whose
# name is unique DO fail here, and dead imports whose name collides
# with any identifier in the file DO NOT. Reach for the import list by
# hand when a call site is removed.
#
# Self-test: a sample carrying one instance of each rule's defect must
# make ALL of them fire — a renamed rule in a detekt bump would
# otherwise turn a curated config green forever.
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
