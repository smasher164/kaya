#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE MACOS WINDOW MEMORY (docs/tasks-s4-plan.md §4). GTK and WinUI each
# hold this rule in a unit test (gtk::frame_tests,
# winui::tests::window_memory_parses_clamps_and_opts_out); this is the
# macOS third. NO SCENE CAN SEE ANY OF IT: tools/scenes/taskspersist.steps
# asserts ONE size on ONE window and stays green with the by-value rule
# inverted, with the clamp gone, with a malformed stored line taken at face
# value and with the opt-out ignored.
#   A  STATIC, any host: the save rides DispatchQueue.main.async and
#      nothing delayed, it is deduplicated twice over (once per run-loop
#      turn, once against what the store holds), and the restore runs at
#      the accessor's registration, after the declaration and without
#      forcing a display pass.
#   B  RUNTIME, macOS only, SKIPPED AND SAID SO elsewhere: the
#      interpreter's own `// MARK: - Window memory` block, cut out here and
#      compiled with tools/checks/swiftui-window-memory.swift, drives the
#      six by-value cases, both frame spellings and six malformed lines,
#      the clamp, the coalesced-and-deduplicated save and the opt-out —
#      then each by-value case is perturbed on the cut and watched failing.

import os
import platform
import re
import subprocess

# Line-buffered stdout: clause B's subprocesses write to the same fd, and
# block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

SWIFTUI = "swift/KayaSwiftUI.swift"
PROBE = "tools/checks/swiftui-window-memory.swift"
BLOCK_START = "    // MARK: - Window memory (docs/tasks-s4-plan.md P4)"
BLOCK_END = "\n    final class KayaWindowDelegate"

# A SAVE THAT WAITS LOSES THE VALUE (docs/tasks-s4-plan.md §4, measured on
# the linux lane 2026-09-09): the process leaves through `_exit`, so a
# trailing write never runs and the store keeps the DECLARED size. Every
# spelling that puts the write on a clock instead of the next turn.
DELAYED = [
    "asyncAfter", "scheduledTimer", "Timer(", "DispatchSource.makeTimerSource",
    "CFRunLoopObserver", "CFRunLoopAddObserver", "RunLoop.main.add",
    "afterDelay", "Thread.sleep", "usleep", "DispatchQueue.global",
]

gate = Gate("check-window-memory")


def span(text, i, opener="{", closer="}"):
    """From the bracket at `i` to its match, skipping comments and string
    literals so a bracket inside either cannot end it early."""
    depth, j, n = 0, i, len(text)
    while j < n:
        c = text[j]
        if c == "/" and j + 1 < n and text[j + 1] == "/":
            j = text.find("\n", j)
            if j < 0:
                break
            continue
        if c == "/" and j + 1 < n and text[j + 1] == "*":
            j = text.find("*/", j)
            if j < 0:
                break
            j += 2
            continue
        if c == '"':
            j += 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j += 1
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
        j += 1
    return None


