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
        MEASURED 2026-09-03 (evening): it lands — 9 of 10 runs read all
        three representations with `entered local false`.
    tools/mac/dragwitness/run.py --hand     THE HAND RUN: kaya's dnd guest
        and the witness windows come up on this desktop, the terminal says
        what to drag where, a person drags, and BOTH sides' bytes are
        verified here — kaya's harness verdict and the witness's report.
        This is the mac half of §5 step 7: it is what confirms kaya READS
        a foreign drop's bytes, which the automated feasibility leg
        (tools/mac/dragwitness-leg.py) cannot — kaya reads the drag
        pasteboard empty under synthetic input (docs/traps.md).

The binary is target/mac-dragwitness/kaya-drag-witness. THE POINTER IS
DESKTOP-GLOBAL: nothing else may be driving it when `--pair` runs, and
`--hand` wants a person at the mouse.
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


HAND_TEXT = "kaya-foreign-text"
HAND_FILE = "witness.txt"
HAND_BYTES = "witness bytes"
HAND_WAIT_MS = 60000


def hand():
    """kaya + the witness on this desktop; a PERSON drags; this verifies.
    kaya is launched FIRST with KAYA_WINDOW_FRONT=1, which puts its window
    at the floating level (a witness quitting re-activates the terminal,
    whose window then covered kaya's between steps) and prints its screen
    frame; the witness opens in the free strip beside it. Three drags, each
    given HAND_WAIT_MS: the witness's blue square onto kaya's `text
    target`, a fresh blue square onto `files target`, then kaya's `hello`
    into the witness's catch window. kaya's own lines stream here as they
    arrive, so a window that never came up says so at once."""
    import os
    import threading
    sys.path.insert(0, str(ROOT / "tools/lib/lanes"))
    import mac as lane
    guest = ROOT / lane.RUST_GUESTS / "dnd"
    if not guest.is_file():
        print(f"dragwitness: {guest} is not staged — run `tools/run-leg.py dnd rust --build` first",
              file=sys.stderr)
        sys.exit(2)
    scratch = OUT / "hand"
    scratch.mkdir(parents=True, exist_ok=True)
    offered = scratch / HAND_FILE
    offered.write_text(HAND_BYTES, encoding="utf-8")
    scene = "\n".join([
        'expect label#4 "no drop yet"',
        f"settle {HAND_WAIT_MS}",
        f'expect label#4 "text target got text {HAND_TEXT} (copy)"',
        f"settle {HAND_WAIT_MS}",
        f'expect label#4 "files target got {HAND_FILE} {HAND_BYTES} (copy)"',
        f"settle {HAND_WAIT_MS}",
        'expect label#5 "drag ended copy"',
        "",
    ])
    env = dict(os.environ)
    env.update(lane.leg_env(ROOT, "dnd", "rust", ""))
    env["KAYA_SELFTEST"] = "dnd"
    env["KAYA_SELFTEST_SCRIPT"] = scene
    # An accessory app's window opens BEHIND the terminal; the interpreter
    # raises it on this knob, which no lane sets.
    env["KAYA_WINDOW_FRONT"] = "1"
    kaya = subprocess.Popen(lane.leg_argv("dnd", "rust", lambda _n: ""), cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8")
    kaya_lines = []

    def pump():
        for line in kaya.stdout:
            kaya_lines.append(line.rstrip("\n"))
            print(f"    kaya: {line.rstrip()}", flush=True)
    threading.Thread(target=pump, daemon=True).start()

    # kaya's window is up once the harness has passed its first expect.
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and not any("no drop yet" in l for l in kaya_lines):
        if kaya.poll() is not None:
            print("dragwitness --hand: kaya's guest exited before its window came up; its lines "
                  "are above", file=sys.stderr)
            sys.exit(1)
        time.sleep(0.1)
    if not any("no drop yet" in l for l in kaya_lines):
        print("dragwitness --hand: kaya's window did not come up within 20s; its lines are above",
              file=sys.stderr)
        kaya.kill()
        sys.exit(1)
    front = [l for l in kaya_lines if "windowfront wid=0 " in l]
    if not front:
        print("dragwitness --hand: kaya printed no windowfront line — the interpreter predates "
              "KAYA_WINDOW_FRONT; rebuild with `tools/run-leg.py dnd rust --build`", file=sys.stderr)
        kaya.kill()
        sys.exit(1)
    fields = dict(part.split("=") for part in front[-1].split("windowfront ")[1].split())
    fx, fy, fw, fh = (int(v) for v in fields["frame"].split(","))
    sw, sh = (int(v) for v in fields["screen"].split(","))
    ww, wh = 300, 200
    if fx >= ww + 40:
        wx, side = fx - ww - 20, "LEFT of"
    elif sw - (fx + fw) >= ww + 40:
        wx, side = fx + fw + 20, "RIGHT of"
    else:
        wx, side = max(0, min(fx, sw - ww)), ("BELOW" if fy + fh + wh + 40 <= sh else "ABOVE")
    wy = fy + fh // 2 - wh // 2 if side.endswith("of") else (fy + fh + 20 if side == "BELOW" else max(40, fy - wh - 20))
    at = f"{wx},{wy},{ww},{wh}"
    print(f"\nkaya's window is up: the one titled 'dnd' with the labels hello / text target / "
          f"note target / files target, at {fx},{fy} size {fw}x{fh} on a {sw}x{sh} screen. "
          f"The witness opens {side} it.", flush=True)
    wait_s = HAND_WAIT_MS // 1000
    steps = [
        ("throw", f"1. Drag the BLUE SQUARE from the 'kaya drag witness' window ({side.lower()} kaya's) "
                  f"onto kaya's 'text target' label ({wait_s}s).", "drag ended copy"),
        ("throw", f"2. A fresh witness window: drag its BLUE SQUARE onto kaya's 'files target' "
                  f"label ({wait_s}s).", "drag ended copy"),
        ("catch", f"3. Drag kaya's 'hello' label INTO the 'kaya drag witness' window ({wait_s}s).",
                  "text hello"),
    ]
    reports = []
    ok = True
    try:
        for mode, say, need in steps:
            report = scratch / f"{mode}-{len(reports)}.txt"
            report.unlink(missing_ok=True)
            args = [str(BINARY), mode, "--at", at, "--report", str(report), "--hold", str(wait_s + 20)]
            if mode == "throw":
                args += ["--file", str(offered)]
            w = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f"\n>>> {say}", flush=True)
            try:
                w.wait(timeout=wait_s + 25)
            except subprocess.TimeoutExpired:
                w.terminate()
            got = report.read_text(encoding="utf-8") if report.is_file() else ""
            reports.append(got)
            landed = need in got
            ok = ok and landed
            print(f"    witness: {'landed — ' if landed else 'DID NOT SEE IT — '}"
                  + " / ".join(line for line in got.splitlines() if line), flush=True)
    finally:
        try:
            kaya.wait(timeout=wait_s + 30)
        except subprocess.TimeoutExpired:
            kaya.kill()
            kaya.wait(timeout=5)
    verdict = [line for line in kaya_lines if "KAYA_SELFTEST:" in line]
    print("\nkaya's own verdict:", verdict[-1] if verdict else "<none>", flush=True)
    if ok and verdict and "KAYA_SELFTEST: OK" in verdict[-1]:
        print("dragwitness --hand: BOTH DIRECTIONS VERIFIED — the witness read kaya's text and "
              "custom id, kaya read the witness's text and file through the picked table")
    else:
        print("dragwitness --hand: NOT VERIFIED — see the witness lines and kaya's verdict above",
              file=sys.stderr)
        sys.exit(1)


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
    elif "--hand" in args:
        hand()
    elif "--board" in args:
        board()
    elif "--selftest" in args:
        selftest()
    elif "--build" not in args:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


main()
