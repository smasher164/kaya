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
    # The windows, ios and android rosters are DATA since the runner
    # conversion: a tools/lib/lanes/ row is IMPORTED with a roster
    # floor — a regex over a module whose lists hold bare scene names
    # would agree with everything.
    ("tools/lib/lanes/win.py", "crates/kaya/src/winui/mod.rs", ""),
    ("tools/validate-mac.sh", "swift/KayaSwiftUI.swift", "macos"),
    ("tools/lib/lanes/ios.py", "swift/KayaSwiftUI.swift", "ios"),
    ("tools/lib/lanes/android.py",
     "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt", ""),
]


def lane_scenes(runner):
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "kaya_lane_stubs", ROOT / runner)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    wired = set(mod.wired_scenes())
    if len(wired) < 10:
        print(f"check-stubs: {runner} answered {len(wired)} wired scenes "
              f"— a roster that small is a moved table, and this census "
              f"would agree with anything", file=sys.stderr)
        sys.exit(1)
    return wired


def stubbed(scene, backend_text, platform):
    # Matched on the SUFFIX of the name, because each language keeps its
    # own casing and prefix. check-steps greps the same way.
    needles = [f'epth_stub("{scene}")', f'epthStub("{scene}")']
    if platform:
        needles.append(f'epthStub("{scene}", on: "{platform}")')
    return any(n in backend_text for n in needles)


def check(scenes, runner_name, runner_text, backend_name, backend_text,
          platform, wired_set=None):
    """Findings for one runner/backend pair — the census the negative
    below runs in-process, so it cannot drift from the real one. A lane
    module's roster arrives as `wired_set` (imported); shell runners
    keep the leg-spelling regex over their text."""
    out = []
    for scene in scenes:
        stub = f'depth_stub("{scene}")'
        if wired_set is not None:
            wired = scene in wired_set
        else:
            wired = re.search(rf"\b{re.escape(scene)}[-_](?:{LANGS})",
                              runner_text)
        if wired and stubbed(scene, backend_text, platform):
            out.append(f"check-stubs: {runner_name} wires '{scene}' legs but "
                       f"{backend_name} still stubs it ({stub})")
    return out


status = 0
scenes = sorted(p.stem for p in (ROOT / "tools/scenes").glob("*.steps"))
for runner, backend, platform in PAIRS:
    wired_set = (lane_scenes(runner)
                 if runner.startswith("tools/lib/lanes/") else None)
    findings = check(
        scenes, runner, (ROOT / runner).read_text(encoding="utf-8"),
        backend, (ROOT / backend).read_text(encoding="utf-8"), platform,
        wired_set=wired_set)
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
