#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Compile-check the Compose interpreter and the three Android app
# modules — the swift-typecheck/java-typecheck sibling for Kotlin. The
# emulator must never be the first compiler to see KayaCompose.kt.
#
# The Java task is named EXPLICITLY: compileDebugKotlin does not imply
# it, and the Android SDK is a DIFFERENT java.lang from the desktop JDK
# java-typecheck uses, so that gate cannot stand in for this one.
#
# AND THE MODULE'S HOST-JVM TESTS, since the M3 scheme ruling
# (docs/deferred.md "THE FULL M3 SCHEME"): KayaColorSchemes.of() is a
# pure function and KayaColorSchemesTest is its wall — the four seed
# palettes moving, the error family refusing to — run here because no
# scene freezes a scheme byte, so the emulator would otherwise be the
# first and only thing to prove the brand scheme.

import subprocess

STEPS = [
    ([":kaya:compileDebugKotlin"],
     "check-compose: FAIL (KayaCompose.kt does not compile)"),
    ([":kaya:testDebugUnitTest"],
     "check-compose: FAIL (the kaya module's host-JVM tests fail — the "
     "scheme wall is KayaColorSchemesTest)"),
    ([":milestone2:compileDebugKotlin", ":milestone2kt:compileDebugKotlin",
      ":milestone2go:compileDebugKotlin"],
     "check-compose: FAIL (an Android app module does not compile)"),
    # :milestone2go is absent here and only here: its guest is Go, in a
    # .so, and it carries no Java of its own for javac to see.
    ([":milestone2:compileDebugJavaWithJavac",
      ":milestone2kt:compileDebugJavaWithJavac"],
     "check-compose: FAIL (a Java guest does not compile for Android)"),
]

for tasks, sentence in STEPS:
    run = subprocess.run(["gradle", "--console=plain", "-q", *tasks],
                         cwd=ROOT / "android", check=False)
    if run.returncode != 0:
        print(sentence, file=sys.stderr)
        sys.exit(1)
print("check-compose: OK")
