#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, TARGET, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# THE MACOS PANE LADDER (docs/multicolumn-plan.md MECHANICS AMENDMENTS).
# No shared scene can pin the middle rung: the platforms legitimately
# disagree at every width inside check-steps' panes band.
#   A  STATIC, any host: no column MINIMUM declared to SwiftUI (amendment
#      1 — a declared minimum becomes the WINDOW's floor, so collapse can
#      never fire and resize_window silently no-ops). Ideal widths are fine.
#   B  RUNTIME, macOS only, SKIPPED AND SAID SO elsewhere:
#      tools/checks/swiftui-pane-ladder.swift compiled into the
#      interpreter's own module and run.

import os
import platform
import subprocess

# Line-buffered stdout: clause B's subprocesses write to the same fd,
# and block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

SWIFTUI = "swift/KayaSwiftUI.swift"
PROBE = "tools/checks/swiftui-pane-ladder.swift"


def scan_min(path, text):
    # Comments are not exempt: a commented example is what the next
    # reader pastes.
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
    if not (TARGET / "debug/libkaya.dylib").is_file():
        print(f"check-pane-ladder: {TARGET}/debug/libkaya.dylib is not built — "
              "the probe links against it. Run tools/gates.py, which builds "
              "what its gates read.", file=sys.stderr)
        sys.exit(1)
    with scratch_dir("check-pane-ladder-") as tmp:
        # The probe compiles the interpreter's OWN source, so no
        # interpreter artifact in this path can go stale.
        def build_probe(source, out):
            return subprocess.run(
                ["bash", "-c",
                 'source "$1/tools/lib/swift-toolchain.sh" && cd "$1" && '
                 "kaya_swiftc "
                 "-import-objc-header crates/kaya/include/kaya.h "
                 '"$2" "$3" -L "$5" -lkaya '
                 "-framework AppKit -framework Foundation -o \"$4\"",
                 "swift-toolchain", str(ROOT), str(source), PROBE,
                 str(out), str(TARGET / "debug")],
                check=False)

        def run_probe(binary):
            return subprocess.run(
                [str(binary)], env=dict(os.environ, DYLD_LIBRARY_PATH=str(TARGET / "debug")),
                check=False, capture_output=True, text=True, encoding="utf-8")

        if build_probe(ROOT / SWIFTUI, tmp / "swiftui-pane-ladder").returncode != 0:
            print("check-pane-ladder: the ladder probe did not compile",
                  file=sys.stderr)
            sys.exit(1)
        run = run_probe(tmp / "swiftui-pane-ladder")
        print(run.stdout, end="")
        # NG1 (M16 F1): the grid's old unproposed answer, its cells end to
        # end, must be named by the probe's third half.
        old = ("?? (minWidth * CGFloat(subviews.count) + spacing * "
               "CGFloat(max(0, subviews.count - 1)))")
        floor = "let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minWidth"
        n = swiftui_text.count(floor)
        doctored = swiftui_text.replace(floor, floor.replace("?? minWidth", old))
        print(f"check-pane-ladder: self-test NG1 put the grid's cells-end-to-end ideal back, "
              f"{n} substitution(s)")
        (tmp / "doctored.swift").write_text(doctored, encoding="utf-8")
        if n != 1 or build_probe(tmp / "doctored.swift", tmp / "doctored").returncode != 0:
            print("check-pane-ladder: SELF-TEST NG1 did not apply or did not compile",
                  file=sys.stderr)
            sys.exit(1)
        red = run_probe(tmp / "doctored")
        if red.returncode == 0 or "an auto grid's ideal width is" not in red.stdout:
            print("check-pane-ladder: SELF-TEST NG1 FAIL — a grid whose ideal is its cells "
                  "end to end passed the probe", file=sys.stderr)
            sys.exit(1)
        print("check-pane-ladder: self-test NG1 red: " + next(
            line for line in red.stdout.splitlines() if "ideal width is" in line).strip())
        if run.returncode != 0:
            print(f"check-pane-ladder: FAIL — the ladder probe exited "
                  f"{run.returncode} (its own output", file=sys.stderr)
            print("  names the rung that did not materialize).",
                  file=sys.stderr)
            sys.exit(1)
    print("check-pane-ladder: OK")
