#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE HARNESS LOSES LEGIBLY. Every step is entered with a CEILING, and
# once a verdict is published the process leaves within the EXIT GRACE
# whether or not the platform's exit path ever runs.
#
# The bug this replaces: a step's retry deadline is read only AFTER the
# step returns, and every step blocks in a hop to the platform's UI
# thread with no timeout of its own. A saturated app therefore printed
# NOTHING — no verdict, no timeout sentence — until something outside
# killed it. Measured on macOS, Linux, Windows and iOS 2026-08-24
# (docs/measurements/choke-*-2026-08-24.txt); on the mac lane the
# something is `timeout 120`, a KILL that takes the log with it.
#
# NO SCENE CAN FAIL THIS. A scene that wedges the UI thread would have
# to wedge it on every platform at once and would then measure nothing
# else, so — like the native-undo pair — a gate is the only wall
# available.
#
# THE CLAUSES:
#
#   A  STATIC, all three harnesses: the same two numbers, an arm inside
#      the script runner whose argument is the step (not a fixed
#      string), a publish over the exit, an exit primitive on the fire
#      path, and ONE sentence — compared flattened, so Rust's line
#      continuations and Swift's and Kotlin's `+` splices are the same
#      text or the gate says which file drifted.
#   B  RUNTIME, macOS only: the interpreter's OWN watchdog source, cut
#      out of swift/KayaSwiftUI.swift here and compiled with
#      tools/checks/swiftui-wedge.swift, against a REAL wedged main
#      thread. Clause A is what says the watchdog is wired into the
#      step loop; this is what says it fires.

import os
import platform
import re
import subprocess

# Line-buffered stdout: clause B's subprocesses write to the same fd,
# and block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

g = Gate("check-harness-ceiling")

HARNESS = "crates/kaya/src/harness.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
PROBE = "tools/checks/swiftui-wedge.swift"


def flat(text):
    """One sentence written three ways. Rust breaks a string with `\\`
    + newline, Swift and Kotlin splice with `+`; flattening those and
    the whitespace leaves the text itself, which is the thing that has
    to agree."""
    text = re.sub(r"\\\n\s*", "", text)
    text = re.sub(r'"\s*\+\s*"', "", text)
    text = re.sub(r"\s+", " ", text)
    return text


# (label, ceiling regex, grace regex, seconds scale)
NUMBERS = {
    "harness.rs": (
        r"STEP_CEILING: Duration = Duration::from_secs\((\d+)\)",
        r"EXIT_GRACE: Duration = Duration::from_secs\((\d+)\)",
        1,
    ),
    "KayaSwiftUI.swift": (
        r"kayaStepCeiling: TimeInterval = (\d+)(?:\.0)?\b",
        r"kayaExitGrace: TimeInterval = (\d+)(?:\.0)?\b",
        1,
    ),
    "KayaCompose.kt": (
        r"STEP_CEILING_MS = ([\d_]+)L",
        r"EXIT_GRACE_MS = ([\d_]+)L",
        1000,
    ),
}
# Where the arm has to BE: a step that is not covered is the whole bug.
RUNNERS = {
    "harness.rs": (r"fn run_with_log\(", r"\n\}"),
    "KayaSwiftUI.swift": (r"private func kayaRunScript\(", r"\n\}"),
    "KayaCompose.kt": (r"private fun runScript\(", r"\n    \}"),
}
# The arm, the publish, and what the fire path leaves with.
SHAPES = {
    "harness.rs": (r"watch\.enter\(([^)]*)\)", r"watch\.published\(",
                   r"harness_exit\("),
    "KayaSwiftUI.swift": (r"watchdog\.enter\(([^)]*)\)",
                          r"watchdog\.published\(", r"_exit\("),
    "KayaCompose.kt": (r"watchdog\.enter\(([^)]*)\)",
                       r"watchdog\.published\(", r"\.halt\("),
}