def strip(text):
    """Code only: comments and string literals blanked, positions kept.
    The block under test SAYS "never a timer" in its own prose and names
    `_exit`, `UserDefaults` and the 250ms debounce it replaced — a census
    that read the comments would fail the file that is already right."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i)
            j = n if j < 0 else j + 2
            out.append(" " * (j - i))
            i = j
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def braced(text, pattern):
    """The braced body following the first match of `pattern`, or None.
    None is a FINDING at every callsite: a gate that stops finding what it
    reads reports a clean bill about nothing."""
    m = re.compile(pattern).search(text)
    if not m:
        return None
    i = text.find("{", m.end() - 1)
    if i < 0:
        return None
    return span(text, i)


def check(raw):
    """Clause A over one interpreter text. Returns offender sentences."""
    bad = []
    code = strip(raw)

    if BLOCK_START not in raw or BLOCK_END not in raw:
        return [f"{SWIFTUI}: the window-memory block is not where this gate "
                f"reads it (the `// MARK: - Window memory` anchor or the "
                f"KayaWindowDelegate that ends it) — nothing was checked"]
    # The anchors are COMMENTS, so the bounds come off the raw text and the
    # block is stripped after.
    block = strip(raw[raw.index(BLOCK_START):raw.index(BLOCK_END)])

    # --- The save rides the toolkit's own queue, not a clock. ---------
    note = braced(block, r"func kayaNoteWindowFrame\(")
    if note is None:
        bad.append("kayaNoteWindowFrame's body is unreadable — the save path "
                   "is what this gate is for")
    else:
        if "DispatchQueue.main.async {" not in note:
            bad.append("the save no longer rides DispatchQueue.main.async: "
                       "kayaNoteWindowFrame must hand the write to the hops' "
                       "OWN queue, FIFO behind the resize and ahead of the "
                       "step that exits (docs/tasks-s4-plan.md §4)")
        # ONE WRITE PER WINDOW PER TURN, and the turn released after it.
        if ("kayaFrameCoalesced.contains(windowId)" not in note
                or "kayaFrameCoalesced.insert(windowId)" not in note):
            bad.append("the per-turn coalescing is gone: a drag fires "
                       "didMove per frame and every one of them would be a "
                       "store write")
        if "kayaFrameCoalesced.remove(windowId)" not in note:
            bad.append("the coalescing is never released, so a window saves "
                       "its frame once and never again")
    for spelling in DELAYED:
        if spelling in block:
            bad.append(f"the window-memory block spells {spelling!r}: a save "
                       f"on a clock LOSES the value, because the process "
                       f"leaves through `_exit` with the trailing write "
                       f"unrun (measured 2026-09-09, docs/traps.md)")

    # --- ...and is deduplicated against what the store holds. ---------
    save = braced(block, r"func kayaSaveWindowFrame\(")
    if save is None:
        bad.append("kayaSaveWindowFrame's body is unreadable")
    elif not re.search(r"guard KayaHost\.windowFrame\(windowId\) != text\b",
                       save):
        bad.append("the save is no longer deduplicated against the store: a "
                   "frame that did not move must cost nothing")

    # --- The restore runs before the first frame is shown. ------------
    restore = braced(block, r"func kayaRestoreWindowFrame\(")
    if restore is None:
        bad.append("kayaRestoreWindowFrame's body is unreadable")
    else:
        if "display: false" not in restore:
            bad.append("the restore forces a display pass: the remembered "
                       "frame goes on before the first frame is shown, so "
                       "setFrame takes `display: false`")
        if "display: true" in restore:
            bad.append("the restore asks for `display: true`, which flushes "
                       "a frame at the size the memory is replacing")
    calls = len(re.findall(r"(?<!func )kayaRestoreWindowFrame\(", code))
    register = braced(code, r"private func register\(_ view: NSView\)")
    if register is None:
        bad.append("KayaWindowAccessor.register's body is unreadable — it is "
                   "the one place the restore may run from")
    elif "kayaRestoreWindowFrame(" not in register:
        bad.append("the restore is not called from the accessor's "
                   "register(): the remembered frame must go on at the "
                   "window's materialization, before it is presented")
    elif calls != 1:
        bad.append(f"kayaRestoreWindowFrame is called {calls} time(s); the "
                   f"accessor's register() is the only site, since anywhere "
                   f"later is after the first frame")
    elif register.index("kayaRestoreWindowFrame(") < register.index(
            "kayaApplyWindowSize(windowId)"):
        bad.append("the restore runs BEFORE kayaApplyWindowSize, so the "
                   "declaration would land on top of the memory it is "
                   "supposed to lose to")
    return bad


# --- Clause A, on the real file. --------------------------------------
real = gate.read(SWIFTUI)
for line in check(real):
    gate.finding(line)

block_lines = len(
    real[real.index(BLOCK_START):real.index(BLOCK_END)].splitlines()
) if BLOCK_START in real and BLOCK_END in real else 0
gate.counted("lines of the window-memory block read", block_lines, floor=120)

# --- Clause A's watched negatives. ------------------------------------
def refuses(label, doctored, want):
    gate.negative(label, lambda: check(doctored), want=want)


refuses("a save put on a 250ms clock",
        gate.doctor("the delayed-save perturbation", real,
                    r"(kayaFrameCoalesced\.insert\(windowId\)\n        )"
                    r"DispatchQueue\.main\.async \{",
                    r"\1DispatchQueue.main.asyncAfter("
                    r"deadline: .now() + 0.25) {"),
        want="'asyncAfter'")
refuses("a save with the per-turn coalescing removed",
        gate.doctor("the coalescing perturbation", real,
                    r" *guard !kayaFrameCoalesced\.contains\(windowId\) "
                    r"else \{ return \}\n *kayaFrameCoalesced"
                    r"\.insert\(windowId\)\n", ""),
        want="the per-turn coalescing is gone")
refuses("a save that no longer asks what the store holds",
        gate.doctor("the store-dedup perturbation", real,
                    r" *guard KayaHost\.windowFrame\(windowId\) != text "
                    r"else \{ return \}\n", ""),
        want="no longer deduplicated against the store")
refuses("a restore nobody calls at materialization",
        gate.doctor("the restore-callsite perturbation", real,
                    r" *kayaRestoreWindowFrame\(windowId, window\)\n", ""),
        want="not called from the accessor's register()")
refuses("a restore that flushes a frame at the declared size",
        gate.doctor("the display-pass perturbation", real,
                    r"window\.setFrame\(clamped, display: false\)",
                    "window.setFrame(clamped, display: true)"),
        want="display: true")

negatives = 5

# --- Clause B: the rule, driven, where the toolchain exists. ----------
if platform.system() != "Darwin":
    print("check-window-memory: clause B (the six by-value cases, the "
          "parse, the clamp, the coalesced save and the opt-out) SKIPPED — "
          "it needs macOS and a Swift toolchain. Clause A ran.")
    gate.negatives_ran(negatives)
    gate.verdict("static clause only")

cut = real[real.index(BLOCK_START):real.index(BLOCK_END)]
if len(cut.splitlines()) < 120:
    gate.refuse(f"could not cut the window-memory block out of {SWIFTUI} "
                f"({len(cut.splitlines())} lines) — the probe drives the "
                f"interpreter's own source, so there is nothing to run "
                f"without it.")
print(f"check-window-memory: clause B — {len(cut.splitlines())} lines of "
      f"{SWIFTUI} compiled into the probe")


def swiftc(*args):
    return subprocess.run(
        ["bash", "-c",
         'source "$1/tools/lib/swift-toolchain.sh" && cd "$1" && '
         'shift && kaya_swiftc "$@"',
         "swift-toolchain", str(ROOT), *[str(a) for a in args]],
        capture_output=True, text=True, check=False)


def drive(name, text):
    """Compile `text` as the interpreter's half and run the probe.
    Returns (returncode, output lines)."""
    src = gate.scratch() / f"KayaWindowMemory-{name}.swift"
    src.write_text("import AppKit\n\n" + text + "\n", encoding="utf-8")
    binary = gate.scratch() / f"swiftui-window-memory-{name}"
    built = swiftc(src, ROOT / PROBE, "-o", binary)
    if built.returncode != 0:
        print(built.stdout + built.stderr, file=sys.stderr)
        gate.refuse(f"the window-memory probe did not compile ({name})")
    # KAYA_WIN_SLOT makes every one of these functions inert by design.
    run = subprocess.run([str(binary)], capture_output=True, text=True,
                         env={k: v for k, v in os.environ.items()
                              if k != "KAYA_WIN_SLOT"}, check=False)
    return run.returncode, (run.stdout + run.stderr).splitlines()


rc, out = drive("live", cut)
for line in out:
    print(f"  {line}")
if rc != 0:
    gate.finding(f"FAIL — the window-memory probe exited {rc}; the lines "
                 f"above name the decision that did not hold.")
    gate.verdict()

# ...AND EVERY CASE WATCHED FAILING, each on its own doctored copy of the
# rule: a probe nobody has seen go red is a guess about a state nobody has
# reached.
RUNTIME_NEGATIVES = [
    ("no-memory",
     "a window with no memory refusing a write",
     r"guard kayaFrameMemory\[windowId\] != nil else \{ return false \}",
     "guard kayaFrameMemory[windowId] != nil else { return true }",
     "a window with no memory takes every write"),
    ("declaration",
     "a restored window taking its launch declaration",
     r"kayaFrameMemoryDeclared\[windowId\] = declared\n            return true",
     "kayaFrameMemoryDeclared[windowId] = declared\n            return false",
     "a restored window's first size is its declaration and is refused"),
    ("repeat",
     "the same declaration read as a resize the second time",
     r"if first == declared \{ return true \}",
     "if first == declared { return false }",
     "the same declaration again is still the declaration"),
    ("half-arrived",
     "a declaration still arriving taken as a resize",
     r"// The declaration is still arriving, one prop at a time\.\n"
     r"            return true",
     "// The declaration is still arriving, one prop at a time.\n"
     "            return false",
     "a declaration still arriving (one axis) holds the memory"),
    ("ends",
     "a memory that survives the resize that ended it",
     r"        kayaFrameMemory\[windowId\] = nil\n"
     r"        kayaFrameMemoryDeclared\[windowId\] = nil\n",
     "        kayaFrameMemoryDeclared[windowId] = nil\n",
     "the ended memory keeps no frame"),
    ("per-window",
     "one window's memory answering for every window",
     r"guard kayaFrameMemory\[windowId\] != nil else",
     "guard !kayaFrameMemory.isEmpty else",
     "the memory is per window, never process-wide"),
    # ...and the probe's other three halves, so no half of it is a
    # sentence nobody has seen print.
    ("kept-position",
     "the `- - <w> <h>` spelling losing the window's position",
     r"let x = Double\(parts\[0\]\) \?\? Double\(current\.origin\.x\)",
     "let x = Double(parts[0]) ?? 0",
     "restores the size and keeps the position"),
    ("guessed-size",
     "a malformed stored line taken at face value",
     r"w > 0, h > 0",
     "w > -10000, h > -10000",
     "a malformed stored line answers nil, not a guess: 120 40 0 620"),
    ("no-overlap",
     "a frame on a display that has left answering a screen anyway",
     r"if area > bestArea \{",
     "if area >= bestArea {",
     "a frame off EVERY screen falls back to nil"),
    ("store-dedup",
     "a save that writes a frame that did not move",
     r" *guard KayaHost\.windowFrame\(windowId\) != text else \{ return \}\n",
     "",
     "a frame that did not move is not written again"),
    ("turn-dedup",
     "a drag's per-frame notifications each reaching the store",
     r" *guard !kayaFrameCoalesced\.contains\(windowId\) else \{ return \}\n"
     r" *kayaFrameCoalesced\.insert\(windowId\)\n",
     "",
     "a noted frame is coalesced, not written on the spot"),
    ("no-restore",
     "a restore that reads the store and leaves the window alone",
     r" *window\.setFrame\(clamped, display: false\)\n",
     "",
     "the stored frame is the window's"),
    ("unarmed",
     "a restore that puts no memory on the window it restored",
     r" *kayaFrameMemory\[windowId\] = clamped\n",
     "",
     "the restored frame goes on the record as the memory"),
    ("opt-out",
     "an opted-out window saved anyway",
     r"guard kayaScene\.windows\[windowId\]\?\.rememberFrame != false,\n"
     r"            let window = kayaNSWindows\[windowId\]",
     "guard let window = kayaNSWindows[windowId]",
     "an opted-out window's frame is not saved"),
]

for name, label, pattern, repl, want in RUNTIME_NEGATIVES:
    doctored = gate.doctor(f"the {name} perturbation", cut, pattern, repl)
    bad_rc, bad_out = drive(name, doctored)
    if bad_rc == 0:
        bad_out = bad_out + [f"(the probe exited 0: {label} passed)"]
    negatives += 1
    if gate.negative(label, lambda lines=bad_out: lines, want=want):
        print(f"check-window-memory: self-test — {label} was refused "
              f"({want})")
    else:
        for line in bad_out:
            print(f"  {line}", file=sys.stderr)

gate.negatives_ran(negatives)
gate.verdict("6 by-value cases, 2 frame spellings, 6 malformed lines, the "
             "clamp, the coalesced save and the opt-out")
