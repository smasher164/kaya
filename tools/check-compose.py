#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Compile-check the Compose interpreter and the Android app modules; the
# emulator must never be the first compiler to see KayaCompose.kt.
# The javac task is named EXPLICITLY — compileDebugKotlin does not imply
# it, and the Android SDK is a DIFFERENT java.lang from the desktop JDK
# java-typecheck uses, so that gate cannot stand in for this one.
# The kaya module's host-JVM tests run here because no scene freezes a
# scheme byte (docs/deferred.md "THE FULL M3 SCHEME").

import subprocess

STEPS = [
    ([":kaya:compileDebugKotlin"],
     "check-compose: FAIL (KayaCompose.kt does not compile)"),
    ([":kaya:testDebugUnitTest"],
     "check-compose: FAIL (the kaya module's host-JVM tests fail — the "
     "scheme wall is KayaColorSchemesTest)"),
    ([":rusthost:compileDebugKotlin", ":javahost:compileDebugKotlin",
      ":gohost:compileDebugKotlin"],
     "check-compose: FAIL (an Android app module does not compile)"),
    # :gohost is absent here and only here: its guest is Go, in a
    # .so, and it carries no Java of its own for javac to see.
    ([":rusthost:compileDebugJavaWithJavac",
      ":javahost:compileDebugJavaWithJavac"],
     "check-compose: FAIL (a Java guest does not compile for Android)"),
]

for tasks, sentence in STEPS:
    run = subprocess.run(["gradle", "--console=plain", "-q", *tasks],
                         cwd=ROOT / "android", check=False,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, encoding="utf-8", errors="replace")
    sys.stdout.write(run.stdout)
    if run.returncode != 0:
        # THE SENTENCE SAYS WHAT WAS MEASURED: a unit-test task compiles
        # its whole classpath first, so a javac error in the JAVA BINDING
        # fails it too, and it was once reported as the scheme wall
        # (2026-09-03, the drag-source packer's new argument).
        if "error:" in run.stdout and "Compilation failed" in run.stdout:
            failed = [line.strip() for line in run.stdout.split("\n")
                      if "Execution failed for task" in line]
            print(f"check-compose: FAIL (a compile error inside {' '.join(tasks)}: "
                  f"{'; '.join(failed) or 'see javac above'})", file=sys.stderr)
        else:
            print(sentence, file=sys.stderr)
        sys.exit(1)
print("check-compose: OK")
