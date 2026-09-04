#!/usr/bin/env python3
"""Build the mac foreign drag witness, and drive it by hand.

    tools/mac/dragwitness/run.py --build
    tools/mac/dragwitness/run.py --board    the cross-process byte exchange:
        one process composes kaya's payload grammar on a named system
        pasteboard, ANOTHER opens it by name and reads all three
        representations back, the MIME-shaped custom id included.
    tools/mac/dragwitness/run.py --selftest the watched negative: an empty
        NSPasteboardItem is 0 pasteboard items and AppKit throws.
    tools/mac/dragwitness/run.py --pair     the feasibility measurement:
        a witness `catch` and a witness `throw`, two SEPARATE PROCESSES
        neither of which is kaya, and a real cross-process drag between
        them driven by posted CGEvents (docs/dnd-plan.md §5 step 7).

The binary is target/mac-dragwitness/kaya-drag-witness. NO LANE RUNS THIS
YET, and the reason is `--pair`'s own answer: a real cross-process drag
cannot be driven on this host, so §5 step 7's two mac legs have no driver
(docs/probes/dnd-witness-mac-2026-09-03.md).
THE POINTER IS DESKTOP-GLOBAL: nothing else may be driving it when
`--pair` runs.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

import shutil
import subprocess
import time

HERE = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "target/mac-dragwitness"
BINARY = OUT / "kaya-drag-witness"


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    got = subprocess.run(
        ["bash", "-c",
         'source "$1/tools/lib/swift-toolchain.sh" && cd "$1" && '
         'kaya_swiftc -O -o "$3" "$2" -framework AppKit',
         "swift-toolchain", str(ROOT), str(HERE / "witness.swift"), str(BINARY)],
        check=False)
    if got.returncode != 0:
        print("dragwitness: witness.swift did not compile", file=sys.stderr)
        sys.exit(1)
    return BINARY


PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>KayaDragWitness</string>
  <key>CFBundleIdentifier</key><string>dev.kaya.dragwitness</string>
  <key>CFBundleName</key><string>KayaDragWitness</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
"""


def bundle():
    """The same binary inside a .app — a variable in the feasibility
    measurement (docs/probes/dnd-witness-mac-2026-09-03.md)."""
    app = OUT / "KayaDragWitness.app"
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copy2(BINARY, app / "Contents/MacOS/KayaDragWitness")
    (app / "Contents/Info.plist").write_text(PLIST, encoding="utf-8")
    return app / "Contents/MacOS/KayaDragWitness"


def pair():
    """Foreign to foreign: does a real cross-process drag land at all?"""
    scratch = OUT / "scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    dropped = scratch / "witness.txt"
    dropped.write_text("witness bytes", encoding="utf-8")
    caught, thrown = scratch / "caught.txt", scratch / "thrown.txt"
    for stale in (caught, thrown):
        stale.unlink(missing_ok=True)
    # Both windows FLOATING and in the bottom-left corner, so every posted
    # click lands on a window of ours and not on whatever else is open.
    exe = bundle() if "--bundled" in sys.argv else BINARY
    extra = ["--policy", "regular"] if "--regular" in sys.argv else []
    dest = subprocess.Popen(
        [str(exe), "catch", "--at", "40,700,300,200", "--report", str(caught)] + extra)
    src = subprocess.Popen(
        [str(exe), "throw", "--at", "420,700,300,200", "--file", str(dropped),
         "--report", str(thrown)] + extra)
    time.sleep(1.5)
    drive = subprocess.Popen(
        [str(BINARY), "drive", "--press", "570,800", "--to", "190,800"])
    drive.wait(timeout=60)
    src.wait(timeout=60)
    dest.wait(timeout=60)
    for name, path in (("catch", caught), ("throw", thrown)):
        print(f"--- {name} report")
        print(path.read_text(encoding="utf-8") if path.is_file() else "<none>")


def board():
    """THE CROSS-PROCESS BYTE EXCHANGE, with no gesture in it: one process
    composes kaya's payload grammar on a named system pasteboard, ANOTHER
    opens it by name and says what it read. The MIME-shaped custom id is
    the point — macOS refuses it at NSPasteboardItem level."""
    scratch = OUT / "scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    dropped = scratch / "witness.txt"
    dropped.write_text("witness bytes", encoding="utf-8")
    wrote, read = scratch / "wrote.txt", scratch / "read.txt"
    for stale in (wrote, read):
        stale.unlink(missing_ok=True)
    name = "dev.kaya.witness"
    subprocess.run([str(BINARY), "throw", "--at", "40,700,10,10", "--board", name,
                    "--file", str(dropped), "--report", str(wrote)], check=False)
    subprocess.run([str(BINARY), "catch", "--at", "40,700,10,10", "--board", name,
                    "--report", str(read)], check=False)
    got = read.read_text(encoding="utf-8") if read.is_file() else ""
    print("--- read back in a second process")
    print(got, end="")
    want = ("text kaya-foreign-text\n"
            "custom dev.kaya/note 8 bytes\n"
            "file witness.txt\n")
    if got != want:
        print(f"dragwitness: the foreign read does not match; wanted\n{want}",
              file=sys.stderr)
        sys.exit(1)
    print("dragwitness: the foreign process read all three representations")


def selftest():
    """THE WATCHED NEGATIVE for the shipped-crash class (docs/traps.md): an
    empty NSPasteboardItem is ZERO pasteboard items and AppKit throws the
    moment a session is begun with it. Both shapes are run and the refusal
    is demanded, because a guard nobody has seen fire is not a guard."""
    scratch = OUT / "scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    reds = 0
    for shape, want_ok in (("empty", False), ("1", True)):
        out = scratch / f"constructed-{shape}.txt"
        out.unlink(missing_ok=True)
        got = subprocess.run(
            [str(BINARY), "throw", "--at", "40,700,200,120", "--constructed", shape,
             "--report", str(out)],
            check=False, capture_output=True, text=True, encoding="utf-8")
        threw = "NSGenericException" in got.stderr or got.returncode != 0
        print(f"--- writer={shape} exit {got.returncode} threw={threw}")
        if threw == want_ok:
            print(f"dragwitness: writer={shape} answered the wrong way — the "
                  f"empty writer must throw and the filled one must not",
                  file=sys.stderr)
            sys.exit(1)
        reds += 1 if threw else 0
    print(f"dragwitness: 1 of 2 shapes threw as measured ({reds} red)")


def main():
    args = sys.argv[1:]
    build()
    if "--pair" in args:
        pair()
    elif "--board" in args:
        board()
    elif "--selftest" in args:
        selftest()
    elif "--build" not in args:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


main()
