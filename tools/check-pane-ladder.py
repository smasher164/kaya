#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# THE MACOS PANE LADDER (docs/multicolumn-plan.md MECHANICS AMENDMENTS).
# macOS has no compact mode to defer to, so kaya's own arithmetic
# decides how many of a three-pane window's columns fit — and no shared
# scene can pin the middle rung, because the platforms legitimately
# disagree at every width inside check-steps' panes band. This gate is
# where the ladder lives or dies:
#
#   A  STATIC, any host: the interpreter never declares a column
#      MINIMUM to SwiftUI. A declared minimum becomes the WINDOW's
#      floor — the collapse rule can then never fire and resize_window
#      turns into a silent no-op (measured; amendment 1). Ideal widths
#      are fine.
#   B  RUNTIME, macOS only — tools/checks/swiftui-pane-ladder.swift
#      compiled INTO the interpreter's own module and run: the rung
#      arithmetic (including content+detail < 600, which is what keeps
#      the bare expect_panes invariant true at every regular width),
#      the edge-triggered command rule the sidebar toggle depends on,
#      and the REAL NSSplitView walked 1400 -> 700 -> 1400 with its
#      visible columns counted at each rung. SKIPPED AND SAID SO on any
#      other host.

import os
import platform
import subprocess

# Line-buffered stdout: clause B's subprocesses write to the same fd,
# and block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

SWIFTUI = "swift/KayaSwiftUI.swift"
PROBE = "tools/checks/swiftui-pane-ladder.swift"


def scan_min(path, text):
    # Offender lines. Comments are not exempt: a commented example is
    # what the next reader pastes.
    bad = []
    for n, line in enumerate(text.splitlines(), 1):
        if "navigationSplitViewColumnWidth(min" in line.replace(" ", ""):
            bad.append(f"{path}:{n}: {line.strip()}")
    return bad


swiftui_text = (ROOT / SWIFTUI).read_text(encoding="utf-8")

# --- Clause A: no declared column minimum, anywhere. -----------------
offenders = scan_min(SWIFTUI, swiftui_text)
if offenders:
    print("check-pane-ladder: FAIL — a column MINIMUM is declared to "
          "SwiftUI.", file=sys.stderr)
    print("\n".join(offenders), file=sys.stderr)
    print("  A declared minimum becomes the WINDOW's floor: collapse can "
          "never", file=sys.stderr)
    print("  fire and resize_window silently no-ops "
          "(docs/multicolumn-plan.md", file=sys.stderr)
    print("  MECHANICS AMENDMENTS 1). Declare ideal widths only; the "
          "minimums", file=sys.stderr)
    print("  live in kayaPaneMin* and are handed to nobody.",
          file=sys.stderr)
    sys.exit(1)

# The guard guards itself: a doctored copy carrying a min: declaration
# must fail, and the perturbation must be PROVEN applied.
NEEDLE = ".navigationSplitViewColumnWidth(ideal: 220)"
count = swiftui_text.count(NEEDLE)
print(f"check-pane-ladder: self-test perturbation applied {count} time(s)")
if count != 1:
    print(f"check-pane-ladder: SELF-TEST FAIL — wanted exactly 1 site for "
          f"{NEEDLE!r}, found {count}; the negative no longer perturbs what "
          f"it thinks it does", file=sys.stderr)
    sys.exit(1)
doctored = swiftui_text.replace(
    NEEDLE, ".navigationSplitViewColumnWidth(min: 180, ideal: 220)")
if not scan_min("doctored.swift", doctored):
    print("check-pane-ladder: SELF-TEST FAIL — a doctored min: declaration "
          "passed the scan", file=sys.stderr)
    sys.exit(1)

# --- Clause B: the runtime ladder, where a GUI toolkit exists. -------
if platform.system() != "Darwin":
    print("check-pane-ladder: OK (static clause; the runtime ladder needs "
          "macOS and was SKIPPED)")
else:
    if not (ROOT / "target/debug/libkaya.dylib").is_file():
        print("check-pane-ladder: target/debug/libkaya.dylib is not built — "
              "the probe links against it. Run tools/gates.py, which builds "
              "what its gates read.", file=sys.stderr)
        sys.exit(1)
    with scratch_dir("check-pane-ladder-") as tmp:
        # The probe compiles the interpreter's OWN source, so there is
        # no interpreter artifact in this path to go stale. The
        # toolchain resolution stays in tools/lib/swift-toolchain.sh —
        # ONE copy; shell launches, python decides (the conversion
        # ruling's boundary).
        build = subprocess.run(
            ["bash", "-c",
             'source "$1/tools/lib/swift-toolchain.sh" && cd "$1" && '
             "kaya_swiftc "
             "-import-objc-header crates/kaya/include/kaya.h "
             '"$2" "$3" -L target/debug -lkaya '
             "-framework AppKit -framework Foundation -o \"$4\"",
             "swift-toolchain", str(ROOT), SWIFTUI, PROBE,
             str(tmp / "swiftui-pane-ladder")],
            check=False)
        if build.returncode != 0:
            print("check-pane-ladder: the ladder probe did not compile",
                  file=sys.stderr)
            sys.exit(1)
        run = subprocess.run(
            [str(tmp / "swiftui-pane-ladder")],
            env=dict(os.environ,
                     DYLD_LIBRARY_PATH=str(ROOT / "target/debug")),
            check=False)
        if run.returncode != 0:
            print(f"check-pane-ladder: FAIL — the ladder probe exited "
                  f"{run.returncode} (its own output", file=sys.stderr)
            print("  names the rung that did not materialize).",
                  file=sys.stderr)
            sys.exit(1)
    print("check-pane-ladder: OK")