# ONE SENTENCE, THREE HARNESSES. Everything after the elapsed number is
# free of interpolation, so it compares byte for byte once flattened.
OPENING = "KAYA_SELFTEST: FAILED (no verdict — the harness entered step"
TAIL = (
    "s ago and has not come back from it. A step blocks in its hop to "
    "the platform's UI "
    "thread, so nothing answered from there; a wedged UI thread and a "
    "merely slow one look "
    "the same from here and this does not claim to tell them apart. "
    "Ended by the harness "
    "step ceiling, which is the cover a step's own retry deadline "
    "cannot give: that one is "
    "read only after a step returns.)"
)
GRACE_NOTE = (
    "s later — leaving under the verdict's own code (the harness exit "
    "grace)"
)


def check(harness, swiftui, compose):
    """Offender sentences for the three given harness paths — any of
    which may be a perturbed copy; that is how the self-tests below
    drive it."""
    paths = {"harness.rs": harness, "KayaSwiftUI.swift": swiftui,
             "KayaCompose.kt": compose}
    bad = []
    texts = {}
    for label, path in paths.items():
        p = pathlib.Path(path)
        if not p.is_absolute():
            p = ROOT / p
        try:
            texts[label] = p.read_text(encoding="utf-8")
        except OSError as exc:
            bad.append(f"cannot read {path} for {label} "
                       f"({exc.strerror}): the harness this rule pins "
                       f"is not there")

    seconds = {}
    for label, text in texts.items():
        ceiling_pat, grace_pat, scale = NUMBERS[label]
        for what, pat in (("step ceiling", ceiling_pat),
                          ("exit grace", grace_pat)):
            m = re.search(pat, text)
            if not m:
                bad.append(f"{paths[label]} declares no {what} — "
                           f"expected /{pat}/. The harness that has "
                           f"none is the one that goes silent.")
                continue
            seconds.setdefault(what, {})[label] = \
                int(m.group(1).replace("_", "")) / scale

        start = re.search(RUNNERS[label][0], text)
        if not start:
            bad.append(f"{paths[label]}: the script runner "
                       f"/{RUNNERS[label][0]}/ is gone — re-point this "
                       f"gate at whatever replaced it")
            continue
        end = re.search(RUNNERS[label][1], text[start.end():])
        body = text[start.end():
                    start.end() + (end.start() if end else len(text))]
        arm_pat, publish_pat, leave_pat = SHAPES[label]
        arms = re.findall(arm_pat, body)
        # A LITERAL argument names every step the same, which is the
        # step-failed rule one file over (tools/check-verbs.py): the
        # sentence has to say which step it was inside. The
        # interpreters also arm their verdict's OWN reads, with an
        # <angle-bracketed> literal, so the rule is that at least one
        # arm carries the step.
        if not any(not a.strip().startswith('"') for a in arms):
            bad.append(f"{paths[label]}'s script runner never arms the "
                       f"step ceiling with the step itself (found "
                       f"{len(arms)} arm(s) matching /{arm_pat}/) — a "
                       f"step nothing armed is a step that can hang "
                       f"with no verdict, and a fixed string names "
                       f"every step the same")
        if not re.search(publish_pat, body):
            bad.append(f"{paths[label]}'s script runner never publishes "
                       f"the verdict to the watchdog (/{publish_pat}/) "
                       f"— `finish` hops to the same UI thread for the "
                       f"exit, and the linux lane measured that hop "
                       f"never running")
        if not re.search(leave_pat, text):
            bad.append(f"{paths[label]} has no {leave_pat} on the "
                       f"watchdog's fire path — a watchdog that reports "
                       f"and stays is the same silence one line later")

    for what, found in seconds.items():
        if len(found) == len(texts) and len(set(found.values())) != 1:
            bad.append(f"the {what} disagrees across the three "
                       f"harnesses: "
                       + ", ".join(f"{k} {v}s"
                                   for k, v in sorted(found.items()))
                       + " — one rule, and a platform with a longer one "
                         "is a platform whose runner kills it first")

    for label, text in texts.items():
        flattened = flat(text)
        for what, want in (("verdict's opening", OPENING),
                           ("verdict's sentence", TAIL),
                           ("exit-grace note", GRACE_NOTE)):
            if want not in flattened:
                bad.append(f"{paths[label]} does not carry the {what} "
                           f"the other harnesses carry — one wedge "
                           f"reads one way everywhere. Wanted: {want!r}")

    # A DIALOG THAT IS NOT UP YET IS WAITING ON AN APP LAUNCH. Android's
    # two dialog arms retried on the generic step deadline, which is the
    # budget for an assertion waiting on a FRAME — and DocumentsUI is
    # another process, whose COLD start the FIRST dialog in a scene pays
    # while every later one is warm. Measured 2026-08-30
    # (docs/traps.md): save-jvm's picker was Displayed +4s603ms and
    # a11y-readable at 6983ms, 511ms past the deadline, while the two
    # save panels after it took 160ms and 74ms. NO SCENE CAN HOLD THIS —
    # the leg is green whenever the emulator is quiet, so it fails only
    # under a full matrix and only for whichever dialog expect happens
    # to be first in the .steps file.
    compose_text = texts.get("KayaCompose.kt")
    if compose_text is not None:
        # Each arm's own block, so a sibling arm's extension cannot
        # answer for a missing one — the block reader
        # check-canvas-blit's first draft got wrong by stopping at the
        # first bracket it found.
        arm_starts = [(m.start(), m.group(1))
                      for m in re.finditer(r'^ {20}"(\w+)" ->',
                                           compose_text, re.M)]
        blocks = {}
        for idx, (pos, name) in enumerate(arm_starts):
            end = (arm_starts[idx + 1][0] if idx + 1 < len(arm_starts)
                   else len(compose_text))
            blocks[name] = compose_text[pos:end]
        for arm in ("expect_file_dialog", "expect_save_dialog"):
            block = blocks.get(arm)
            if block is None:
                bad.append(f"{paths['KayaCompose.kt']}: the {arm} arm "
                           f"is gone — re-point this clause at whatever "
                           f"replaced it")
                continue
            note = block.find("kayaNoteDialogUnseen")
            if note < 0:
                bad.append(f"{paths['KayaCompose.kt']}'s {arm} arm no "
                           f"longer records an unseen dialog — that "
                           f"instrument is what tells a late "
                           f"presentation from a dialog that presented "
                           f"and could not be read")
                continue
            extend = block.find("stepStart + DIALOG_LAUNCH_BUDGET_NS")
            if extend < 0 or extend > note:
                bad.append(
                    f"{paths['KayaCompose.kt']}'s {arm} arm reports a "
                    f"missing dialog on the generic step deadline — "
                    f"that is a FRAME's budget, and a dialog that is "
                    f"not up yet is waiting on DocumentsUI's cold APP "
                    f"LAUNCH (measured 4s603ms to Displayed, 6983ms to "
                    f"readable). Extend with `stepDeadline = "
                    f"maxOf(stepDeadline, stepStart + "
                    f"DIALOG_LAUNCH_BUDGET_NS)` before the report, as "
                    f"expect_ax does.")
        # AND IT MAY NOT BE SHRUNK BACK toward the number that was
        # measured failing: a budget at the observed time is a budget
        # that fails the next time the lane is busier.
        m = re.search(r"DIALOG_LAUNCH_BUDGET_NS = ([\d_]+)L",
                      compose_text)
        if not m:
            bad.append(f"{paths['KayaCompose.kt']} declares no "
                       f"DIALOG_LAUNCH_BUDGET_NS — the two dialog arms "
                       f"above have nothing to extend to")
        elif int(m.group(1).replace("_", "")) < 10_000_000_000:
            bad.append(f"{paths['KayaCompose.kt']}'s "
                       f"DIALOG_LAUNCH_BUDGET_NS is "
                       f"{int(m.group(1).replace('_', '')) / 1e9}s — "
                       f"the presentation this covers was MEASURED at "
                       f"6.983s on a loaded lane, so a budget near it "
                       f"buys nothing. Keep it well clear (and under "
                       f"STEP_CEILING).")

    return bad


