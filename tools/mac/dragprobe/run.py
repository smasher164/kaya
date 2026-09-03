#!/usr/bin/env python3
"""Build and drive the mac drag probe — docs/dnd-plan.md §2 probe 3.

Two binaries, run as SEPARATE PROCESSES, once BARE and once inside a .app
bundle whose Info.plist carries UTExportedTypeDeclarations (the thing the
report probe 3 is about blames): the source writes the drag pasteboard by
one route per run, the receiver reads it back and drives the real
NSDraggingDestination arms through an NSDraggingInfo double (D10's mac
route). THE GESTURE IS NOT DRIVEN — real input is refused in this repo.

Build products go to target/mac-dragprobe, never beside the sources.
THROWAWAY; a probe, not a lane.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

import shutil
import subprocess

HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "target/mac-dragprobe"
ROUTES = ["board", "item", "writer", "provider", "session", "session-writer", "session-board"]
# `clear` is not in ROUTES: it is the hygiene route, run last by hand.

PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>{exe}</string>
  <key>CFBundleIdentifier</key><string>dev.kaya.dragprobe.{tag}</string>
  <key>CFBundleName</key><string>{exe}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>dev.kaya.note</string>
      <key>UTTypeDescription</key><string>kaya note (reverse-DNS)</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.mime-type</key><array><string>dev.kaya/note</string></array>
      </dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>dev.kaya/note</string>
      <key>UTTypeDescription</key><string>kaya note (MIME-shaped, illegal as a UTI)</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
"""


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ["src", "recv"]:
        binary = OUT / f"dragprobe-{name}"
        cmd = subprocess.run(
            ["bash", "-c",
             'source "$1/tools/lib/swift-toolchain.sh" && cd "$1" && '
             'kaya_swiftc -O -o "$3" "$2" '
             "-framework AppKit -framework UniformTypeIdentifiers",
             "swift-toolchain", str(ROOT), str(HERE / f"{name}.swift"), str(binary)],
            check=False)
        if cmd.returncode != 0:
            print(f"dragprobe: {name}.swift did not compile", file=sys.stderr)
            sys.exit(1)
    for name, exe, tag in [("src", "DragProbeSrc", "src"), ("recv", "DragProbeRecv", "recv")]:
        app = OUT / f"{exe}.app"
        (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(OUT / f"dragprobe-{name}", app / "Contents/MacOS" / exe)
        (app / "Contents/Info.plist").write_text(
            PLIST.format(exe=exe, tag=tag), encoding="utf-8")


def run(binary, args, label):
    """One probe process; stdout and stderr both, because the UTI complaint
    macOS makes about a slashed type is a CONSOLE log, not a return value."""
    p = subprocess.run([str(binary)] + args, check=False,
                       capture_output=True, text=True)
    print(f"--- {label} (exit {p.returncode})")
    print(p.stdout, end="")
    if p.stderr:
        for line in p.stderr.splitlines():
            print(f"    stderr| {line}")
    return p


def main():
    build()
    only = sys.argv[1:]
    shapes = [("UNBUNDLED", OUT / "dragprobe-src", OUT / "dragprobe-recv"),
              ("BUNDLED", OUT / "DragProbeSrc.app/Contents/MacOS/DragProbeSrc",
               OUT / "DragProbeRecv.app/Contents/MacOS/DragProbeRecv")]
    for shape, src, recv in shapes:
        for route in (only or ROUTES):
            print(f"\n======== {shape} route={route} ========")
            run(src, [route], f"{shape} source {route}")
            run(recv, [], f"{shape} receiver after {route}")


main()
