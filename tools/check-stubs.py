#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# The wired-legs-vs-stubbed-backend guard: for each runner that carries
# legs for a scene, the runner's backend must not stub that scene's
# feature. Stubs COMPILE, so nothing else sees the combination.
#
# THE STUB IS A CALL, NOT A SENTENCE: `depth_stub("<scene>")` in Rust,
# `depthStub("<scene>")` in Kotlin, `kayaDepthStub(_:on:)` in Swift. A
# backend that refuses in its own words is invisible here, which is what
# the vacuity guard below is for.

import re
import subprocess

LANGS = "rust|python|go|csharp|java|swift|ocaml|haskell|compose|jvm|swiftui"

PAIRS = [
    ("tools/linux/run-suites.sh", "crates/kaya/src/gtk.rs", ""),
    # The windows roster is DATA since the runner conversion: the legs
    # are quoted names in the lane module, which the same regex reads.
    ("tools/lib/lanes/win.py", "crates/kaya/src/winui/mod.rs", ""),
    ("tools/validate-mac.sh", "swift/KayaSwiftUI.swift", "macos"),
    ("tools/ios/run-sim.sh", "swift/KayaSwiftUI.swift", "ios"),
    ("tools/android/run-emulator.sh",
     "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt", ""),
]


def stubbed(scene, backend_text, platform):
    # Matched on the SUFFIX of the name, because each language keeps its
    # own casing and prefix. check-steps greps the same way.
    needles = [f'epth_stub("{scene}")', f'epthStub("{scene}")']
    if platform:
        needles.append(f'epthStub("{scene}", on: "{platform}")')
    return any(n in backend_text for n in needles)


def check(scenes, runner_name, runner_text, backend_name, backend_text,
          platform):
    """Findings for one runner/backend pair — the census the negative
    below runs in-process, so it cannot drift from the real one."""
    out = []
    for scene in scenes:
        stub = f'depth_stub("{scene}")'
        wired = re.search(rf"\b{re.escape(scene)}[-_](?:{LANGS})", runner_text)
        if wired and stubbed(scene, backend_text, platform):
            out.append(f"check-stubs: {runner_name} wires '{scene}' legs but "
                       f"{backend_name} still stubs it ({stub})")
    return out


status = 0
scenes = sorted(p.stem for p in (ROOT / "tools/scenes").glob("*.steps"))
for runner, backend, platform in PAIRS:
    findings = check(
        scenes, runner, (ROOT / runner).read_text(encoding="utf-8"),
        backend, (ROOT / backend).read_text(encoding="utf-8"), platform)
    for line in findings:
        print(line, file=sys.stderr)
    if findings:
        status = 1

# The guard guards itself: a synthesized wired-and-stubbed pair must
# fail — run through the REAL check above, not a re-typed copy of it.
if not check(["fakescene"], "runner.sh", "run fakescene-rust something",
             "backend.rs", 'crate::depth_stub("fakescene");', ""):
    print("check-stubs: SELF-TEST FAIL (bad sample passed)", file=sys.stderr)
    sys.exit(1)

# THE VACUITY GUARD: any not-implemented refusal in a backend must go
# through the helper, or the rule above cannot see it.
if subprocess.run([sys.executable, "tools/lib/hand-rolled-stubs.py"],
                  cwd=ROOT, check=False).returncode != 0:
    status = 1

# STUB IMPLIES LEDGER. A depth stub is SILENT — it holds a scene's legs
# off a runner and both rules above read green — so every declaration
# must have an OPEN entry in docs/deferred.md naming the scene and the
# backend. Struck-through entries do not count: a closed entry says the
# hole was filled, and a backend still refusing contradicts it.
if subprocess.run([sys.executable, "tools/lib/stub-ledger.py"],
                  cwd=ROOT, check=False).returncode != 0:
    status = 1

if status != 0:
    sys.exit(1)
print("check-stubs: OK")