bad = check(HARNESS, SWIFTUI, COMPOSE)
if bad:
    g.finding("the step ceiling is not in force in all three harnesses:")
    print("\n".join(bad), file=sys.stderr)

# --- The self-tests: perturb the REAL files, count the substitutions,
# --- demand a refusal that names the perturbation. --------------------
harness_fixed = g.perturb(
    "the harness.rs fixed-step-text perturbation", HARNESS,
    r'watch\.enter\(format!\("\{step:\?\}"\)\);',
    'watch.enter("a step".to_string());')
g.negative("a Rust harness whose ceiling cannot name the step it was "
           "inside",
           lambda: check(str(harness_fixed), SWIFTUI, COMPOSE),
           want="never arms the step ceiling with the step itself")

swiftui_unarmed = g.perturb(
    "the KayaSwiftUI.swift unarmed-step perturbation", SWIFTUI,
    r"watchdog\.enter\(line\)\n", "")
g.negative("a SwiftUI step loop that arms nothing",
           lambda: check(HARNESS, str(swiftui_unarmed), COMPOSE),
           want="never arms the step ceiling with the step itself")

compose_drifted = g.perturb(
    "the KayaCompose.kt ceiling-drift perturbation", COMPOSE,
    r"STEP_CEILING_MS = 60_000L", "STEP_CEILING_MS = 300_000L")
g.negative("an Android ceiling longer than the other two",
           lambda: check(HARNESS, SWIFTUI, str(compose_drifted)),
           want="the step ceiling disagrees across the three harnesses")

compose_noexit = g.perturb(
    "the KayaCompose.kt unpublished-exit perturbation", COMPOSE,
    r"watchdog\.published\(code\)\n", "")
g.negative("an Android verdict whose exit hop nothing covers",
           lambda: check(HARNESS, SWIFTUI, str(compose_noexit)),
           want="never publishes the verdict to the watchdog")

swiftui_drifted = g.perturb(
    "the KayaSwiftUI.swift sentence-drift perturbation", SWIFTUI,
    r"and a merely slow one look the same from here",
    "and a wedged one look the same from here")
g.negative("a wedge that reads differently on one platform",
           lambda: check(HARNESS, str(swiftui_drifted), COMPOSE),
           want="does not carry the verdict's sentence the other "
                "harnesses carry")

# THE TWO DIALOG ARMS. One perturbation per arm, because a sibling
# arm's extension answering for a missing one is exactly the shape this
# reads per-block to avoid.
compose_nofiledlg = g.perturb(
    "the KayaCompose.kt file-dialog launch-budget perturbation", COMPOSE,
    r"stepDeadline = maxOf\(\n +stepDeadline,\n +stepStart \+ "
    r"DIALOG_LAUNCH_BUDGET_NS,\n +\)\n +val lastLook = "
    r"System\.nanoTime\(\) \+ RETRY_PERIOD_NS >= stepDeadline\n +"
    r"if \(lastLook\) kayaNoteDialogUnseen\(DIALOG_KIND_OPEN\)",
    "val lastLook = System.nanoTime() + RETRY_PERIOD_NS >= stepDeadline"
    "\n                            "
    "if (lastLook) kayaNoteDialogUnseen(DIALOG_KIND_OPEN)")
g.negative("an Android picker assertion given a frame's budget for an "
           "app launch",
           lambda: check(HARNESS, SWIFTUI, str(compose_nofiledlg)),
           want="expect_file_dialog arm reports a missing dialog on the "
                "generic step deadline")

compose_nosavedlg = g.perturb(
    "the KayaCompose.kt save-dialog launch-budget perturbation", COMPOSE,
    r"stepDeadline = maxOf\(\n +stepDeadline,\n +stepStart \+ "
    r"DIALOG_LAUNCH_BUDGET_NS,\n +\)\n +val lastLook = "
    r"System\.nanoTime\(\) \+ RETRY_PERIOD_NS >= stepDeadline\n +"
    r"if \(lastLook\) kayaNoteDialogUnseen\(DIALOG_KIND_SAVE\)",
    "val lastLook = System.nanoTime() + RETRY_PERIOD_NS >= stepDeadline"
    "\n                                "
    "if (lastLook) kayaNoteDialogUnseen(DIALOG_KIND_SAVE)")
g.negative("an Android save-panel assertion given a frame's budget for "
           "an app launch",
           lambda: check(HARNESS, SWIFTUI, str(compose_nosavedlg)),
           want="expect_save_dialog arm reports a missing dialog on the "
                "generic step deadline")

compose_tightdlg = g.perturb(
    "the KayaCompose.kt launch-budget shrink perturbation", COMPOSE,
    r"DIALOG_LAUNCH_BUDGET_NS = 20_000_000_000L",
    "DIALOG_LAUNCH_BUDGET_NS = 7_000_000_000L")
g.negative("a launch budget shrunk back to the number that was measured "
           "failing",
           lambda: check(HARNESS, SWIFTUI, str(compose_tightdlg)),
           want="the presentation this covers was MEASURED at 6.983s")

# An ABSENT harness is a failure that NAMES IT, never a skip.
absent = g.scratch() / "no-such-harness.kt"
g.negative("an absent harness",
           lambda: check(HARNESS, SWIFTUI, str(absent)),
           want=f"cannot read {absent}")

g.negatives_ran(9)

# --- Clause B: the runtime negative, where the toolchain exists. ------
if platform.system() == "Darwin":
    # The probe drives the INTERPRETER'S OWN watchdog: it is cut out of
    # the real file here, so there is no second copy to drift.
    text = g.read(SWIFTUI)
    try:
        start = text.index("/// THE CEILING ON ONE STEP")
        end = text.index("\n}\n",
                         text.index("final class KayaStepWatchdog"))
    except ValueError:
        start = end = None
    cut = ("import Foundation\n\n" + text[start:end + 3]
           if start is not None else "")
    lines = len(text[start:end].splitlines()) if cut else 0
    if lines < 40:
        g.refuse(f"could not cut the watchdog out of {SWIFTUI} "
                 f"({lines} lines) — the probe compiles the "
                 f"interpreter's own source, so there is nothing to run "
                 f"without it.")
    ceiling_src = g.scratch() / "KayaStepCeiling.swift"
    ceiling_src.write_text(cut, encoding="utf-8")
    print(f"check-harness-ceiling: clause B — {lines} lines of "
          f"{SWIFTUI} compiled into the probe")

    def swiftc(*args):
        return subprocess.run(
            ["bash", "-c",
             'source "$1/tools/lib/swift-toolchain.sh" && cd "$1" && '
             'shift && kaya_swiftc "$@"',
             "swift-toolchain", str(ROOT), *[str(a) for a in args]],
            check=False)

    wedge = g.scratch() / "swiftui-wedge"
    if swiftc(ceiling_src, PROBE, "-o", wedge).returncode != 0:
        g.refuse("the wedge probe did not compile")
    live = subprocess.run([str(wedge)], check=False)
    if live.returncode != 0:
        g.finding(f"FAIL — the SwiftUI wedge probe exited "
                  f"{live.returncode}.")
        g.verdict()
    # AND WATCHED FAILING, on the same real source: a ceiling that
    # never expires is the pre-fix silence, and the probe has to report
    # it.
    dead_text = g.doctor("the never-expiring-ceiling perturbation", cut,
                         r"waited >= ceiling", "waited >= ceiling * 1000")
    dead_src = g.scratch() / "KayaStepCeilingDead.swift"
    dead_src.write_text(dead_text, encoding="utf-8")
    dead_bin = g.scratch() / "swiftui-wedge-dead"
    if swiftc(dead_src, PROBE, "-o", dead_bin).returncode != 0:
        g.refuse("the perturbed wedge probe did not compile")
    # 5s against the probe's own 1.5s ceiling: a live one has published
    # long before, a dead one has not.
    dead = subprocess.run([str(dead_bin)], capture_output=True,
                          text=True, check=False,
                          env=dict(os.environ, KAYA_WEDGE_CAP_MS="5000"))
    dead_log = dead.stdout + dead.stderr
    if dead.returncode == 0:
        g.finding("SELF-TEST FAILED — a watchdog whose ceiling can "
                  "never expire still passed the probe, so the probe "
                  "proves nothing.")
        g.verdict()
    if "the step ceiling never fired" not in dead_log:
        g.finding("SELF-TEST FAILED — the dead ceiling was refused, but "
                  "not for the stated reason:")
        print(dead_log, file=sys.stderr)
        g.verdict()
    print("check-harness-ceiling: self-test — a never-expiring ceiling "
          "reported the silence")
else:
    print("check-harness-ceiling: clause B (the wedged-main-thread "
          "probe) SKIPPED — it needs macOS and a Swift toolchain. "
          "Clause A ran.")

g.verdict("3 harnesses, one ceiling and one sentence")
