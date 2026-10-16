#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# A RED LEG'S BUNDLE NAMES ITS CAUSE ON EVERY LANE, or says what it
# measured instead (CLAUDE.md's flight-recorder rule, the maintainer's
# 2026-09-16 ruling). The shape is one declaration —
# tools/lib/flightrec_lane.py's SECTIONS for the four python lanes and
# tools/lib/flightrec.sh's FLIGHTREC_SECTIONS_LINUX for the container —
# and this gate holds five things no lane can fail:
#
#  1. every lane declares the three sections a reader always wants (the
#     leg's own log, the verb trace, and a PICTURE of what the user would
#     have seen), and the two declarations are one list;
#  2. every declared section is REACHED by that lane's own collect — a
#     section nothing writes is marked by finish() and looks, in the
#     bundle, exactly like one the platform could not answer, which is
#     the lie this pass came from;
#  3. a `.skip` file is written through ONE writer per half and never
#     with an empty sentence (the windows notes bundle of 2026-09-16
#     carried a zero-byte shot marker: the reader could not tell "no
#     picture was possible" from "nobody tried");
#  4. each lane's failure path ends in finish(), never in a bare
#     bundle_report — the unreached-section marking is finish()'s;
#  5. the pictures are taken WHERE THE DEVICE IS STILL THE LEG'S: the
#     phones hand their device back to the pool and the linux lane
#     REBOOTS the leg's display, both before the bundle is built, so a
#     capture moved into drain() photographs somebody else's scene or an
#     empty desktop — and would still produce a plausible PNG.
#
# Beside them the windows launcher's verb-trace path, held against the
# name the recorder pulls: check-steps holds the launcher line alone, and
# nothing held the two ends together. And the toast moment's own two
# records one door over (docs/deferred.md, the notes_rust toast entry):
# no launcher names those — the GUEST writes them beside the verb trace —
# so their three places are winui/mod.rs's capture, the recorder's pull
# and deploy-win's pre-leg delete.

import ast
import atexit
import datetime
import io
import json
import os
import re
import subprocess
import tempfile
import time
import types

gate = Gate("check-flightrec")

LANE_PY = "tools/lib/flightrec_lane.py"
LANE_SH = "tools/lib/flightrec.sh"
LINUX = "tools/linux/run-suites.sh"
IOS = "tools/ios/run-sim.py"
ANDROID = "tools/android/run-emulator.py"
WIN = "tools/deploy-win.py"
STEPS = "tools/check-steps.py"
WINUI = "crates/kaya/src/winui/mod.rs"
GUEST_PS1 = "tools/guest/flightrec.ps1"
FOCUS_RING = "tools/linux/focus-ring.py"
HAND = "tools/run-leg.py"
WINLIST = "tools/mac/flightrec-winlist.swift"
HARNESS = "crates/kaya/src/harness.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
DOOR_RECORD = "tools/linux/door_record.py"
LEG_CEILING = "tools/linux/leg-ceiling.py"
GTK_RS = "crates/kaya/src/gtk.rs"
STACK_NAMES = "tools/linux/stack-names.py"
JOURNAL = "tools/lib/flightrec.py"
ACT2_EXEC = "tools/linux/act2-exec.sh"
DOOR_LEGS = ("tools/linux/persist-leg.py", "tools/linux/link-leg.py")
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
LANE_HEALTH = "tools/lib/lane_health.py"
VALIDATE_ALL = "tools/validate-all.py"
MAC_RUNNER = "tools/validate-mac.py"
LINUX_HOST = "tools/validate-linux.py"
MAC_LANE = "tools/lib/lanes/mac.py"
# Each lane reads its health at start and at end, the end before its verdict
# (docs/traps.md, the windows lane slowed by a rebooted VM's Defender).
HEALTH_CALLS = {
    WIN: ('lane_health_reading("start")', 'lane_health_reading("end")',
          'print("deploy-win: ALL PASS")'),
    IOS: ('lane_health.ios_report("ios", "start"', 'lane_health.ios_report("ios", "end"',
          'print("run-sim: ALL PASS")'),
    ANDROID: ('lane_health.android_report("android", "start"',
              'lane_health.android_report("android", "end"', 'print("run-emulator: ALL PASS")'),
    MAC_RUNNER: ('lane_health.mac_report("mac", "start")', 'lane_health.mac_report("mac", "end")',
                 'print("validate-mac: ALL PASS")'),
    LINUX_HOST: ('lane_health.linux_report("linux", "start"',
                 'lane_health.linux_report("linux", "end"', "sys.exit(rc)"),
}

# The recorder class whose body IS each python lane's collect path.
RECORDERS = {"mac": "MacRecorder", "windows": "WinRecorder",
             "ios": "IosRecorder", "android": "AndroidRecorder"}

# What every lane owes a reader, whatever its platform.
UNIVERSAL = ("leg-log", "verb-trace", "shot")


def sources():
    return {rel: gate.read(rel) for rel in
            (LANE_PY, LANE_SH, LINUX, IOS, ANDROID, WIN,
             STEPS, WINUI, GUEST_PS1, FOCUS_RING, HAND, WINLIST, HARNESS, SWIFTUI,
             DOOR_RECORD, ACT2_EXEC, COMPOSE, JOURNAL, *DOOR_LEGS, LEG_CEILING, STACK_NAMES, GTK_RS,
             LANE_HEALTH, VALIDATE_ALL, MAC_RUNNER, LINUX_HOST, MAC_LANE)}


def census_android_app_shot(src):
    """docs/traps.md, the android red leg that photographed the home
    screen: the app's own picture is taken before its verdict is
    published, since the process leaves about 300ms after it, and the
    runner adopts THAT as `shot`, the screencap as `desktop-shot`."""
    found = []
    kt = src[COMPOSE]
    step = kt.find("} else if (failures.size > failuresBefore) {")
    step_end = kt.find("statements++", step)
    if step < 0 or "KayaFailShot.take(" not in kt[step:step_end]:
        found.append("android: the harness takes no picture at a step's final failure "
                     "(KayaFailShot.take)")
    verdict = kt.find('val said = reported.joinToString("; ")')
    publish = kt.find('Log.e("kaya", line)', verdict)
    take = kt.find("KayaFailShot.take(", verdict)
    if verdict < 0 or publish < 0 or not 0 <= take < publish:
        found.append("android: the failed verdict is published before the app's picture is "
                     "taken — the process leaves under it")
    if "android.view.PixelCopy.request(" not in kt[kt.find("object KayaFailShot"):]:
        found.append("android: KayaFailShot no longer copies the window")
    if "val sheets = sheetLayers(activity, bitmap)" not in kt[kt.find("object KayaFailShot"):]:
        found.append("android: KayaFailShot no longer draws each sheet's own window over the "
                     "activity's (docs/traps.md, the quick-add field panned above its sheet's top)")
    runner = src[ANDROID]
    if '["--es", "KAYA_FAIL_SHOT", f"fail-shot-{leg}.png"]' not in runner:
        found.append("android: the runner no longer names KAYA_FAIL_SHOT for the leg")
    if 'f"files/fail-shot-{name}.png"' not in py_block(runner, "app_shot"):
        found.append("android: app_shot does not pull the file KAYA_FAIL_SHOT names")
    leg = py_block(runner, "run_apk_on")
    if "app_shot(serial, package, name, log)" not in leg:
        found.append("android: run_apk_on does not pull the app's own picture on a red leg")
    clear = leg.find('run_as(serial, package, "rm", "-f", f"files/verb-trace-{name}.txt")')
    start = leg.find('"am", "start", "-W", "-n", component, "--es",')
    if not 0 <= clear < start:
        found.append("android: run_apk_on does not delete the leg's verb trace before its launch — "
                     "the ring appends, so a red bundle carries every earlier red's dump")
    if '.with_suffix(".shot.png")' not in py_block(runner, "app_shot") or \
            '.with_suffix(".desktop-shot.png")' not in py_block(runner, "device_capture"):
        found.append("android: the screencap after the verdict is filed as the leg's `shot` — "
                     "it is the launcher's picture once the process has left")
    rec = py_block(src[LANE_PY], "AndroidRecorder")
    adopts = ('self.adopt_shot(bundle, "shot", log.with_suffix(".shot.png"),',
              'self.adopt_shot(bundle, "desktop-shot", '
              'log.with_suffix(".desktop-shot.png"),')
    if not all(a in rec for a in adopts):
        found.append("android: the recorder does not adopt the app's picture as `shot` and the "
                     "screencap as `desktop-shot`")
    return found


def census_mac_app_shot(src):
    """docs/traps.md, the mac red leg whose window was gone: the guest
    leaves within the grace of its verdict, so the collect lists the other
    pooled legs' windows. The guest photographs its own window at its first
    final failure and before the verdict's publish, and the recorder adopts
    that picture as `shot` ahead of every later attempt."""
    found = []
    sw = src[SWIFTUI]
    step = sw.find("} else if failures.count > failuresBefore {")
    step_end = sw.find("\n    }\n", step)
    if step < 0 or "KayaFailShot.take(" not in sw[step:step_end]:
        found.append("mac: the harness takes no picture at a step's final failure "
                     "(KayaFailShot.take)")
    verdict = sw.find('? "KAYA_SELFTEST: ACT 1 FAILED (')
    publish = sw.find("watchdog.published(1)", verdict)
    take = sw.find("KayaFailShot.take(", verdict)
    if verdict < 0 or publish < 0 or not 0 <= take < publish:
        found.append("mac: the failed verdict is published before the guest's picture is "
                     "taken — the process leaves under it")
    shot = sw[sw.find("enum KayaFailShot"):]
    if '"-l\\(num)"' not in shot[:shot.find("\n    }\n")]:
        found.append("mac: KayaFailShot no longer photographs its window by number")
    rec = py_block(src[LANE_PY], "MacRecorder")
    if 'env["KAYA_FAIL_SHOT"] = str(scratch / "fail-shot.png")' not in py_block(
            rec, "watched_leg"):
        found.append("mac: watched_leg no longer names KAYA_FAIL_SHOT for the leg")
    body = py_block(rec, "_shot")
    adopt, later = body.find('shutil.copy2(fail, bundle / "shot.png")'), \
        body.find("self.shot_pid(")
    if not 0 <= adopt < later:
        found.append("mac: _shot does not adopt the guest's own picture as `shot` before "
                     "it looks for a window the guest has already closed")
    return found


def census_ios_app_shot(src):
    """docs/traps.md, the iOS red leg that photographed the home screen:
    `simctl launch --console-pty` returns at exit, so the runner's screenshot
    is SpringBoard's. The app draws its own windows at its first final
    failure and before the verdict's publish, the runner pulls that out of
    the container as `shot`, and the device's screenshot is `desktop-shot`."""
    found = []
    sw = src[SWIFTUI]
    for anchor, what in (('KayaFailShot.take("the first failed step, \\(line)")', "step"),
                         ('KayaFailShot.take("the failed verdict")', "verdict")):
        at = sw.find(anchor)
        if at < 0 or "#if os(macOS)" in sw[sw.rfind("\n", 0, sw.rfind("\n", 0, at)):at]:
            found.append(f"iOS: the {what}'s fail shot is not taken on iOS (KayaFailShot.take "
                         f"missing or fenced to macOS)")
    ios_at = sw.find("#elseif os(iOS)\n    /// The iOS twin")
    ios = sw[ios_at:sw.find("\n#endif\n", ios_at)] if ios_at >= 0 else ""
    if "window.drawHierarchy(in: window.frame" not in ios:
        found.append("iOS: KayaFailShot no longer draws the app's windows (drawHierarchy)")
    if "kayaTempDir()" not in ios:
        found.append("iOS: KayaFailShot no longer resolves a relative KAYA_FAIL_SHOT under "
                     "Documents, where the runner pulls it")
    leg = py_block(src[IOS], "run_swiftui_on")
    if 'env["SIMCTL_CHILD_KAYA_FAIL_SHOT"] = f"fail-shot-{name}.png"' not in leg:
        found.append("iOS: run_swiftui_on no longer names KAYA_FAIL_SHOT for the leg")
    if '(f"fail-shot-{name}.png", f"fail-shot-{name}.png.when")' not in leg:
        found.append("iOS: run_swiftui_on does not delete the leg's last fail shot before "
                     "its launch — a red leg with no picture would adopt an earlier one")
    if '(f"fail-shot-{name}.png", ".shot.png")' not in py_block(src[IOS], "pull_container_files"):
        found.append("iOS: pull_container_files does not pull the app's own picture")
    for fn in ("device_capture", "driver_shot"):
        if '.with_suffix(".desktop-shot.png")' not in py_block(src[IOS], fn):
            found.append(f"iOS: {fn} files the device's screen as the leg's `shot` — it is "
                         f"SpringBoard's once the app has exited")
    rec = py_block(src[LANE_PY], "IosRecorder")
    adopts = ('self.adopt_shot(bundle, "shot", log.with_suffix(".shot.png"),',
              'self.adopt_shot(bundle, "desktop-shot", '
              'log.with_suffix(".desktop-shot.png"),')
    if not all(a in rec for a in adopts):
        found.append("iOS: the recorder does not adopt the app's picture as `shot` and the "
                     "device's as `desktop-shot`")
    return found


def py_block(text, name):
    """One class or function's source, by name."""
    lines = text.splitlines(keepends=True)
    for node in ast.walk(ast.parse(text)):
        if isinstance(node, (ast.ClassDef, ast.FunctionDef)) \
                and node.name == name:
            return "".join(lines[node.lineno - 1:node.end_lineno])
    return ""


def sh_block(text, start, end):
    """The text between two markers, or "" when either is missing."""
    a = text.find(start)
    if a < 0:
        return ""
    b = text.find(end, a)
    return text[a:b + len(end)] if b >= 0 else ""


def declared(src):
    """The five lanes' section lists: the python table and the shell row,
    as ONE mapping."""
    out = {}
    for node in ast.walk(ast.parse(src[LANE_PY])):
        if isinstance(node, ast.Assign) \
                and any(getattr(t, "id", "") == "SECTIONS"
                        for t in node.targets):
            out = {k: tuple(v) for k, v in ast.literal_eval(node.value).items()}
    row = re.search(r'FLIGHTREC_SECTIONS_LINUX="([^"]*)"', src[LANE_SH])
    if row:
        out["linux"] = tuple(row.group(1).split())
    return out


# ---------------------------------------------------------------- 1 + 2

def reachable_py(body, name):
    """Whether a python recorder's collect can actually GET TO the branch
    that names this section. `"<name>" in body` cannot see a writer
    method nobody calls: the section is declared, the code is there, and
    every bundle still carries finish()'s marker for it. A lane's own
    `<lane>_leg` entry is called by the runner; anything else must be
    called inside the class. A name spelled outside every method (a
    class-level sentence) keeps the plain test."""
    try:
        tree = ast.parse(body)
    except SyntaxError:
        return True
    lines = body.splitlines(keepends=True)
    holders = [node.name for node in ast.walk(tree)
               if isinstance(node, ast.FunctionDef)
               and f'"{name}"' in "".join(
                   lines[node.lineno - 1:node.end_lineno])]
    if not holders:
        return True
    return any(h.endswith("_leg") or f"self.{h}(" in body for h in holders)


def census_sections(src):
    found = []
    table = declared(src)
    for lane in ("mac", "windows", "ios", "android", "linux"):
        if lane not in table:
            found.append(f"{lane}: no section list is declared for this lane "
                         f"— {LANE_PY}'s SECTIONS and {LANE_SH}'s "
                         f"FLIGHTREC_SECTIONS_LINUX are the two halves")
            continue
        for want in UNIVERSAL:
            if want not in table[lane]:
                found.append(
                    f"{lane}: declares no `{want}` section. Every lane owes "
                    f"a reader the leg's own log, the verb trace and a "
                    f"picture of what the user would have seen; a platform "
                    f"that cannot take one says so in the section's own "
                    f"skip sentence, it does not drop the section")
    for lane, names in sorted(table.items()):
        if lane == "linux":
            body = sh_block(src[LINUX], 'bundle="$(flightrec_bundle linux',
                            "flightrec_finish")
            if not body:
                found.append(f"linux: {LINUX}'s drain no longer opens a "
                             f"bundle and closes it with flightrec_finish, "
                             f"so this gate can read no collect path")
                continue
            reached = [n for n in names
                       if re.search(r'\$bundle" ' + re.escape(n) + r'(?![\w-])',
                                    body)]
        else:
            body = py_block(src[LANE_PY], RECORDERS[lane])
            if not body:
                found.append(f"{lane}: no {RECORDERS[lane]} in {LANE_PY}")
                continue
            reached = [n for n in names
                       if f'"{n}"' in body and reachable_py(body, n)]
        for name in names:
            if name not in reached:
                found.append(
                    f"{lane}: section `{name}` is declared and no branch of "
                    f"that lane's collect names it, so every bundle carries "
                    f"finish()'s marker for it and nothing measured")
    return found


# -------------------------------------------------------------------- 3

def census_skips(src):
    found = []
    rest = src[LANE_PY].replace(py_block(src[LANE_PY], "skip"), "")
    for m in re.finditer(r'\.skip"[^\n]*\n?[^\n]*write_text', rest):
        found.append(
            f"{LANE_PY}: a `.skip` file is written outside skip() "
            f"({m.group(0).splitlines()[0].strip()}) — skip() is the one "
            f"writer, and it is what refuses an empty marker")
    sh_skip = sh_block(src[LANE_SH], "flightrec_skip() {", "\n}\n")
    sh_rest = src[LANE_SH].replace(sh_skip, "")
    for m in re.finditer(r'>"?\$bundle/\$?\{?name\}?\.skip"?', sh_rest):
        found.append(
            f"{LANE_SH}: a `.skip` file is written outside flightrec_skip "
            f"({m.group(0)}) — that function is the one writer")
    # AND NO CALL MAY NAME AN EMPTY SENTENCE. The fallback inside skip()
    # catches it at run time; this catches it before the lane runs.
    for rel in (LANE_PY,):
        for node in ast.walk(ast.parse(src[rel])):
            if not isinstance(node, ast.Call):
                continue
            if getattr(node.func, "attr", "") != "skip" or len(node.args) < 3:
                continue
            why = node.args[2]
            if isinstance(why, ast.Constant) and not str(why.value).strip():
                found.append(
                    f"{rel}:{node.lineno}: skip() is called with an empty "
                    f"sentence — an empty marker is a diagnostic that cannot "
                    f"discriminate (invariant 3)")
    for call in sh_calls(src[LANE_SH], "flightrec_skip") \
            + sh_calls(src[LINUX], "flightrec_skip"):
        if len(call) < 4 or not call[3].strip(' "\''):
            found.append(
                f"flightrec_skip is called with no sentence ({' '.join(call)}) "
                f"— the caller must say what was measured")
    return found


def sh_calls(text, name):
    """Every call of a shell function, `\\`-continuations joined, as a
    list of its whitespace-separated words."""
    out = []
    joined = text.replace("\\\n", " ")
    for line in joined.splitlines():
        line = line.strip()
        if line.startswith(name + " "):
            out.append(line.split(None, 3))
    return out


# -------------------------------------------------------------------- 4

def census_finish(src):
    found = []
    for lane, cls in RECORDERS.items():
        body = py_block(src[LANE_PY], cls)
        if "self.finish(" not in body:
            found.append(
                f"{lane}: {cls} never calls finish(), so a section its "
                f"collect stopped writing is silently absent from the "
                f"bundle instead of marked with a sentence")
        if "self.bundle_report(" in body:
            found.append(
                f"{lane}: {cls} calls bundle_report() directly — finish() "
                f"is the one caller, because it is what fills the sections "
                f"the collect never reached BEFORE the report counts them")
    body = sh_block(src[LINUX], 'bundle="$(flightrec_bundle linux',
                    "flightrec_finish")
    if "flightrec_bundle_report" in body:
        found.append(
            f"linux: {LINUX}'s drain calls flightrec_bundle_report directly "
            f"— flightrec_finish is the one caller")
    return found


# -------------------------------------------------------------------- 5

def census_when(src):
    """The pictures are taken while the device is still this leg's."""
    found = []
    run_one = sh_block(src[LINUX], "run_one() {", "\n}\n")
    for shot, reboot, arm in (
            ("flightrec_shot_x11", 'x11_display_boot "$kaya_display"', "x11"),
            ("flightrec_shot_wayland", 'wayland_session_boot "$kaya_slot"',
             "wayland")):
        at, back = run_one.find(shot), run_one.find(reboot)
        if at < 0:
            found.append(
                f"linux/{arm}: run_one takes no picture on the failure path "
                f"({shot}) — the display is rebooted below, so a shot taken "
                f"anywhere later is of a fresh empty session")
        elif back < 0:
            found.append(f"linux/{arm}: run_one no longer reboots the "
                         f"session ({reboot}); re-read this clause")
        elif at > back:
            found.append(
                f"linux/{arm}: run_one photographs the session AFTER "
                f"{reboot} — that picture is of the new display, not the "
                f"leg's")
    for rel, leg_fn, drain_fn in ((IOS, "run_swiftui_on", "drain"),
                                  (ANDROID, "run_apk_on", "drain")):
        lane = "ios" if rel == IOS else "android"
        if "device_capture(" not in py_block(src[rel], leg_fn):
            found.append(
                f"{lane}: {leg_fn} does not call device_capture() — the "
                f"device goes back to the pool when it returns, so a "
                f"capture after it photographs another leg's scene")
        if "device_capture(" in py_block(src[rel], drain_fn):
            found.append(
                f"{lane}: {drain_fn} calls device_capture() — by then the "
                f"device is back in the pool")
    return found


# -------------------------------------------------------------------- 6

def census_vtrace(src):
    """ONE PATH, THREE PLACES. check-steps holds every windows launcher
    to a `set KAYA_VERB_TRACE=…\\<leg>-vtrace.txt` line (its own
    verb_trace_line, with its own exemptions and its packaged
    outer/inner pair — that census is NOT repeated here), and nothing
    held that spelling against the file the recorder PULLS or against
    the one deploy-win clears before the leg. Either end moving alone
    leaves `verb-trace.skip` on every red windows leg, which is what the
    2026-09-16 notes bundle carried."""
    found = []
    pull = re.search(r'self\.pull\(bundle, leg, "([^"]+)", "verb-trace"',
                     src[LANE_PY])
    line = re.search(r'return f"set KAYA_VERB_TRACE='
                     r'C:\\\\kaya\\\\flightrec\\\\\{leg\}-([^"]+)"',
                     src[STEPS])
    if not pull or not line:
        found.append(
            f"{LANE_PY if not pull else STEPS}: the windows verb-trace "
            f"file is no longer named where this clause reads it (the "
            f"recorder's pull of the `verb-trace` section, and "
            f"check-steps' verb_trace_line)")
        return found
    if pull.group(1) != line.group(1):
        found.append(
            f"the windows launchers write "
            f"C:\\kaya\\flightrec\\<leg>-{line.group(1)} (check-steps' "
            f"verb_trace_line) and the recorder pulls "
            f"C:/kaya/flightrec/<leg>-{pull.group(1)} — one of the two "
            f"moved, so every red windows leg's bundle would read "
            f"verb-trace.skip")
    if f"-{pull.group(1)} " not in src[WIN].replace("\\\\", "\\"):
        found.append(
            f"{WIN}: does not delete C:\\kaya\\flightrec\\<leg>-"
            f"{pull.group(1)} before the leg — a trace left by the same "
            f"leg of a PREVIOUS lane run would be pulled and read as this "
            f"leg's")
    return found


def census_toast_files(src):
    """THE SAME RULE ONE DOOR OVER, for the toast moment's own records.
    No launcher names these — the GUEST writes them beside the verb trace
    (crates/kaya/src/winui/mod.rs, `capture_toast_moment`, through
    vtrace::sibling), so the clause above cannot reach them and the three
    places are the guest's write, the recorder's pull, and deploy-win's
    pre-leg delete. Either of the first two moving alone leaves
    `toast-moment.skip` on every red windows leg, which is the sentence
    this whole section exists to stop printing; the third missing reads a
    capture from a PREVIOUS run of the same leg as this one's."""
    found = []
    pulled = sorted(set(re.findall(
        r'C:/kaya/flightrec/\{leg\}-((?:toast|gesture|failshot)[\w.-]*)"', src[LANE_PY])))
    if not pulled:
        return [f"{LANE_PY}: the windows recorder pulls no toast-moment file "
                f"at all — the section's records are named nowhere this "
                f"clause can read them"]
    written = re.findall(r'sibling\("([\w.]+)"\)', src[WINUI])
    for suffix in pulled:
        # The WAL is derived from the database's own name, because sqlite
        # recovers it under no other.
        base = suffix[:-4] if suffix.endswith("-wal") else suffix
        if base not in written:
            found.append(
                f"{LANE_PY} pulls C:/kaya/flightrec/<leg>-{suffix}, and "
                f"{WINUI}'s toast capture writes no `{base}` beside the verb "
                f"trace (vtrace::sibling) — the section would carry its skip "
                f"on every red leg while the guest wrote a file nobody reads")
        if f"-{suffix} " not in src[WIN].replace("\\\\", "\\"):
            found.append(
                f"{WIN}: does not delete C:\\kaya\\flightrec\\<leg>-{suffix} "
                f"before the leg — a capture left by the same leg of a "
                f"PREVIOUS lane run would be pulled and read as this leg's "
                f"toast")
    return found


def census_guest_clock(src):
    """ONE CLOCK, AND IT IS THE PLATFORM'S. The windows sampler stamps
    every ring line with an epoch second and the host reads the guest's
    own epoch once a lane, and both used `Get-Date -UFormat %s`, which on
    Windows PowerShell 5.1 answers LOCAL time as though it were UTC
    (docs/traps.md, measured 25200s out on the lane's VM). The two agreed
    with each other, so nothing looked wrong until that clock met a
    PLATFORM timestamp: `render_wpn(db, since=…)` compares the leg's start
    against the notification database's FILETIMEs, and every row of the
    last seven hours read `ARRIVED INSIDE THIS LEG` (docs/deferred.md, the
    PopupHost WATCH's sixth sighting). No lane can fail this — a marker
    that is too wide marks MORE rows, never fewer."""
    found = []
    for rel in (GUEST_PS1, LANE_PY):
        # COMMENT-STRIPPED, because both files now NAME the broken call in
        # the prose that says not to use it.
        code = re.sub(r'"""[\s\S]*?"""', "", src[rel])
        code = "\n".join(ln for ln in code.splitlines()
                         if not ln.strip().startswith("#"))
        if "-UFormat %s" in code:
            found.append(
                f"{rel}: stamps an epoch with `Get-Date -UFormat %s`, which "
                f"answers LOCAL time as though it were UTC on Windows "
                f"PowerShell 5.1 — the guest's clock then sits one UTC offset "
                f"behind the notification database's own, and the toast "
                f"moment's `ARRIVED INSIDE THIS LEG` marker reads hours wide. "
                f"`[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()` is the call")
    if not re.search(r'\$at = \[DateTimeOffset\]::UtcNow\.ToUnixTimeSeconds\(\)',
                     src[GUEST_PS1]):
        found.append(
            f"{GUEST_PS1}: the ring's `at=` stamp is not "
            f"[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() — every section "
            f"that places a leg against that ring (the foreground head line, "
            f"desktop-live's window, the toast moment's marker) is read "
            f"against it")
    if "ToUnixTimeSeconds" not in py_block(src[LANE_PY], "clock_sync"):
        found.append(
            f"{LANE_PY}: clock_sync reads the guest's epoch some other way "
            f"than [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() — it must "
            f"read the clock the sampler stamps, or the offset it measures "
            f"is a timezone rather than a drift")
    return found


def census_collect_fresh(src):
    """THE OLD ANSWER GOES FIRST (docs/traps.md's run_guest_oneshot trap,
    met again by the recorder 2026-09-16): the windows collect polls for
    COLLECTDONE in a file a previous run of the same leg left complete, so
    a second red of one leg returned at once with the collect never run and
    pulled a file nine hours old as this leg's desktop. The collect deletes
    every output it writes BEFORE the task is created."""
    found = []
    body = py_block(src[LANE_PY], "collect")
    if body is None:
        return [f"{LANE_PY}: WinRecorder.collect is not where this clause reads it"]
    create = body.find("schtasks /create /tn kayafrc_")
    if create < 0:
        return [f"{LANE_PY}: WinRecorder.collect no longer creates its task by name"]
    head = body[:create]
    if "del " not in head or "collect.txt" not in head:
        found.append(
            f"{LANE_PY}: WinRecorder.collect does not delete its previous "
            f"outputs (<leg>-collect.txt and the pictures) before creating the "
            f"task — the poll for COLLECTDONE then answers from the last run's "
            f"file and the collect never runs")
    return found


def census_focus_ring(src):
    """THE LINUX FOCUS RING'S TWO ENDS, AND ITS LIFE (docs/deferred.md, the
    wayland clipboard seed entry). The `desktop` section is the sway tree at
    COLLECT, with the guest already gone, so the one question a wayland
    clipboard red asks — who held the seat while the leg ran — had no
    section at all. The ring answers it, and three things no lane can fail
    hold it up: the sampler's own file names against the names the collect
    cuts (census_vtrace's rule one lane over: either end moving alone leaves
    `focus.skip` on every red leg while a sampler writes a file nobody
    reads), the sampler being STARTED by the runner, and its being STOPPED
    by the EXIT trap — a ring nobody starts is a section that always skips,
    and a sampler nobody stops is a process left polling in a container that
    outlived its lane (docs/deferred.md's windows LEAK entry, one lane
    over)."""
    found = []
    ring = src[FOCUS_RING]
    runner = src[LINUX]
    names = sorted(set(re.findall(r'f"(focus-[\w-]+?-)\{number\}\.txt"',
                                  ring)))
    if len(names) != 2:
        found.append(
            f"{FOCUS_RING}: this clause reads the sampler's own ring file "
            f"names out of its emit calls and found {len(names)} — the two "
            f"halves (a wayland slot's and an x11 display's) are what the "
            f"collect cuts by name")
    for prefix in names:
        if f'"$FLIGHTREC_SCRATCH/{prefix}' not in runner:
            found.append(
                f"{LINUX}: the collect cuts no {prefix}… ring, but "
                f"{FOCUS_RING} writes one — a renamed end leaves focus.skip "
                f"on every red leg of that protocol while the sampler goes "
                f"on writing a file nobody reads")
    stop = re.search(r'stop = ring / "([^"]+)"', ring)
    if not stop:
        found.append(f"{FOCUS_RING}: names no stop file, so the runner's "
                     f"EXIT trap has no channel to end the sampler with")
    elif stop.group(1) not in runner:
        found.append(
            f"{LINUX}: never writes {FOCUS_RING}'s stop file "
            f"({stop.group(1)}) — the sampler would poll until its own "
            f"deadline, inside a container the lane has finished with")
    for call, why in (
            ("focus_ring_start",
             "the ring is never sampled, so every red leg's focus section "
             "is a skip"),
            ("focus_ring_stop",
             "the sampler outlives the lane")):
        if len(re.findall(rf"\b{call}\b", runner)) < 2:
            found.append(
                f"{LINUX}: `{call}` is declared and not called (or called "
                f"and not declared) — {why}")
    if "focus_ring_stop" not in sh_block(runner, "trap '", "' EXIT"):
        found.append(
            f"{LINUX}: the EXIT trap does not stop the focus sampler — a "
            f"lane that dies mid-run is exactly when it is left behind")
    if "--self-test" not in sh_block(runner, "focus_ring_start() {", "\n}\n"):
        found.append(
            f"{LINUX}: the lane does not run {FOCUS_RING}'s own self-test "
            f"before it samples — the cut's range is what tells this leg's "
            f"lines from the previous leg's, and nothing else watches it")
    return found

# -------------------------------------------------------------------- 10

def census_hand_run(src):
    """A RED FOUND BY HAND LEAVES THE LANE'S OWN BUNDLE (CLAUDE.md's
    flight-recorder rule; docs/deferred.md's hand-run entry, where a hand
    red could only be re-run). tools/run-leg.py runs ONE mac leg and
    reaches the recorder through MacRecorder's own entry points — never a
    second collect of its own — so the mac row's sections ARE the hand
    run's sections and clause 2 above answers for both. The half that
    reading the recorder alone cannot see: the sections adopted out of the
    leg's SCRATCH are filled by the launch wiring, so a hand run that
    launches its own guest keeps a bundle and loses exactly those."""
    found = []
    text = src[HAND]
    cls = RECORDERS["mac"]
    if f"{cls}(" not in text or ".mac_leg(" not in text:
        return [f"{HAND} does not collect through {cls}.mac_leg — a leg "
                f"that fails by hand then leaves no bundle at all, which "
                f"is the state docs/deferred.md's hand-run entry recorded"]
    fed = sorted(set(re.findall(r'self\.adopt\(bundle, "([\w-]+)", scratch',
                                py_block(src[LANE_PY], "_capture"))))
    if not fed:
        return [f"{LANE_PY}: MacRecorder._capture adopts no section out of "
                f"the leg's scratch — this clause reads that list to know "
                f"which sections the launch wiring answers for"]
    wiring = ""
    lines = src[LANE_PY].splitlines(keepends=True)
    for node in ast.walk(ast.parse(src[LANE_PY])):
        if not isinstance(node, ast.ClassDef) or node.name != cls:
            continue
        for fn in node.body:
            if not isinstance(fn, ast.FunctionDef):
                continue
            body = "".join(lines[fn.lineno - 1:fn.end_lineno])
            if "KAYA_VERB_TRACE" in body and "sampler_start(" in body:
                wiring = fn.name
    if not wiring:
        found.append(
            f"{LANE_PY}: no {cls} method fills a leg's scratch (the verb "
            f"trace's path in the leg's environment, the sampler over its "
            f"process), so sections {', '.join(fed)} have no one wiring "
            f"the hand run and the lane can share")
    elif f".{wiring}(" not in text:
        found.append(
            f"{HAND} does not launch its leg through {cls}.{wiring}, so "
            f"nothing fills the scratch: sections {', '.join(fed)} carry "
            f"finish()'s marker on every hand red while the lane's bundle "
            f"for the same leg carries them")
    return found


def census_ios_stamp(src):
    found = []
    if "binary-stamp" not in declared(src).get("ios", ()):
        found.append("ios: declares no binary-stamp section")
    for worker in ("_leg_worker", "_proof_worker", "_witness_worker"):
        if "keep_binary_stamp(" not in py_block(src[IOS], worker):
            found.append(f"ios: {worker} does not keep the executable SDK stamp")
    capture = py_block(src[IOS], "keep_binary_stamp")
    if not all(s in capture for s in ('"vtool", "-show-build"', 'CFBundleExecutable', '.sdk')):
        found.append("ios: binary-stamp does not read the bundle executable through vtool")
    if 'log.with_suffix(".sdk")' not in py_block(src[LANE_PY], "IosRecorder"):
        found.append("ios: binary-stamp does not adopt the SDK sidecar")
    return found


def census_ios_notifications(src):
    found = []
    if "notifications" not in declared(src).get("ios", ()):
        found.append("ios: declares no notifications section")
    leg = py_block(src[IOS], "run_swiftui_on")
    install = leg.find('"simctl", "install", udid')
    stamp = leg.find("installed_at = time.time()")
    if stamp < 0 or install < 0 or stamp > install:
        found.append("ios: the notification log's window does not start at the leg's install")
    if "notification_capture(udid, bundle_id, name, installed_at, log)" not in leg:
        found.append("ios: the failure path does not keep the notification side")
    capture = py_block(src[IOS], "notification_capture")
    if not all(s in capture for s in ("ios_notification_store(", '"--start", start',
                                      "IOS_NOTIFICATION_PREDICATE", '".notifications"')):
        found.append("ios: notification_capture no longer reads the store and the log window")
    text = src[LANE_PY]
    at = text.find("IOS_NOTIFICATION_PREDICATE = (")
    predicate = text[at:text.find("\n\n", at)] if at >= 0 else ""
    if not all(s in predicate for s in (
            'process == "usernotificationsd"', 'process == "SpringBoard" AND ',
            'subsystem BEGINSWITH "com.apple.UserNotifications"')):
        found.append("ios: the notification predicate lost SpringBoard or usernotificationsd")
    if 'log.with_suffix(".notifications")' not in py_block(src[LANE_PY], "IosRecorder"):
        found.append("ios: notifications does not adopt the runner's sidecar")
    return found


def ios_notification_checks(src, echo=False):
    import plistlib
    scope = {"pathlib": pathlib, "time": time}
    for name in ("_keyed_root", "ios_notification_store"):
        body = py_block(src[LANE_PY], name)
        if not body:
            return [f"ios: missing notification renderer {name}"]
        exec(compile(body, LANE_PY, "exec"), scope)

    def keyed(path, value):
        objs = ["$null"]

        def put(x):
            if isinstance(x, dict) and set(x) == {"date"}:
                objs.append({"NS.time": x["date"] - 978307200})
            elif isinstance(x, dict):
                slot = len(objs)
                objs.append(None)
                objs[slot] = {"NS.keys": [put(k) for k in x],
                              "NS.objects": [put(v) for v in x.values()]}
                return plistlib.UID(slot)
            elif isinstance(x, list):
                slot = len(objs)
                objs.append(None)
                objs[slot] = {"NS.objects": [put(v) for v in x]}
                return plistlib.UID(slot)
            else:
                objs.append(x)
            return plistlib.UID(len(objs) - 1)
        root = put(value)
        with open(path, "wb") as f:
            plistlib.dump({"$archiver": "NSKeyedArchiver", "$objects": objs,
                           "$top": {"root": root}, "$version": 100000}, f,
                          fmt=plistlib.FMT_BINARY)

    now = 1791429114.0
    found = []
    with tempfile.TemporaryDirectory(prefix="kaya-notif-store-") as d:
        root = pathlib.Path(d)
        (root / "LIVE").mkdir()
        (root / "GONE").mkdir()
        keyed(root / "Library.plist", {"dev.kaya.notifyswiftui": "LIVE"})
        keyed(root / "LIVE" / "DeliveredNotifications.plist", [
            {"AppNotificationIdentifier": "kaya-12", "AppNotificationTitle": "fresh",
             "AppNotificationCreationDate": {"date": now - 60}}])
        keyed(root / "GONE" / "DeliveredNotifications.plist", [
            {"AppNotificationIdentifier": "kaya-12", "AppNotificationTitle": "stale",
             "AppNotificationCreationDate": {"date": now - 8 * 86400}}])
        said = scope["ios_notification_store"](root, "dev.kaya.notifyswiftui", now=now)
        (root / "GONE" / "PendingNotifications.plist").write_bytes(b"not a plist")
        broken = scope["ios_notification_store"](root, "dev.kaya.notifyswiftui", now=now)
    if echo:
        print("check-flightrec: iOS notification store:\n" + said.rstrip())
    if "maps to section LIVE" not in said:
        found.append("ios: the store lost the leg's own section")
    if "2 record(s) held; 1 in a section no bundle maps" not in said:
        found.append("ios: the store lost the orphaned record")
    if "1 older than 7 days" not in said or "8.00 days old" not in said:
        found.append("ios: the store lost the expiry age")
    if "'kaya-12'" not in said or "stale" not in said:
        found.append("ios: the store lost the identifier or title")
    if "PendingNotifications.plist did not decode" not in broken:
        found.append("ios: the store hid an undecodable file")
    return found


def census_android_history(src):
    found = []
    sections = declared(src).get("android", ())
    for name in ("system-events", "anr-history", "shade-history"):
        if name not in sections:
            found.append(f"android: declares no {name} section")
    body = py_block(src[ANDROID], "run_apk_on")
    failures = []
    for node in ast.walk(ast.parse(body)):
        if isinstance(node, ast.If):
            tests = node.test.values if isinstance(node.test, ast.BoolOp) else [node.test]
            if any(isinstance(test, ast.Compare) and isinstance(test.left, ast.Constant)
                    and test.left.value == "KAYA_SELFTEST: OK"
                    and len(test.ops) == 1 and isinstance(test.ops[0], ast.NotIn)
                    for test in tests):
                failures.append(ast.get_source_segment(body, node))
    for call, suffix in (("android_system_events", ".system-events"),
                         ("android_anr_history", ".anr-history"),
                         ("android_shade_history", ".shade-history")):
        if not any(f"flightrec_lane.{call}(" in branch and f'"{suffix}"' in branch
                   for branch in failures):
            found.append(f"android: failure path does not write {suffix} through {call}")
    return found


def ios_recording_recovery(src):
    tree = ast.parse(py_block(src[IOS], "rec_suite_start"))
    branches = [node for node in ast.walk(tree) if isinstance(node, ast.If)
                and ast.unparse(node.test) == "wedged and (not retry)"]
    if len(branches) != 1:
        return ["ios: cannot locate one recording recovery branch"]
    branch = branches[0]
    if not isinstance(branch.body[-1], ast.Return):
        return ["ios: recording recovery no longer returns after retry"]
    calls = []
    scope = {"REC_PIDS": [], "UDIDS": ["phone"], "subprocess": subprocess,
             "time": types.SimpleNamespace(sleep=lambda _: None),
             "xcuidrive_stop_all": lambda: calls.append("stop drivers"),
             "run": lambda *a, **kw: calls.append("reset service"),
             "boot_pool": lambda: calls.append("boot pool"),
             "xcuidrive_launch_all": lambda: calls.append("launch drivers"),
             "xcuidrive_join": lambda: calls.append("join drivers"),
             "rec_suite_start": lambda **kw: calls.append("retry recording")}
    exec(compile(ast.Module(body=branch.body[:-1], type_ignores=[]), IOS, "exec"), scope)
    expected = ["stop drivers", "reset service", "boot pool", "launch drivers",
                "join drivers", "retry recording"]
    return [] if calls == expected else [f"ios: recording recovery driver lifecycle {calls}"]


def ios_recording_checks(src, png, film):
    def refuse(message):
        raise RuntimeError(message)
    scope = {"subprocess": subprocess, "die": refuse,
             "TEXT": {"text": True, "encoding": "utf-8", "errors": "replace"}}
    for name in ("_recording_probe", "_luma_of", "_film_edge_ms"):
        exec(compile(py_block(src[IOS], name), IOS, "exec"), scope)
    found = []
    for name, args, expected in (("_luma_of", (png,), 255),
                                 ("_film_edge_ms", (film, True), 1000)):
        try:
            answer = scope[name](*args)
            if answer != expected:
                found.append(f"ios: recording {name} read {answer}, wanted {expected}")
        except RuntimeError as error:
            found.append(f"ios: recording {name} failed: {error}")
    try:
        scope["_luma_of"](png.parent / "missing.png")
        found.append("ios: recording probe accepted a missing image")
    except RuntimeError as error:
        if "exited" not in str(error) or "missing.png" not in str(error):
            found.append("ios: recording probe hid the command failure")
    scope["_recording_probe"] = lambda _: "not a number"
    try:
        scope["_luma_of"](png)
        found.append("ios: recording probe invented a luma")
    except RuntimeError as error:
        if "no numeric luma" not in str(error):
            found.append("ios: recording probe lost the malformed output")
    return found


def android_recording_checks(src, film):
    scope = {"subprocess": subprocess,
             "TEXT": {"text": True, "encoding": "utf-8", "errors": "replace"}}
    exec(compile(py_block(src[ANDROID], "recording_duration_ms"), ANDROID, "exec"), scope)
    read = scope["recording_duration_ms"]
    found = []
    log = io.StringIO()
    if read(film, log) != 2000:
        found.append(f"android: recording duration changed: {log.getvalue()}")
    log = io.StringIO()
    if read(film.parent / "missing.mp4", log) != 0 or "exited" not in log.getvalue():
        found.append("android: recording probe hid command failure")
    for output in ("broken", "nan", "inf", "0", "-1"):
        scope["subprocess"] = types.SimpleNamespace(run=lambda *a, output=output, **kw:
            types.SimpleNamespace(returncode=0, stdout=output, stderr="probe detail"))
        log = io.StringIO()
        if (read(film, log) != 0 or "no positive duration" not in log.getvalue()
                or output not in log.getvalue() or "probe detail" not in log.getvalue()):
            found.append("android: recording probe guessed duration or hid malformed output")
    tree = ast.parse(py_block(src[ANDROID], "run_apk_on"))
    branches = [node for node in ast.walk(tree) if isinstance(node, ast.If)
                and any(isinstance(child, ast.Expr) and isinstance(child.value, ast.Call)
                        and isinstance(child.value.func, ast.Name)
                        and child.value.func.id == "device_capture" for child in node.body)]
    if len(branches) != 1:
        found.append("android: recording cannot locate failure capture")
    else:
        condition = compile(ast.Expression(branches[0].test), ANDROID, "eval")
        if not eval(condition, {"failed": True, "out": "KAYA_SELFTEST: OK"}):
            found.append("android: recording failure skipped recorder sections")
    if 'dur_ms = recording_duration_ms(rec_dir / "video.mp4", log)' not in src[ANDROID]:
        found.append("android: recording duration reader is not reached")
    pulls = [node for node in ast.walk(tree) if isinstance(node, ast.If)
             and ast.unparse(node.test) == "pulled"]
    if len(pulls) != 1 or 'dur_ms = 0' not in ast.unparse(pulls[0]):
        found.append("android: recording failed pull can reuse stale video")
    return found


def windows_recording_width(src):
    tree = ast.parse(src[WIN])
    assignments = [node for node in tree.body if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == "WIDTH"
                           for target in node.targets)]
    if len(assignments) != 1:
        return ["windows: cannot locate recording pool width"]
    found = []
    for environ, expected in (({}, 6), ({"KAYA_WIN_JOBS": "3"}, 3),
                              ({"KAYA_RECORD": "1"}, 1),
                              ({"KAYA_RECORD": "1", "KAYA_WIN_JOBS": "3"}, 1)):
        scope = {"os": types.SimpleNamespace(environ=environ)}
        exec(compile(ast.Module(body=assignments, type_ignores=[]), WIN, "exec"), scope)
        if scope["WIDTH"] != expected:
            found.append(f"windows: recording pool width {scope['WIDTH']} for {environ}, "
                         f"wanted {expected}")
    return found


def windows_recording_diagnostic(src, directory):
    capture = directory / "windows"
    capture.mkdir(exist_ok=True)
    (capture / "frames").mkdir(exist_ok=True)
    (capture / "frames/0-1234.png").write_bytes(b"test")
    (capture / "check.slot").write_text("2", encoding="utf-8")
    scope = {"re": re, "LEGS_DIR": capture,
             "run_ssh_out": lambda _: "KAYA_HARNESS: epoch 1000\nKAYA_HARNESS: +50ms end"}
    exec(compile(py_block(src[WIN], "_extract_leg_recording"), WIN, "exec"), scope)
    found = []
    if scope["_extract_leg_recording"]("check", capture):
        found.append("windows: recording accepted no matching frames")
    said = (capture / "check/extract.log").read_text(encoding="utf-8")
    for part in ("slot=2", "range=-500..3050", "total frames=1", "recorder.log"):
        if part not in said:
            found.append(f"windows: recording diagnostic lost {part}")
    body = py_block(src[WIN], "rec_suite_stop")
    if '(recdir / "recorder.log").write_text(recorder_log, encoding="utf-8")' not in body:
        found.append("windows: recording did not retain capturer transcript")
    return found


def census_frontmost(src):
    """A MISSING PID NEVER PHOTOGRAPHS THE FRONTMOST WINDOW (docs/traps.md,
    2026-09-28): the window list read `Int("None")` as no filter and listed
    every window, and shot_pid took the first, which was the human's
    terminal. Both halves refuse now, the shot before it reaches
    screencapture."""
    found = []
    shot = py_block(src[LANE_PY], "shot_pid")
    guard = shot.find("if not isinstance(pid, int)")
    grab = shot.find('"screencapture"')
    if guard < 0 or (grab >= 0 and guard > grab):
        found.append("mac: shot_pid does not refuse a pid that is not a positive "
                     "integer before it reaches screencapture")
    if 'is not a pid")' not in src[WINLIST] or "exit(2)" not in src[WINLIST]:
        found.append("mac: flightrec-winlist does not refuse an argument that is "
                     "not a pid, so a missing pid lists every window")
    return found


def desktop_shot_checks(src):
    """THE DESKTOP IS PHOTOGRAPHED ONLY ON AN IDLE HOST (the maintainer's
    ruling of 2026-09-28): shot_desktop cut out and run against a doubled
    idle clock and a doubled screencapture that counts its calls."""
    import textwrap
    found = []
    body = textwrap.dedent(py_block(src[LANE_PY], "shot_desktop"))
    if not body:
        return ["mac: shot_desktop is gone, so the idle rule is unread"]
    for idle, makes, want_shot, want_none in ((5, True, False, False),
                                              (None, True, False, False),
                                              (9999, False, True, False),
                                              (9999, True, True, True)):
        calls = []

        def run(argv, **_kw):
            calls.append(argv)
            if makes:
                pathlib.Path(argv[-1]).write_bytes(b"png")

        lane = types.ModuleType("lanes.mac")
        lane.DESKTOP_SHOT_IDLE_S = 120.0
        lane.hid_idle_seconds = (lambda i=idle: (i, None) if i is not None
                                 else (None, "doubled unreadable"))
        pkg = types.ModuleType("lanes")
        pkg.mac = lane
        saved = {k: sys.modules.get(k) for k in ("lanes", "lanes.mac")}
        sys.modules.update({"lanes": pkg, "lanes.mac": lane})
        scope = {"pathlib": pathlib,
                 "shutil": types.SimpleNamespace(which=lambda _n: "/usr/sbin/screencapture"),
                 "subprocess": types.SimpleNamespace(run=run, DEVNULL=None)}
        try:
            exec(compile(body, LANE_PY, "exec"), scope)
            with tempfile.TemporaryDirectory() as tmp:
                said = scope["shot_desktop"](None, pathlib.Path(tmp) / "d.png")
                when = pathlib.Path(tmp) / "d.when"
                when = when.read_text(encoding="utf-8") if when.is_file() else ""
        except (TypeError, ValueError, AttributeError, KeyError, OSError) as e:
            found.append(f"mac: shot_desktop with HIDIdleTime {idle} raised "
                         f"{type(e).__name__}: {e}")
            continue
        finally:
            for k, v in saved.items():
                if v is None:
                    sys.modules.pop(k, None)
                else:
                    sys.modules[k] = v
        if bool(calls) != want_shot:
            found.append(f"mac: shot_desktop with HIDIdleTime {idle} "
                         f"{'photographed' if calls else 'did not photograph'} "
                         f"the desktop")
        if (said is None) != want_none:
            found.append(f"mac: shot_desktop with HIDIdleTime {idle} answered {said!r}")
        if said is None and f"HIDIdleTime {idle}s" not in when:
            found.append(f"mac: shot_desktop photographed the desktop at HIDIdleTime "
                         f"{idle} and wrote no sentence naming that reading ({when!r})")
    return found


def winlist_refuses_nonsense():
    """The real binary, asked about "None": it must exit nonzero and list
    no window. Built by the recorder's own builder (content-hashed)."""
    import subprocess
    from flightrec_lane import winlist_bin
    binary = winlist_bin(pathlib.Path(__file__).resolve().parent.parent)
    if not binary:
        return ["mac: the window list did not build, so its refusal is unverified"]
    got = subprocess.run([binary, "None"], capture_output=True, text=True,
                         encoding="utf-8", errors="replace", check=False)
    if got.returncode == 0 or "win=" in got.stdout:
        return [f"mac: flightrec-winlist None exited {got.returncode} and listed "
                f"{got.stdout.count('win=')} window(s)"]
    print(f"check-flightrec: flightrec-winlist None refused: {got.stdout.strip()}")
    return []


def mac_power_checks(src, echo=False):
    scope = {"re": re}
    exec(compile(py_block(src[LANE_PY], "mac_power_history"), LANE_PY, "exec"), scope)
    render = scope["mac_power_history"]
    found = []
    capture = py_block(src[LANE_PY], "MacRecorder")
    if ('["pmset", "-g", "log"]' not in capture
            or 'mac_power_history(power_text, power_code)' not in capture
            or "power-history" not in declared(src).get("mac", ())):
        found.append("mac: power capture no longer reads and renders pmset history")
    events = [f"2026-09-20 18:52:44 -0700 Sleep event-{n:03d}" for n in range(201)]
    events += ["2026-09-20 18:54:47 -0700 DarkWake event-newest",
               "2026-09-20 18:54:48 -0700 Wake event-awake",
               "2026-09-20 18:54:49 -0700 Notification Display is turned on"]
    noise = "2026-09-20 18:54:47 -0700 Kernel Client Acks: Sleep unrelated noise"
    said = render("\n".join([*events, noise]), 0)
    if (any(line not in said for line in events[-200:]) or "event-000" in said
            or "unrelated noise" in said or "Selected 204 event(s)" not in said):
        found.append("mac: power history lost newest events or retained unrelated noise")
    if "not current-leg attribution" not in said:
        found.append("mac: power history claimed current-leg attribution")
    for code, text, expected in ((0, "noise", "Selected 0 event(s)"),
                                 (1, "permission denied", "power-history capture status 1"),
                                 (124, "deadline", "power-history capture status 124")):
        answer = render(text, code)
        if expected not in answer or (code and text not in answer):
            found.append("mac: power diagnostic lost its measured result")
        if echo:
            print(f"check-flightrec: Mac power: {answer.strip()}")
    return found


GTK_MEDIA_NOTES = (
    ("media_action", "the view's media.play/media.pause action reaching the arm"),
    ("player_command", "the command and whether the player had loaded"),
    ("player_state", "the playbin's own state change"))


def census_gtk_media_ring(src):
    """A GTK MEDIA RED NAMES WHICH LINK DROPPED (docs/traps.md, an OCaml guest
    naming a sibling guest's module): media_session-go-x11's `ax_action video#0
    "Pause"` reached the app (the ring advanced) and produced no transaction,
    and its bundle could not say whether the action, the command or the
    pipeline went quiet."""
    found = []
    for verb, what in GTK_MEDIA_NOTES:
        if f'sheet_note("{verb}", ' not in src[GTK_RS]:
            found.append(f"gtk: {what} no longer reaches the verb trace ({verb})")
    return found


def mac_timeout_checks(src, echo=False):
    """A MAC LEG `timeout 120` KILLED NAMES THE STEP IT WAS IN (docs/traps.md,
    an OCaml guest naming a sibling guest's module runs that guest): every
    OCaml media leg ran another scene, failed each step to its 15 s retry, and
    was killed with no verdict, and its bundle's verb-trace sentence listed
    three ways a leg can end without saying which one this was."""
    found = []
    scope = {"re": re, "pathlib": pathlib}
    for name in ("mac_last_step", "mac_timeout_sentence", "mac_no_trace_sentence"):
        block = py_block(src[LANE_PY], name)
        if not block:
            return [f"mac: {name} is gone from {LANE_PY}"]
        exec(compile(block, LANE_PY, "exec"), scope)
    watched = py_block(src[LANE_PY], "watched_leg")
    status = watched.find('(scratch / "exit-status.txt").write_text(f"{rc}\\n"')
    if status < 0 or status < watched.find("rc = proc.wait()"):
        found.append("mac: watched_leg no longer records the leg's exit status after it ends")
    if not re.search(r"if rc == 124:\n(?:.*\n){0,2}? +killed = mac_timeout_sentence\(", watched):
        found.append("mac: watched_leg no longer writes the timeout sentence into the leg log")
    capture = py_block(src[LANE_PY], "_capture")
    adopt = ('scratch / "verb-trace.txt",\n'
             '                   why_absent=mac_no_trace_sentence(scratch, log))')
    if adopt not in capture:
        found.append("mac: the verb-trace section's absence no longer reads the exit status")
    with tempfile.TemporaryDirectory() as tmp:
        d = pathlib.Path(tmp)
        log = d / "leg.log"
        log.write_text("KAYA_HARNESS: scene ready after 9ms\n"
                       "KAYA_HARNESS: +9ms expect_title \"media\"\n"
                       "KAYA_HARNESS: step-failed title \"tracks\", wanted \"media\"\n"
                       "KAYA_HARNESS: +15011ms expect label#1 \"next 0\"\n", encoding="utf-8")
        bare = d / "bare.log"
        bare.write_text("dyld: missing symbol\n", encoding="utf-8")
        cases = [("no status", None, log, "recorded no exit status"),
                 ("killed in a step", "124", log,
                  'exit 124) with no verdict, in step `+15011ms expect label#1 "next 0"`'),
                 ("killed before a step", "124", bare, "before any step"),
                 ("killed, streamed", "124", None, "streamed to the terminal"),
                 ("a crash", "134", log, "exited 134"),
                 ("the runner's refusal", "0", log, "its own verdict passing")]
        for what, rc, leg_log, want in cases:
            st = d / "exit-status.txt"
            st.unlink(missing_ok=True)
            if rc is not None:
                st.write_text(rc + "\n", encoding="utf-8")
            said = scope["mac_no_trace_sentence"](d, leg_log)
            if echo:
                print(f"check-flightrec: mac no-trace ({what}): {said}")
            if want not in said:
                found.append(f"mac: branch `{what}` did not print `{want}`: {said}")
    return found


def mac_unified_log_checks(src, echo=False):
    """docs/traps.md, the toast that outlived its seconds: replayd's flood
    filled the one-query section's cap before the leg and kept the head."""
    kept = re.search(r"^REPEATS_KEPT = (\d+)$", src[LANE_PY], re.M)
    scope = {"subprocess": subprocess, "re": re, "SECTION_CAP": 1000,
             "REPEATS_KEPT": int(kept.group(1)) if kept else 0}
    exec(compile(py_block(src[LANE_PY], "mac_log_collapse"), LANE_PY, "exec"), scope)
    exec(compile(py_block(src[LANE_PY], "mac_unified_log"), LANE_PY, "exec"), scope)
    found = []
    if "mac_unified_log(self._sampler_pid(scratch))" not in py_block(src[LANE_PY], "_capture"):
        found.append("mac: the unified-log section is no longer mac_unified_log "
                     "over the leg's guest pid")
    asked = []
    stamp = b"2026-10-14 13:44:14.317 Df "
    loop = stamp + b"node[4242:10904b4c] (ReplayKit) RPDaemonProxy: connection INTERRUPTED\n"

    def fake(argv, **_):
        predicate = argv[argv.index("--predicate") + 1]
        asked.append(predicate)
        guest = predicate.startswith("processID == 4242")
        body = (stamp + b"node[4242:1] guest-oldest\n" + stamp + b"node[4242:1] "
                + b"g" * 300 + b"\n" + stamp + b"node[4242:1] guest-moment\n" + loop * 400
                + stamp + b"node[4242:1] guest-newest\n" if guest
                else b"flood-oldest\n" + b"r" * 5000 + b"\nflood-newest\n")
        return subprocess.CompletedProcess(argv, 0 if guest else 1, body)
    text, state = scope["mac_unified_log"](4242, cap=20000, run=fake)
    if any("processID == 4242" in p and "replayd" in p for p in asked):
        found.append(f"mac: the guest's lines share a query with replayd ({asked})")
    if not any("mediaremoted" in p and "perl" in p for p in asked):
        found.append("mac: no MediaRemote section — a remote command that never left the "
                     "helper reads as one the guest dropped (docs/traps.md, the session_send "
                     "that never left perl)")
    if not any("RPDaemonProxy: connection INTERRUPTED" in p and "processID" not in p
               for p in asked):
        found.append("mac: no every-process replayd connection-loss section — the guest that "
                     "cut this one's capture off goes unnamed (docs/traps.md, the pooled ink "
                     "read that never answered)")
    if "guest-moment" not in text or "repeated 400 times" not in text:
        found.append("mac: a repeated message filled the guest's share and the step before "
                     "it was cut (no collapse, or the repeats not counted)")
    if "guest-oldest" not in text or "guest-newest" not in text:
        found.append("mac: the guest's own lines did not survive replayd's flood")
    if "flood-newest" not in text or "flood-oldest" in text:
        found.append("mac: an over-cap query kept its oldest lines instead of its newest")
    if text.find("guest-newest") > text.find("flood-newest"):
        found.append("mac: the guest's lines no longer come first")
    if state != "error" or "exit 1" not in text:
        found.append("mac: a failed log query was not reported with its exit")
    if echo:
        print("check-flightrec: Mac unified log: " + " | ".join(
            line for line in text.splitlines() if line.startswith("== ")))

    def absent(argv, **_):
        raise FileNotFoundError(2, "No such file or directory", argv[0])
    try:
        gone, gone_state = scope["mac_unified_log"](4242, cap=1000, run=absent)
    except OSError:
        found.append("mac: an absent `log` tool raised out of the collect, so "
                     "the bundle loses every section after it")
    else:
        if gone_state != "error" or "not run" not in gone or "'log'" not in gone:
            found.append("mac: an absent `log` tool was not reported, by name, "
                         "as not run")
    return found


def android_report_checks(src, echo=False):
    scope = {"re": re}
    for name in ("android_system_events", "android_anr_history", "android_shade_history"):
        body = py_block(src[LANE_PY], name)
        if not body:
            return [f"android: missing report renderer {name}"]
        exec(compile(body, LANE_PY, "exec"), scope)
    render = scope["android_anr_history"]
    package = "dev.kaya.javahost"
    def entry(stamp, owner):
        return ("========================================\n"
                f"{stamp} data_app_anr\nProcess: {owner}\nPID: 18476\n"
                f"Timestamp: {stamp}\nmain stack\n")
    text = ("Drop box contents: 3 entries\n" + entry("2026-09-19 12:00:00", package)
            + entry("2026-09-20 15:28:00", package)
            + entry("2026-09-20 15:29:00", "dev.kaya.other"))
    answer = render(package, text, 0)
    found = []
    if "Matched 2 of 3" not in answer or "Process: dev.kaya.other" in answer:
        found.append("android: ANR history did not filter by exact package")
    if "Reports can predate this leg" not in answer:
        found.append("android: ANR history claimed current-leg attribution")
    if answer.find("2026-09-20 15:28:00") > answer.find("2026-09-19 12:00:00"):
        found.append("android: newest ANR did not precede the old report")
    cases = (("empty", "(No entries found.)", 0, "Matched 0 of 0"),
             ("read failure", "permission denied", 1, "DropBox read exited 1; no ANR verdict"),
             ("timeout", "partial output", 124, "DropBox read exited 124; no ANR verdict"),
             ("format", "unknown format", 0, "Unrecognized DropBox output; no ANR verdict"))
    for label, output, code, expected in cases:
        said = render(package, output, code)
        if expected not in said or (code and output not in said):
            found.append(f"android: ANR {label} diagnostic lost its measured result")
        if echo:
            print(f"check-flightrec: Android {label}: {said.strip()}")
    events = ["input_focus: Focus entering Application Not Responding",
              "am_anr  : waited for FocusEvent", "ANR in dev.kaya.javahost",
              "Input dispatching timed out", "Denying clipboard access",
              "ClipboardOverlay", "wm_pause_activity:", "wm_resume_activity:",
              "wm_set_resumed_activity:",
              "WindowManager: Drop result=true reported by token",
              "WindowManager: Sending DRAG_ENDED to Window{kaya}",
              "VRI[MainActivity]: Reporting drop result: true",
              "KAYA_DRAG_EVENT: source detached ended=false",
              "KAYA_DRAG_STARTED: draganddrop",
              "KAYA_REQUEST: draganddrop 6 96 64 106 128 1500",
              "KAYA_ACK: draganddrop 6",
              "CCodec  : allocate(c2.goldfish.h264.decoder)",
              "CCodec  : Created component [c2.goldfish.h264.decoder]",
              "C2GoldfishAvcDec: calling onInit",
              "GoldfishComponentStore: created component",
              "hw-IPCThreadState: All binder threads in pool (8 threads) busy for 15021 ms",
              "C2BqBuffer: cannot dequeue buffer 0",
              "CCodec  : [c2.android.aac.decoder] previous call to flush exceeded timeout",
              "kaya    : media: player 1 failed media3 1003 underlying 0: ERROR_CODE_TIMEOUT: "
              "Unexpected runtime error: Detaching surface timed out.",
              "init    : Service 'android-hardware-media-c2-goldfish-hal-1-0' (pid 394) "
              "received signal 31"]
    timeline = scope["android_system_events"]("\n".join([*events, "unrelated noise"]))
    if any(event not in timeline for event in events) or "unrelated noise" in timeline:
        found.append("android: system timeline dropped a focus/ANR event, drag event or "
                     "media codec event, or kept unrelated noise")
    if "Selected 0 line(s)" not in scope["android_system_events"]("unrelated noise"):
        found.append("android: empty system timeline did not report its zero count")
    shade = scope["android_shade_history"]
    buffers = ("    10-07 12:22:33.648 V systemui.shade: New panel State: CLOSED\n"
               "    10-07 12:22:33.068 D systemui.shadewindow: Updating shade, should be "
               "focusable : false\n"
               "    10-07 12:22:33.680 D systemui.shadewindow: Updating shade, should be "
               "visible and focusable: false\n"
               "    10-07 12:22:19.367 V systemui.shade: NPVC mLastFlingWasExpanding set to: true\n"
               "    10-07 12:22:18.994 D systemui.shade: onFlingEnd called\n"
               "    10-07 12:22:19.352 D RemoteInputControllerLog: removeRemoteInput reason: "
               "RemoteInputView#onDetachedFromWindow\n"
               "    10-07 12:22:19.400 D systemui.shadewindow: Setting isExpanded to true\n")
    history = shade(buffers, 0)
    kept = [line.strip()[19:] for line in buffers.splitlines() if "isExpanded" not in line]
    if any(event not in history for event in kept) or "Setting isExpanded" in history:
        found.append("android: shade history dropped a panel, focus or remote-input event, "
                     "or kept window noise")
    stamps = re.findall(r"^10-07 (\d\d:\d\d:\d\d\.\d+) ", history, re.M)
    if stamps != sorted(stamps) or len(stamps) != 6:
        found.append(f"android: shade history is not oldest first across buffers: {stamps}")
    if "History can predate this leg" not in history:
        found.append("android: shade history claimed current-leg attribution")
    failed = shade("Bad service", 124)
    if "SystemUI dump exited 124; no shade history" not in failed or "Bad service" not in failed:
        found.append("android: shade history read failure lost its measured result")
    if echo:
        print(f"check-flightrec: Android shade history: {history.strip()}")
        print(f"check-flightrec: Android timeline: {timeline.strip()}")
        print(f"check-flightrec: Android history: {answer.strip()}")
    return found


def rust_fn(text, header):
    at = text.find(header)
    start = text.find("{", at) if at >= 0 else -1
    if start < 0:
        return ""
    depth = 0
    for i in range(start, len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[start:i + 1]
    return ""


def census_wedge_capture(src):
    """The linux harness's stacks at the ceiling (docs/traps.md, the wedged
    media_feed leg): eu-stack's ~360 KB blocked on a pipe read only after
    exit, so every wedged media leg's bundle said "ran past 10 s"."""
    found = []
    wedge = rust_fn(src[HARNESS], "fn wedge_stacks()")
    cap = rust_fn(src[HARNESS], "fn ceiling_capture(")
    if not wedge or not cap:
        return ["harness.rs: wedge_stacks or ceiling_capture is gone — re-point "
                "this clause at whatever prints the stacks at the ceiling"]
    for needle, why in (('ceiling_capture("thread stacks at the ceiling", "eu-stack"',
                         "no thread stacks"),
                        ('ceiling_capture("processes at the ceiling", "ps"',
                         "no process sample"),
                        ('"/proc/loadavg"', "no load sample")):
        if needle not in wedge:
            found.append(f"harness.rs: wedge_stacks leaves {why} at the ceiling")
    drained = [cap.find(f"drain(child.{p}.take())") for p in ("stdout", "stderr")]
    waits = cap.find("try_wait()")
    if min(drained) < 0 or "read_to_end" not in rust_fn(cap, "fn drain") \
            or "std::thread::spawn" not in rust_fn(cap, "fn drain") \
            or waits < 0 or max(drained) > waits:
        found.append("harness.rs: ceiling_capture does not drain its pipes on "
                     "threads before it waits — a pipe read only after exit "
                     "blocks eu-stack past the bound")
    if "wait_with_output" in cap:
        found.append("harness.rs: ceiling_capture reads its output with "
                     "wait_with_output, after the child exits")
    if '.env_remove("DEBUGINFOD_URLS")' not in cap:
        found.append("harness.rs: ceiling_capture lets eu-stack ask debuginfod "
                     "servers inside its 10 s bound")
    test = rust_fn(src[HARNESS], "fn ceiling_capture_drains_a_large_output()")
    if 'ceiling_capture("bytes", "head", &["-c", "1000000"' not in test:
        found.append("harness.rs: the unit test running ceiling_capture over "
                     "more than a pipe holds is gone")
    return found


def census_ios_stacks(src):
    """THE iOS CEILING'S STACKS (docs/traps.md): the app leaves at its own
    ceiling, so the host must sample it while the watchdog holds the exit,
    and the two ends meet through two file names in the app's Documents."""
    found = []
    swift = src[SWIFTUI]
    at = swift.find("final class KayaStepWatchdog")
    fire = swift[at:swift.find("_exit(1)", at)] if at >= 0 else ""
    if "kayaCeilingStacks(step)" not in fire or \
            fire.find("kayaCeilingStacks(step)") > fire.find("KayaVTrace.dump"):
        found.append("swift: the step watchdog's fire path no longer asks the host for "
                     "stacks before it dumps the trace and leaves")
    ask = swift[swift.find("func kayaCeilingStacks("):]
    ask = ask[:ask.find("\n    }\n")]
    wait = re.search(r"kayaCeilingStacksWait: TimeInterval = (\d+)", swift)
    leg = py_block(src[IOS], "run_swiftui_on")
    watch = py_block(src[IOS], "stacks_watch")
    take = py_block(src[IOS], "stacks_take")
    for name in ("kaya-stacks-request", "kaya-stacks-done"):
        if f'"{name}"' not in ask or f'"{name}"' not in watch:
            found.append(f"ios: {name} is not the one file name kayaCeilingStacks and "
                         f"stacks_watch both use")
    if "target=stacks_watch" not in leg or '.with_suffix(".stacks")' not in leg \
            or "stacks.start()" not in leg or "stacks_stop.set()" not in leg:
        found.append("ios: run_swiftui_on does not run stacks_watch around the launch")
    cap = re.search(r"^STACKS_SAMPLE_CAP = (\d+)$", src[IOS], re.M)
    if not cap or "min(STACKS_SAMPLE_CAP, int(deadline - time.time()))" not in take \
            or '["timeout", str(bound), "sample", pid,' not in take:
        found.append("ios: stacks_take does not run `sample` on the app under the cap "
                     "and the leg's deadline")
    elif not wait or int(cap.group(1)) >= int(wait.group(1)):
        found.append("ios: stacks_take's bound is not inside the harness's wait for it, "
                     "so the app can leave before its stacks are written")
    if 'log.with_suffix(".stacks")' not in py_block(src[LANE_PY], "IosRecorder"):
        found.append("ios: stacks does not adopt the runner's sidecar")
    census = swift[swift.find("func kayaCeilingAnimations("):]
    if "animations at the ceiling: \\(kayaCeilingAnimations())" not in ask \
            or "layer.animationKeys()" not in census:
        found.append("swift: the ceiling no longer prints every layer's animations, the "
                     "reading that rules a CALayer in or out of XCTest's animations-idle "
                     "wait")
    fail = leg[leg.find("if not ok:"):]
    if "xl.seek(xcode_log_at)" not in fail:
        found.append("ios: a failed leg's log no longer carries XCTest's own idle waits")
    return found


def census_ios_app_log(src):
    """docs/traps.md, the app log selected by process name."""
    found = []
    leg = py_block(src[IOS], "run_swiftui_on")
    launch = leg.find('"simctl", "launch", "--console-pty"')
    stamp = leg.find("launched_at = time.time()")
    if stamp < 0 or launch < 0 or stamp > launch:
        found.append("ios: the app log's window does not start at the leg's launch")
    if "flightrec_lane.ios_launch_pid(out, bundle_id), launched_at)" not in leg:
        found.append("ios: the failure path does not hand device_capture the launch's pid")
    capture = py_block(src[IOS], "device_capture")
    if 'f"processID == {pid}"' not in capture or '"--start", since,' not in capture:
        found.append("ios: the app log is not selected by the launch's pid from its launch")
    if "flightrec_lane.ios_xctest_idle(body)" not in capture:
        found.append("ios: the app log does not lead with XCTest's idle waits")
    if 'log.with_suffix(".applog")' not in py_block(src[LANE_PY], "IosRecorder"):
        found.append("ios: app-log does not adopt the runner's sidecar")
    return found


def ios_app_log_checks(src, echo=False):
    scope = {"re": re, "datetime": datetime}
    for name in ("ios_launch_pid", "ios_xctest_idle", "_log_time"):
        body = py_block(src[LANE_PY], name)
        if not body:
            return [f"ios: missing app-log reader {name}"]
        exec(compile(body, LANE_PY, "exec"), scope)
    for const in ("IOS_XCTEST_LATE = ", "IOS_XCTEST_IDLE = ("):
        at = src[LANE_PY].find(const)
        exec(compile(src[LANE_PY][at:src[LANE_PY].find("\n\n", at)], LANE_PY, "exec"), scope)
    ask = "[com.apple.dt.xctest:Default] Received request to notify when"
    rows = [
        f"2026-10-12 15:22:51.280 Df go[53460:1] {ask} the main run loop is idle",
        "2026-10-12 15:22:51.280 Df go[53460:2] [com.apple.dt.xctest:Default] "
        "Sending main run loop idle reply",
        f"2026-10-12 15:22:51.280 Df go[53460:1] {ask} animations are idle",
        "2026-10-12 15:22:51.280 Df go[53460:1] [com.apple.dt.xctest:Default] "
        "Sending animations idle reply with error: (null)",
        f"2026-10-12 15:22:51.566 Df go[53460:1] {ask} the main run loop is idle",
        f"2026-10-12 15:22:51.566 Df go[53460:1] {ask} animations are idle",
        "2026-10-12 15:22:51.566 Df go[53460:2] [com.apple.dt.xctest:Default] "
        "Sending main run loop idle reply",
        "2026-10-12 15:23:52.334 Df go[53460:2] [com.apple.UIKit] last line"]
    stalled = scope["ios_xctest_idle"]("\n".join(rows))
    clean = scope["ios_xctest_idle"]("\n".join(rows[:4]))
    reply = ("[com.apple.dt.xctest:Default] Sending animations idle reply with error: (null)")
    late = scope["ios_xctest_idle"]("\n".join([
        f"2026-10-14 13:48:56.105 Df go[84555:1] {ask} animations are idle",
        f"2026-10-14 13:49:56.232 Df go[84555:1] {ask} animations are idle",
        f"2026-10-14 13:49:56.232 Df go[84555:2] {reply}",
        f"2026-10-14 13:49:56.232 Df go[84555:2] {reply}"]))
    empty = scope["ios_xctest_idle"]("Timestamp               Ty Process[PID:TID]\n")
    pid = scope["ios_launch_pid"]("noise\ndev.kaya.timecodego: 53460\n", "dev.kaya.timecodego")
    other = scope["ios_launch_pid"]("dev.kaya.milestone2go: 1\n", "dev.kaya.timecodego")
    if echo:
        print("check-flightrec: iOS app log, stalled: " + stalled)
    found = []
    if "animations asked 2, answered 1" not in stalled or \
            "NEVER ANSWERED: animations asked at 2026-10-12 15:22:51.566" not in stalled:
        found.append("ios: the app log's idle reading lost the unanswered animations wait")
    if "main run loop asked 2, answered 2" not in stalled or "main run loop asked at" in stalled:
        found.append("ios: the app log's idle reading misreads an answered main run loop wait")
    if "every one answered" not in clean or "the longest wait 0.00 s" not in clean:
        found.append("ios: the app log's idle reading calls an answered slice unanswered")
    if echo:
        print("check-flightrec: iOS app log, late: " + late)
    if "ANSWERED LATE" not in late or \
            "animations asked at 2026-10-14 13:48:56.105 answered 60.13 s later" not in late or \
            "every one answered" in late:
        found.append("ios: the app log's idle reading calls a 60 s animations wait answered "
                     "(the submit-go red of 2026-10-14, two replies after XCTest gave up)")
    if "holds no lines at all" not in empty:
        found.append("ios: the app log's idle reading does not say its slice was empty")
    if pid != 53460 or other is not None:
        found.append("ios: the launch's pid is not read off simctl's own line for the bundle")
    return found


def census_ios_hang_record(src):
    """docs/traps.md, XCTest's animations-idle wait: what XCTest counts, read from inside
    the app at the ceiling and 15 s into a driver request, and the system's account of
    the app beside it."""
    found = []
    swift = src[SWIFTUI]
    ledger = swift[swift.find("final class KayaAnimationLedger"):]
    ledger = ledger[:ledger.find("\n    func kayaCeilingStacks(")]
    ask = swift[swift.find("func kayaCeilingStacks("):]
    ask = ask[:ask.find("\n    }\n")]
    if 'KayaAnimationLedger.shared.reading("at the ceiling")' not in ask:
        found.append("swift: the step ceiling no longer prints XCTest's animation count and "
                     "the ledger")
    slow = swift[swift.find("enum KayaSimdrive"):]
    slow = slow[:slow.find("\n    }\n")]
    if "kayaDriverSlowReading" not in slow or \
            "KayaAnimationLedger.shared.reading(moment)" not in slow:
        found.append("swift: a driver request still unanswered after kayaDriverSlowReading "
                     "no longer prints the animation reading")
    slow_at = re.search(r"kayaDriverSlowReading: TimeInterval = (\d+)", swift)
    ceiling = re.search(r"let kayaStepCeiling: TimeInterval = (\d+)", swift)
    if not slow_at or not ceiling or int(slow_at.group(1)) >= int(ceiling.group(1)):
        found.append("swift: kayaDriverSlowReading is not inside the step ceiling, so the "
                     "reading cannot land while XCTest still waits")
    harness = swift[swift.find("let watchdog = KayaStepWatchdog("):]
    if "KayaAnimationLedger.shared.install()" not in harness[:400]:
        found.append("swift: the harness no longer installs the animation ledger when it starts")
    ready = harness.find('print("KAYA_HARNESS: scene ready after')
    attach = harness.find('KayaSimdrive.ask("attach", timeout: kayaDriverAttachWait)')
    first = harness.find("scriptLines: for rawLine in script")
    gate_at = harness.find('environment["KAYA_DRIVER_ATTACH"] != nil')
    settle = harness.find("while !KayaAnimationLedger.shared.quiet(for: kayaDriverAttachQuiet), "
                          "Date() < settled {")
    if not (0 <= ready < gate_at < settle < attach < first):
        found.append("swift: the xcui driver is no longer attached between the scene's mount "
                     "and the first step, after the ledger reads no UIView animation open or "
                     "moving (docs/traps.md, XCTest's notifier loaded over an open animation)")
    quiet = re.search(r"kayaDriverAttachSettle: TimeInterval = (\d+)", swift)
    wait = re.search(r"kayaDriverAttachWait: TimeInterval = (\d+)", swift)
    if not quiet or not wait or not ceiling or \
            int(quiet.group(1)) + int(wait.group(1)) >= int(ceiling.group(1)):
        found.append("swift: the attach's settle and wait are not inside the step ceiling")
    sim = src[IOS]
    leg = py_block(sim, "run_swiftui_on")
    if 'if needs_driver(script):\n        env["SIMCTL_CHILD_KAYA_DRIVER_ATTACH"] = "1"' not in leg:
        found.append("ios: a leg whose verbs reach the xcui driver is not told to attach it "
                     "before its first step")
    watch = py_block(sim, "simdrive_watch")
    if 'if attached and parts != ["attach"]:' not in watch:
        found.append("ios: the watcher forwards the harness's attach to the driver as a verb")
    enter = swift[swift.find("    func enter(_ step: String) {\n        lock.lock()\n"
                             "        self.step"):]
    if "KayaAnimationLedger.shared.enter(step)" not in enter[:400]:
        found.append("swift: the watchdog's enter no longer tells the ledger which step runs")
    for want, why in (
            ('NSClassFromString("UIViewAnimationState")', "the class XCTest swizzles"),
            ("class_replaceMethod(\n                cls, startSel", "the start replaced"),
            ("class_replaceMethod(\n                cls, stopSel", "the stop replaced"),
            ("prevStart(state, startSel, anim)", "the replaced start still called"),
            ("prevStop(state, stopSel, anim, finished)", "the replaced stop still called"),
            ('NSClassFromString("XCTAnimationsIdleNotifier")', "XCTest's own notifier read"),
            ("blind = loaded && !open[at].xctest", "what XCTest saw start"),
            ('NSSelectorFromString("isAnimationInProgress")', "XCTest's own count read"),
            ("UIResponder.keyboardWillHideNotification", "the keyboard's timeline"),
            ('NSSelectorFromString("addAnimation:forKey:")', "the layer an animation is added to"),
            ("prevAdd(layer, addSel, anim, key)", "the replaced add still called"),
            ("KayaAnimationLedger.shared.added(layer, key as String?)", "the add recorded"),
            ("let place = placed.removeValue(forKey: ObjectIdentifier(key))",
             "the add's layer carried into its open start"),
            ('+ (gotNow[entry.id] ?? ""))', "the add's layer read beside each open start")):
        if want not in ledger:
            found.append(f"swift: KayaAnimationLedger lost {why} ({want.splitlines()[0]})")
    for key in ("XCTest's animation tracking ", "XCTest IN PROGRESS", "XCTest not in progress",
                "XCTest's notifier first seen at ", "for animations that started before it loaded",
                "XCTest unread: ", "refused: ", "open since",
                "main thread did not answer", "layers read at add: ",
                "that layer has been deallocated", "is alive in no window",
                "a window the scene does not list", "never seen added through"):
        if key not in ledger:
            found.append(f"swift: the reading no longer prints {key!r}, which "
                         f"flightrec_lane.ios_animation_reading keys on")
    leg = py_block(src[IOS], "run_swiftui_on")
    fail = leg[leg.find("if not ok:"):]
    if "system_capture(udid, name, log, launched_at,\n                       " \
            "flightrec_lane.ios_launch_pid(out, bundle_id))" not in fail:
        found.append("ios: a failed leg no longer keeps the system's account of the app")
    if 'with_suffix(".animations").write_text(\n            ' \
            "flightrec_lane.ios_animation_reading(out)" not in fail:
        found.append("ios: a failed leg no longer keeps the judged animation readings")
    cap = py_block(src[IOS], "system_capture")
    for want, why in (('process == "testmanagerd"', "testmanagerd"),
                      ('process == "KayaDrive-Runner"', "the xcui driver's runner"),
                      ('process == "runningboardd" AND eventMessage CONTAINS "{pid}"',
                       "runningboardd naming the pid"),
                      ('"--start", since, "--info"', "the Info lines from the launch"),
                      ("flightrec_lane.ios_system_log(body, pid)", "the judged summary"),
                      ('"Library/Logs/DiagnosticReports", pid, launched_at - 1)',
                       "the crash reports by pid")):
        if want not in cap:
            found.append(f"ios: system_capture lost {why}")
    if "KayaDrive-Runner" not in py_block(src[IOS], "stacks_pids"):
        found.append("ios: the runner system_capture names is not the one stacks samples")
    if '("system log", leg_log.with_suffix(".syslog"))' not in py_block(
            src[IOS], "secure_refusals"):
        found.append("ios: the system log is adopted without the secure scan reading it")
    rec = py_block(src[LANE_PY], "IosRecorder")
    for suffix in (".animations", ".syslog"):
        if f'log.with_suffix("{suffix}")' not in rec:
            found.append(f"ios: no section adopts the runner's {suffix} sidecar")
    return found


def ios_hang_record_checks(src, echo=False):
    scope = {"re": re, "pathlib": pathlib, "json": json, "datetime": datetime}
    for name in ("ios_animation_reading", "_log_time", "ios_provider_purges", "ios_system_log",
                 "ios_crash_reports"):
        body = py_block(src[LANE_PY], name)
        if not body:
            return [f"ios: missing hang reader {name}"]
        exec(compile(body, LANE_PY, "exec"), scope)
    at = src[LANE_PY].find("IOS_ANIMATION_HEAD = ")
    exec(compile(src[LANE_PY][at:src[LANE_PY].find("\n", at)], LANE_PY, "exec"), scope)
    head = "KAYA_HARNESS: XCTest's animation tracking "
    ledger = "kaya's ledger installed; 36 started, 35 stopped, 0 stopped with no start, "
    held = (f"{head}at the ceiling: XCTest IN PROGRESS (+[XCTAnimationsIdleNotifier "
            f"isAnimationInProgress], its count above 0); {ledger}1 open; main thread "
            f"answered in 0 ms, run loop mode kCFRunLoopDefaultMode\n"
            "  open since 11:07:50.974 (step 'press return'): CABasicAnimation opacity "
            "duration 0.5 repeat 3.4e38 of UIViewAnimationState 0x1; on CALayer of X key "
            "opacity\n  event 11:07:50.974 (step 'press return'): start\nKAYA_SELFTEST: x")
    reading = scope["ios_animation_reading"]
    said = {
        "held": reading(held),
        "uncounted": reading(held.replace("1 open;", "0 open;").replace(
            "  open since", "  event")),
        "idle": reading(f"{head}15 s into #2 type_b64: XCTest not in progress (its count not "
                        f"above 0); {ledger}0 open; main thread answered in 1 ms, run loop "
                        f"mode m\n"),
        "blind": reading(f"{head}15 s into #1 type_b64: XCTest not in progress (its count not "
                         f"above 0); XCTest's notifier first seen at 13:48:56.104 (step 'type "
                         f"\"milk\"') with 15 UIView animation(s) open; 15 stop(s) reached it "
                         f"for animations that started before it loaded, which XCTest logs as "
                         f"x; the first: started 13:48:55.761; {ledger}0 open; main thread "
                         f"answered in 8 ms, run loop mode m\n"),
        "unread": reading(f"{head}at the ceiling: XCTest unread: XCTAnimationsIdleNotifier "
                          f"is not loaded in this process; kaya's ledger refused: "
                          f"UIViewAnimationState is not in this process; 0 started, 0 "
                          f"stopped, 0 stopped with no start, 0 open; main thread did not "
                          f"answer within 2 s, so no open animation was placed\n"),
        "none": reading("KAYA_HARNESS: animations at the ceiling: 0 animation(s)\n")}
    t = "2026-10-12 15:2"
    rows = [f"{t}2:51.566 Df testmanagerd[9:1] [com.apple.dt.xctest:Default] Invalidating "
            f"<XCTTargetBootstrapSession: 0x1>(pid 53460)",
            f"{t}2:50.000 I  testmanagerd[9:1] [AXRuntimePID] Did suspend pid: 53460 on Display 0",
            f"{t}3:00.000 Df KayaDrive-Runner[8:1] Lost connection to the application (pid 53460)",
            f"{t}3:52.334 Df runningboardd[7:1] [com.apple.runningboard:process] Notifying "
            f"connection that process [app<dev.kaya.timecodego((null))>:53460] exited with "
            f"context <RBSProcessExitContext| voluntary>"]
    system = scope["ios_system_log"]
    said["let go"] = system("\n".join(rows), 53460)
    said["no exit"] = system("\n".join(rows[:3]), 53460)
    said["held on"] = system(rows[3], 53460)
    said["empty"] = system("Timestamp\n", 53460)
    said["no pid"] = system("\n".join(rows), None)
    with tempfile.TemporaryDirectory(prefix="kaya-crash-") as d:
        root = pathlib.Path(d)
        doc = {"pid": 53460, "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"},
               "termination": {"namespace": "SIGNAL", "indicator": "Segmentation fault: 11"}}
        (root / "timecodego-2026-10-12-152251.ips").write_text(
            '{"app_name":"timecodego"}\n' + json.dumps(doc), encoding="utf-8")
        (root / "other.ips").write_text('{}\n' + json.dumps({"pid": 1}), encoding="utf-8")
        (root / "torn.ips").write_text('{}\n{"pid": ', encoding="utf-8")
        crash = scope["ios_crash_reports"]
        said["crash"] = crash(root, 53460, 0)
        said["no crash"] = crash(root, 53461, 0)
        said["no dir"] = crash(root / "absent", 53460, 0)
    if echo:
        for k, v in said.items():
            print(f"check-flightrec: iOS hang record, {k}: {v.splitlines()[0]}")
    found = []
    for k, want in (
            ("held", "kaya's ledger holds 1 UIView animation(s) no stop has matched; the "
                     "oldest: open since 11:07:50.974 (step 'press return')"),
            ("uncounted", "XCTest's count is above 0 while kaya's ledger holds no open"),
            ("idle", "15 s into #2 type_b64: XCTest's count is not above 0"),
            ("blind", "15 s into #1 type_b64: XCTest's notifier loaded at 13:48:56.104 (step "
                      "'type \"milk\"') with 15 UIView animation(s) open, and 15 of their stops "
                      "reached it with no start"),
            ("unread", "XCTest's own count was not read: XCTAnimationsIdleNotifier is not "
                       "loaded in this process; kaya's ledger was never installed: "
                       "UIViewAnimationState is not in this process; the main thread did "
                       "not answer"),
            ("none", "the harness printed no animation reading"),
            ("let go", "BEFORE the app exited: XCTest let go of a live app"),
            ("let go", "last marked the running pid 53460 SUSPENDED at 15:22:50.000"),
            ("let go", "1 line(s) say lost connection or unable to monitor, the first"),
            ("let go", "exit at 15:23:52.334 with context <RBSProcessExitContext| voluntary>"),
            ("no exit", "no exit of it is in this slice: XCTest let go of a live app"),
            ("held on", "testmanagerd never ended its session with pid 53460"),
            ("empty", "holds no lines at all"),
            ("no pid", "no line here can be tied to the app"),
            ("crash", "names pid 53460: exception EXC_BAD_ACCESS SIGSEGV, termination "
                      "SIGNAL Segmentation fault: 11"),
            ("crash", "1 could not be read: torn.ips"),
            ("no crash", "no crash report written since the launch names pid 53461 (3 written"),
            ("no dir", "no crash report directory at")):
        if want not in said[k]:
            found.append(f"ios: the hang record's {k} reading lost {want!r}: {said[k][:300]!r}")
    return found


def retention_checks(src, echo=False):
    """A red bundle outlives the run it came from (docs/HACKING.md, "read a
    failed leg"): the real pruner, run over a synthetic home, dry and then
    for real."""
    import calendar
    scope = {"__name__": "flightrec_probe"}
    exec(compile(src[JOURNAL], JOURNAL, "exec"), scope)
    now = calendar.timegm((2026, 10, 13, 0, 0, 0))

    def name(days_ago, n):
        return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now - days_ago * 86400)) + f"-{n:06d}"

    found = []
    with tempfile.TemporaryDirectory() as tmp:
        base = pathlib.Path(tmp)
        scope["home"] = lambda: base
        runs = [name(100 - i * 0.01 if i == 0 else 30 - i * 0.5, i) for i in range(24)]
        reds = {runs[0]: "linux-gtk-e", runs[1]: "mac-a", runs[3]: "ios-b", runs[23]: "win-new"}
        for i, run in enumerate(runs):
            d = base / "runs" / run
            (d / "bundles").mkdir(parents=True)
            bundle = f"{d}/bundles/{reds[run]}" if run in reds else None
            (d / "journal.jsonl").write_text(
                json.dumps({"rec": "leg", "bundle": bundle}) + "\n", encoding="utf-8")
            if run in reds:
                (d / "bundles" / reds[run]).mkdir()
                (d / "bundles" / reds[run] / "leg-log.txt").write_bytes(b"r" * 3000)
        for run, leg in ((name(134, 90), "linux-old"), (name(42, 91), "win-c"),
                         (name(28, 92), "android-d")):
            (base / "red" / run / "bundles" / leg).mkdir(parents=True)
            (base / "red" / run / "bundles" / leg / "shot.png").write_bytes(b"p" * 3000)

        def tree():
            return sorted(str(p.relative_to(base)) for p in base.rglob("*"))

        before = tree()
        said = []
        scope["prune"](20, now=now, days=90, limit=10000, dry=True, every=True,
                       say=said.append)
        if tree() != before:
            found.append("retention: the dry run moved or removed something")
        plan = "\n".join(said)
        said = []
        scope["prune"](20, now=now, days=90, limit=10000, say=said.append)
        did = "\n".join(said)
        if echo:
            print("check-flightrec: retention plan (dry):\n  " + plan.replace("\n", "\n  "))
            print("check-flightrec: retention done:\n  " + did.replace("\n", "\n  "))
        left = sorted(d.name for d in (base / "runs").iterdir())
        if left != runs[4:]:
            found.append(f"retention: {len(left)} runs kept, wanted the newest 20 of 24")
        if not (base / "runs" / runs[23] / "bundles" / "win-new").is_dir():
            found.append("retention: a red bundle inside a kept run was moved or removed")
        red = sorted(str(p.relative_to(base / "red")) for p in (base / "red").glob("*/bundles/*"))
        want = sorted([f"{runs[1]}/bundles/mac-a", f"{runs[3]}/bundles/ios-b",
                       f"{name(28, 92)}/bundles/android-d"])
        for lost in sorted(set(want) - set(red)):
            found.append(f"retention: lost red bundle {lost}")
        for extra in sorted(set(red) - set(want)):
            why = ("older than 90 days" if "-e" in extra or "old" in extra
                   else "past the disk bound" if "win-c" in extra else "unexpected")
            found.append(f"retention: kept {extra}, {why}")
        if (base / "red" / name(134, 90)).exists():
            found.append("retention: an emptied red run directory was left behind")
        journal = base / "red" / runs[1] / "journal.jsonl"
        if not journal.is_file():
            found.append("retention: a moved red bundle lost its run's journal")
        elif f"/red/{runs[1]}/bundles/mac-a" not in journal.read_text(encoding="utf-8"):
            found.append("retention: the kept journal still points into the pruned run")
        for text, mode in ((plan, "dry run"), (did, "prune")):
            for leg in ("mac-a", "ios-b", "linux-gtk-e"):
                if not re.search(rf"move(?:d)? red bundle \S*/{leg} ", text):
                    found.append(f"retention: the {mode} did not print the move of {leg}")
            for leg, why in (("linux-old", "older than 90 days"),
                             ("linux-gtk-e", "older than 90 days"),
                             ("win-c", "past the 10000 bytes bound")):
                if not re.search(rf"remove(?:d)? red bundle \S*/{leg} \(.*{why}", text):
                    found.append(f"retention: the {mode} did not print removing {leg} ({why})")
            if len(re.findall(r"remove(?:d)? run ", text)) != 4:
                found.append(f"retention: the {mode} did not print each removed run")
            if not re.search(r"kept under \S+: 3, ", text):
                found.append(f"retention: the {mode} did not print what it kept")
        if plan.count("would keep red bundle") != 3:
            found.append("retention: the plan did not list each kept red bundle")
    return found


def census_leg_ceiling(src):
    """A LINUX LEG THAT OUTLIVES ITS CEILING PRINTS ITS STACKS, AND THE BUNDLE
    NAMES THEIR STATIC FRAMES (docs/traps.md, the toast leg that never
    started and the capture that wedged on a freed monitor): a leg hung
    before its harness started reached `timeout 180` with nothing said, and
    the stacks the harness did take printed the deciding frame as `?`."""
    found = []
    run_one = sh_block(src[LINUX], "run_one() {", "\n}\n")
    if "timeout 180" in run_one:
        found.append(f"{LINUX}: run_one still runs a leg under a bare `timeout 180`, which kills "
                     f"it with no stacks")
    wrapped = run_one.count("python3 /work/tools/linux/leg-ceiling.py 180")
    if wrapped < 4:
        found.append(f"{LINUX}: run_one runs {wrapped} of its 4 leg arms under {LEG_CEILING}")
    for script in (LEG_CEILING, STACK_NAMES):
        if f"python3 /work/{script} --self-test" not in src[LINUX]:
            found.append(f"{LINUX}: never runs {script}'s self-test")
    if '"eu-stack", "-m", "-b", "-p"' not in src[LEG_CEILING]:
        found.append(f"{LEG_CEILING}: its eu-stack carries no build ids (-b), so "
                     f"{STACK_NAMES} has no frame it can name")
    if 'ceiling_capture("thread stacks at the ceiling", "eu-stack", &["-m", "-b", "-p"' \
            not in src[HARNESS]:
        found.append(f"{HARNESS}: the ceiling's eu-stack carries no build ids (-b), so "
                     f"{STACK_NAMES} has no frame it can name")
    body = sh_block(src[LINUX], 'bundle="$(flightrec_bundle linux', "flightrec_finish")
    if f'python3 /work/{STACK_NAMES} "$LEGS_DIR/$name.log"' not in body:
        found.append(f"{LINUX}: the drain never runs {STACK_NAMES} over a red leg's log")
    core = sh_block(src[GTK_RS], "pub(crate) fn run_core(", "gtk4::Application::builder()")
    if "if let Err(e) = gtk4::init() {" not in core or "display_why_not(" not in core:
        found.append(f"{GTK_RS}: run_core no longer opens the display itself before the "
                     f"application and says what the display's socket answered — GTK's own "
                     f"`Failed to open display` exits 1 naming nothing (docs/traps.md, the x11 "
                     f"leg whose display would not open)")
    return found


def census_door_record(src):
    """THE LINUX RELAUNCH DOORS' RECORD (docs/traps.md, the plain door's
    lost Activate): a door leg that started its bus with dbus-launch
    threw the daemon's activation log away, and one that pushed its
    launcher itself kept no rc, output or Exec, so a missing act two named
    no place it stopped. Each door leg goes through tools/linux/
    door_record.py for all four, samples its watch while it polls, and
    act2-exec.sh writes its start and exit lines."""
    found = []
    for leg in DOOR_LEGS:
        text = src[leg]
        for call, why in (
                ("door_record.Bus(", "its bus daemon's activation log"),
                ("door_record.push(", "the launcher's rc and output"),
                ("door_record.exec_record(", "the Exec lines it can run"),
                ("door_record.Watch(", "the processes the bus started"),
                ("door_record.report(", "the record in the leg log")):
            if call not in text:
                found.append(f"{leg}: never calls {call.rstrip('(')}, so a "
                             f"red second act carries no {why}")
        if '"dbus-launch"' in text:
            found.append(f"{leg}: starts a bus through dbus-launch, which "
                         f"points the daemon's log at /dev/null")
        if "watch.sample()" not in py_block(text, "poll_verdict"):
            found.append(f"{leg}: poll_verdict never samples the watch, so a "
                         f"process that started and died is never seen")
    shell = src[ACT2_EXEC]
    prefix = re.search(r'^EXEC_LOG_PREFIX = "([^"]+)"', src[DOOR_RECORD], re.M)
    start = shell.find('started at')
    run = shell.find('\n"$@" ')
    if not prefix or f'echo "{prefix.group(1)} pid $$ started' not in shell:
        found.append(f"{ACT2_EXEC}: writes no start line under "
                     f"{DOOR_RECORD}'s EXEC_LOG_PREFIX, so a door that ran "
                     f"nothing reads like one whose process wrote nothing")
    elif run < 0 or start > run:
        found.append(f"{ACT2_EXEC}: the start line is not written before "
                     f"the launcher runs")
    if re.search(r'^exec "\$@"', shell, re.M) \
            or "exited $kaya_rc" not in shell:
        found.append(f"{ACT2_EXEC}: execs or drops the launcher's exit "
                     f"status, so a process that died leaves no status")
    if "LAUNCH_ENTRY" not in src[DOOR_LEGS[0]] \
            or re.search(r'"gio",\s*"launch"', src[DOOR_LEGS[0]]):
        found.append(f"{DOOR_LEGS[0]}: its plain door is not "
                     f"tools/linux/launch-entry.py — `gio launch` exits "
                     f"before its Activate call is written and loses it "
                     f"under load")
    if "door_record.py --self-test" not in src[LINUX]:
        found.append(f"{LINUX}: never runs {DOOR_RECORD}'s self-test, the "
                     f"one place its record is read back off real doors")
    return found


def census_pass_path(src):
    """A PASSING LEG COSTS THE OBSERVER NOTHING (docs/deferred.md, the
    flight recorder's first matrix: 304ms of ssh and python per leg took
    the windows lane 110s past its ceiling). Both per-leg record paths are
    one append, never a spawn."""
    found = []
    m = re.search(r"^flightrec_leg\(\) \{.*?^\}", src[LANE_SH], re.S | re.M)
    if not m:
        return [f"{LANE_SH}: flightrec_leg could not be read — the anchor moved"]
    for line in m.group(0).splitlines():
        if re.match(r"^\s*#", line):
            continue
        for banned in ("python3", "run_ssh", "scp", "mkdir"):
            if re.search(rf"\b{banned}\b", line):
                found.append(f"{LANE_SH}: flightrec_leg calls '{banned}' — it "
                             f"runs on every leg and must not spawn")
    leg = None
    for node in ast.walk(ast.parse(src[LANE_PY])):
        if isinstance(node, ast.ClassDef) and node.name == "LaneRecorder":
            for item in node.body:
                if isinstance(item, ast.FunctionDef) and item.name == "leg":
                    leg = ast.get_source_segment(src[LANE_PY], item)
    if leg is None:
        return found + [f"{LANE_PY}: LaneRecorder.leg could not be read"]
    if "subprocess" in leg or "Popen" in leg:
        found.append(f"{LANE_PY}: LaneRecorder.leg spawns — it runs on every "
                     f"leg of four lanes and must stay one O_APPEND write")
    return found


# THE MAC RECORDER, DRIVEN. The censuses above read the collect; this runs
# it: the real MacRecorder (or a doctored copy) through watched_leg and
# mac_leg, the one wiring validate-mac's pool and run-leg share, against a
# guest that lives five seconds and fails, one that passes, and one whose
# journal cannot be opened. The desktop is never photographed: the drive
# reads the host as busy.
MAC_DRIVER = '''import importlib.util
import os
import pathlib
import sys

lane_mod, root, leg_name, tmp = sys.argv[1:5]
leg_argv = sys.argv[5:]
sys.path.insert(0, str(pathlib.Path(root) / "tools" / "lib"))
from lanes import mac as mac_lane
mac_lane.hid_idle_seconds = lambda: (0, None)
spec = importlib.util.spec_from_file_location("kaya_flightrec_shadow", lane_mod)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
fr = mod.MacRecorder(pathlib.Path(root))
tmp = pathlib.Path(tmp)
scratch = tmp / "scratch"
log = tmp / "leg.log"
with open(log, "w", encoding="utf-8") as lf:
    rc = fr.watched_leg(scratch, leg_argv, dict(os.environ), lf)
fr.mac_leg(leg_name, "PASS" if rc == 0 else "FAIL", 0, log, scratch)
fr.flush()
print(f"driver: status={0 if rc == 0 else 1}")
'''
def absent_tool_checks(src):
    """A capture tool this host does not have leaves a .skip naming it,
    never a silently absent section and never a raise out of the collect."""
    import importlib.util
    shadow = gate.scratch() / f"section-{len(list(gate.scratch().glob('section-*')))}"
    shadow.mkdir()
    (shadow / "flightrec_lane.py").write_text(src[LANE_PY], encoding="utf-8")
    spec = importlib.util.spec_from_file_location("kaya_section_shadow",
                                                  shadow / "flightrec_lane.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    rec = object.__new__(mod.LaneRecorder)
    bundle = shadow / "bundle"
    bundle.mkdir()
    try:
        rec.section(bundle, "windows", ["no-such-tool-on-any-host"])
    except OSError as error:
        return [f"{LANE_PY}: an absent capture tool raised out of section(): {error}"]
    marker = bundle / "windows.skip"
    said = marker.read_text(encoding="utf-8") if marker.is_file() else ""
    manifest = (bundle / "MANIFEST").read_text(encoding="utf-8") \
        if (bundle / "MANIFEST").is_file() else ""
    if "no-such-tool-on-any-host" not in said or "windows skip" not in manifest:
        return [f"{LANE_PY}: an absent capture tool left no skip naming it "
                f"({said.strip()!r}, manifest {manifest.strip()!r})"]
    return []


LIVE_FAIL = ("python3", "-c", "import time, sys; time.sleep(5); sys.exit(1)")
UNREACHED = "never reached section"


def mac_drive_start(lane_text, tag, kind):
    """Start one drive in the background; mac_drive_checks reads it."""
    tmp = gate.scratch() / f"drive-{tag}"
    tmp.mkdir(parents=True)
    (tmp / "flightrec_lane.py").write_text(lane_text, encoding="utf-8")
    (tmp / "driver.py").write_text(MAC_DRIVER, encoding="utf-8")
    home = tmp / "journal"
    if kind == "nojournal":
        (tmp / "blocker").write_text("", encoding="utf-8")
        home = tmp / "blocker" / "journal"
    leg, argv = (("alwayspass", ("/usr/bin/true",)) if kind == "pass"
                 else ("alwaysfail", LIVE_FAIL))
    root = pathlib.Path(__file__).resolve().parent.parent
    proc = subprocess.Popen(
        [sys.executable, str(tmp / "driver.py"), str(tmp / "flightrec_lane.py"),
         str(root), leg, str(tmp), *argv],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        encoding="utf-8", errors="replace",
        env=dict(os.environ, KAYA_FLIGHTREC_DIR=str(home)))
    atexit.register(proc.kill)
    return {"proc": proc, "tmp": tmp, "home": home, "kind": kind, "leg": leg}


def mac_drive_checks(drive):
    if "log" not in drive:
        out, _ = drive["proc"].communicate(timeout=300)
        drive["log"], drive["rc"] = out, drive["proc"].returncode
    log, rc, home, kind = drive["log"], drive["rc"], drive["home"], drive["kind"]
    tail = " | ".join(log.strip().splitlines()[-4:])
    if kind == "nojournal":
        found = []
        if rc != 0 or "driver: status=1" not in log:
            found.append(f"mac drive: an unwritable journal cost the leg "
                         f"(driver exit {rc}): {tail}")
        misses = log.count("flightrec: the journal could not be opened")
        if misses != 1:
            found.append(f"mac drive: the journal miss was printed {misses} "
                         f"time(s), want exactly 1")
        return found
    if rc != 0:
        return [f"mac drive ({kind}): the driver exited {rc}: {tail}"]
    journals = sorted(home.rglob("journal.jsonl"))
    journal = journals[0].read_text(encoding="utf-8") if journals else ""
    verdict = "PASS" if kind == "pass" else "FAIL"
    found = []
    if f'"leg":"{drive["leg"]}"' not in journal or f'"verdict":"{verdict}"' not in journal:
        found.append(f"mac drive ({kind}): the journal has no {verdict} record "
                     f"for the leg")
    if kind == "pass":
        if "driver: status=0" not in log:
            found.append(f"mac drive: the passing leg did not pass: {tail}")
        if [p for p in home.rglob("mac-*") if p.is_dir()]:
            found.append("mac drive: a PASSING leg scaffolded a bundle — the "
                         "pass path must create nothing")
        if any(p.stat().st_size for p in home.rglob("spool.tsv")):
            found.append("mac drive: the spool survived the flush, so a second "
                         "flush would write every record twice")
        return found
    manifests = sorted(home.rglob("MANIFEST"))
    if "driver: status=1" not in log or not manifests:
        return found + [f"mac drive: no bundle was written for a failing leg: "
                        f"{tail}"]
    bundle = manifests[0].parent
    sampler = bundle / "sampler.txt"
    if not sampler.is_file() or not re.search(
            r"guest_pid=\d+", sampler.read_text(encoding="utf-8")):
        found.append("mac drive: the sampler never resolved the guest's pid "
                     "while it lived, so a hang's shot and sample would skip")
    listed = {line.split()[0] for line in
              manifests[0].read_text(encoding="utf-8").splitlines() if line.split()}
    missing = [s for s in declared(REAL)["mac"] if s not in listed]
    if missing:
        found.append(f"mac drive: the bundle is missing sections {missing}")
    for skip in sorted(bundle.glob("*.skip")):
        said = skip.read_text(encoding="utf-8", errors="replace")
        if not said.strip() or "named no reason" in said:
            found.append(f"mac drive: {skip.name} carries no measured reason: "
                         f"{said.strip()!r}")
        if UNREACHED in said:
            found.append(f"mac drive: the collect never reached section "
                         f"{skip.stem}")
            if f"{skip.stem} skip" not in log or UNREACHED not in log:
                found.append(f"mac drive: the report did not print the "
                             f"unreached {skip.stem} and its sentence")
    if not re.search(r"flightrec: bundle .* sections", log):
        found.append("mac drive: the bundle's counts were never printed")
    return found


def census_lane_health(src):
    found = []
    for rel, (start, end, verdict) in HEALTH_CALLS.items():
        text = src[rel]
        counts = [text.count(start), text.count(end)]
        if counts != [1, 1]:
            found.append(f"{rel}: the lane-health reading at start/end is called "
                         f"{counts[0]}/{counts[1]} times, wanted once each (`{start}`, `{end}`)")
            continue
        at = [text.index(start), text.index(end), text.find(verdict)]
        if not (at[0] < at[1] < at[2]):
            found.append(f"{rel}: the lane-health end reading does not come after the "
                         f"start and before the verdict `{verdict}`")
    reading = py_block(src[WIN], "lane_health_reading")
    if 'lane_health.windows_report("windows", when,' not in reading:
        found.append(f"{WIN}: lane_health_reading no longer reads the guest")
    win = src[WIN]
    calls = win.count("\nnative_images()\n")
    order = [win.find('\ntiming("vm-ready")\n'), win.find("\nnative_images()\n"),
             win.find('\nlane_health_reading("start")\n')]
    if calls != 1:
        found.append(f"{WIN}: the native-image phase is called {calls} times at the top "
                     f"level, wanted once")
    elif not (0 <= order[0] < order[1] < order[2]):
        found.append(f"{WIN}: the native-image phase does not run after vm-ready and "
                     f"before the start reading and every leg")
    phase = py_block(win, "native_images")
    for needle, what in (("lane_health.ngen_plan(", "reads the queues"),
                         ("lane_health.ngen_drain_command(", "drains a pending queue"),
                         ("lane_health.ngen_verdict(", "reads the queues after the drain")):
        if needle not in phase:
            found.append(f"{WIN}: native_images no longer {what} (`{needle}`)")
    stops = phase.count("die(refusal)")
    if stops != 2:
        found.append(f"{WIN}: native_images does not stop the lane on both refusals "
                     f"(die(refusal) {stops}/2)")
    wait = src[VALIDATE_ALL]
    waiter = wait[wait.find("    def _wait("):wait.find("    waiter = threading.Thread")]
    if "lane_health.host_line()" not in waiter:
        found.append(f"{VALIDATE_ALL}: a lane's exit no longer prints the host's reading")
    net, cmp = wait.find("net = secs - waited - idle"), wait.find("lane_health.compare_runs(")
    if net < 0 or cmp < net:
        found.append(f"{VALIDATE_ALL}: no leg-time comparison after the lane's net seconds")
    elif "lane_health.health_lines(log_text)" not in wait[cmp:cmp + 600]:
        found.append(f"{VALIDATE_ALL}: a leg-time shift no longer reprints the lane's readings")
    return found


def census_mac_apps(src):
    """docs/traps.md, the Preview a Go guest's checkin relaunched: the mac
    lane reads the host's applications at its start, after every leg and at
    its end, and its own apps are excluded only by names it still launches."""
    found = []
    runner = src[MAC_RUNNER]
    pooled = py_block(runner, "_run_leg")
    if not re.search(r"entry = lane_health\.MAC_APPS\.leg_began\(name\)\n +try:\n"
                     r" +_leg_body\(name, argv, env, scene\)\n +finally:\n"
                     r" +lane_health\.MAC_APPS\.leg_ended\(entry\)\n", pooled):
        found.append(f"{MAC_RUNNER}: _run_leg no longer reads the apps at a pooled leg's "
                     f"start and end (leg_began, then leg_ended in a finally)")
    serial = py_block(runner, "queue_leg")
    serial = serial[serial.find("if JOBS == 1"):]
    began = serial.find("entry = lane_health.MAC_APPS.leg_began(name)")
    ran = serial.find("rc = FR.watched_leg(")
    ended = serial.find("lane_health.MAC_APPS.leg_ended(entry)")
    if not (0 <= began < ran < ended):
        found.append(f"{MAC_RUNNER}: the serial path no longer reads the apps around its leg")
    health = src[LANE_HEALTH]
    report = py_block(health, "mac_report")
    for needle in ("MAC_APPS.start()", "MAC_APPS.end()"):
        if needle not in report:
            found.append(f"{LANE_HEALTH}: mac_report no longer takes the app reading "
                         f"(`{needle}`)")
    if "self.sample(" not in py_block(health, "leg_ended"):
        found.append(f"{LANE_HEALTH}: a leg's end no longer reads the apps")
    sample = py_block(health, "sample")
    adopt = sample.find("self.adoption(app, where)")
    typed = sample.find('if app["type"] not in APP_TYPES:')
    if not 0 <= adopt < typed:
        found.append(f"{LANE_HEALTH}: sample no longer reads every record for an adopted "
                     f"identity before it filters to GUI types")
    tail = runner[runner.find('lane_health.mac_report("mac", "end")'):]
    tail = tail[:tail.find('exclusive.summary("mac")')]
    if not re.search(r"\nif lane_health\.MAC_APPS\.refusals\(\):\n(?: .*\n)*? +status = 1\n$",
                     tail):
        found.append(f"{MAC_RUNNER}: an IDENTITY ADOPTED reading no longer fails the lane "
                     f"(`if lane_health.MAC_APPS.refusals():` setting status = 1 after the "
                     f"end reading)")
    scope = {"__name__": "lane_health_shadow"}
    exec(compile(health, LANE_HEALTH, "exec"), scope)
    named = scope["LANE_APPS"]
    gate.counted("the mac lane's own apps excluded by name", list(named), floor=5)
    for label, _how, _pattern, rel, needle in named:
        if rel not in src:
            found.append(f"{LANE_HEALTH}: the exclusion `{label}` names {rel}, which this "
                         f"gate does not read")
        elif needle not in src[rel]:
            found.append(f"{LANE_HEALTH}: the exclusion `{label}` is no longer named by the "
                         f"lane: {rel} lacks `{needle}`")
    agents = scope["HOST_AGENTS"]
    gate.counted("host agents excluded by name", list(agents), floor=1)
    for label, _bundle, exe, why in agents:
        if not pathlib.Path(exe).is_file():
            found.append(f"{LANE_HEALTH}: the host agent `{label}` names {exe}, which this "
                         f"host no longer has")
        if not why:
            found.append(f"{LANE_HEALTH}: the host agent `{label}` is excluded with no reason")
    return found


# docs/deferred.md, the iOS varied-python entry: the synthesized tier's park
# writes its own account into the verb trace a red bundle carries.
PARK_LINKS = (
    ("the aim", "scroll(_ node: KayaNode, toRow index: Int)", 'note(node, "scroll_to_row r'),
    ("each pass of a park", "private func report(_ node: KayaNode)",
     'if anchorRow != nil { note(node, "") }'),
    ("the landing", "private func repark(", 'note(node, "landed")'),
    ("the cancel", "private func repark(", '"park cancelled: the offset moved from "'),
    ("the re-park", "private func repark(", 'note(node, "re-park: measured first'),
    ("the trace write", "private func note(_ node: KayaNode, _ event: String)",
     'KayaVTrace.attempt('),
    ("the rows", "func describe(_ node: KayaNode) -> String",
     'rows.append("r\\(index) \\(drawn)/\\(n(KayaHost.rowExtent(node.id, index)))")'),
    ("the core's correction", "func describe(_ node: KayaNode) -> String", "anchor_shift"),
)


def census_ios_park(src):
    text = src[SWIFTUI]
    start = text.find("@Observable final class KayaSynthesizedWindow {")
    end = text.find("\nprivate struct KayaScrollBox", start)
    if start < 0 or end < 0:
        return ["SwiftUI: cannot locate KayaSynthesizedWindow"]
    body = text[start:end]
    found = []
    for what, opener, needle in PARK_LINKS:
        at = body.find(opener)
        if at < 0:
            found.append(f"SwiftUI: KayaSynthesizedWindow lost `{opener}`")
            continue
        close = body.find("\n    }\n", at)
        if needle not in body[at:close]:
            found.append(f"SwiftUI: the park's account lost {what} (`{needle}`)")
    if "if read != want { window.noteRead(node, read) }" not in text:
        found.append("SwiftUI: expect_window's refused reading no longer records the window")
    return found


def lane_health_checks(src, echo=False):
    scope = {"__name__": "lane_health_shadow"}
    exec(compile(src[LANE_HEALTH], LANE_HEALTH, "exec"), scope)
    found = scope["selftest"](echo=echo)
    script = scope["WINDOWS_SCRIPT"]
    for needle, what in (("LastBootUpTime", "boot time"), ("Start-Sleep", "CPU sample"),
                         ("Get-MpComputerStatus", "Defender scan state"),
                         ("Get-MpPreference", "Defender exclusions"),
                         ("RUNTIMES", "the lane's runtimes"),
                         ("StatusPending", "pending native images"),
                         ("TotalProcessorTime", "PowerShell start's CPU")):
        if needle not in script:
            found.append(f"{LANE_HEALTH}: the windows reading lost its {what} (`{needle}`)")
    tree = ast.parse(src[WIN])
    wanted = {"NODE_VERSION", "NODE_DIR", "WIN_RUNTIMES"}
    body = [n for n in tree.body if isinstance(n, ast.Assign) and any(
        isinstance(x, ast.Name) and x.id in wanted for x in n.targets)]
    run = {}
    exec(compile(ast.Module(body=body, type_ignores=[]), WIN, "exec"), run)
    size = len(scope["windows_command"](run.get("WIN_RUNTIMES", ())))
    if "WIN_RUNTIMES" not in run or size >= 8000:
        found.append(f"{LANE_HEALTH}: the windows reading's command is {size} characters "
                     f"(cmd.exe refuses past 8191) or names no runtimes")
    if echo:
        print(f"check-flightrec: lane health: {len(scope['drive']())} branches driven, "
              f"windows command {size} characters")
    return found


# ---------------------------------------------------------------- run it

REAL = sources()

# The drives take seconds each, so all of them start here and run beside
# the censuses; each doctored copy's substitution count is printed now.
DRIVES = {}
if sys.platform == "darwin":
    DRIVES["fail"] = mac_drive_start(REAL[LANE_PY], "fail", "fail")
    DRIVES["pass"] = mac_drive_start(REAL[LANE_PY], "pass", "pass")
    DRIVES["nojournal"] = mac_drive_start(REAL[LANE_PY], "nojournal", "nojournal")
    for tag, kind, label, pattern, repl, flags in (
            ("MD1", "fail", "MD1 the guest pid walked from descendants only",
             r'anchors = \[str\(root_pid\)\] if self\._comm\(root_pid\) == "timeout" '
             r'\\\n +else \[\]', "anchors = []", 0),
            ("MD2", "fail", "MD2 the windowserver section no longer written",
             r'self\._text_section\(bundle, "windowserver",\s*'
             r'"\\n"\.join\(wanted\) \+ "\\n"\)', "pass", 0),
            ("MD3", "fail", "MD3 the sample section skipped with no sentence",
             r'self\.adopt\(bundle, "sample", scratch / "sample\.txt",.*?duration\."\)',
             'self.skip(bundle, "sample", "")', re.S),
            ("MD4", "pass", "MD4 a passing mac leg collects a bundle",
             r'if verdict != "PASS":\n(\s+bundle = self\.bundle\(leg\)\n'
             r'\s+fail = self\.fail_sentence\(log\) if log)', r"if True:\n\1", 0),
            ("MD5", "nojournal", "MD5 an unopenable journal ends the runner",
             r'(print\("flightrec: the journal could not be opened.*?'
             r'file=sys\.stderr\)\n)(\s+)return\n', r"\1\2raise SystemExit(1)\n",
             re.S)):
        DRIVES[tag] = (label, mac_drive_start(
            gate.doctor(label, REAL[LANE_PY], pattern, repl, flags=flags),
            tag, kind))
else:
    print("check-flightrec: the mac recorder drive needs a mac; not run here")

CENSUSES = (("sections", census_sections), ("skip writers", census_skips),
            ("finish", census_finish), ("capture point", census_when),
            ("windows verb trace", census_vtrace),
            ("windows toast files", census_toast_files),
            ("windows collect freshness", census_collect_fresh),
            ("guest clock", census_guest_clock),
            ("linux focus ring", census_focus_ring),
            ("hand run", census_hand_run), ("iOS SDK stamp", census_ios_stamp),
            ("no frontmost shot", census_frontmost),
            ("Android history", census_android_history),
            ("Android app shot", census_android_app_shot),
            ("mac app shot", census_mac_app_shot),
            ("iOS app shot", census_ios_app_shot),
            ("iOS notification side", census_ios_notifications),
            ("linux ceiling stacks", census_wedge_capture),
            ("linux door record", census_door_record),
            ("linux leg ceiling", census_leg_ceiling),
            ("iOS ceiling stacks", census_ios_stacks),
            ("iOS app log", census_ios_app_log),
            ("iOS hang record", census_ios_hang_record),
            ("mac host apps", census_mac_apps),
            ("GTK media ring", census_gtk_media_ring))
TABLE = declared(REAL)
gate.counted("lanes declaring a bundle shape", list(TABLE), floor=5)
gate.counted("sections declared across the five lanes",
             [s for names in TABLE.values() for s in names], floor=25)
for label, fn in CENSUSES:
    for line in fn(REAL):
        gate.finding(line, at=label)
for line in android_report_checks(REAL, echo=True):
    gate.finding(line, at="Android report renderers")
if sys.platform == "darwin":
    for line in winlist_refuses_nonsense():
        gate.finding(line, at="no frontmost shot")
for line in desktop_shot_checks(REAL):
    gate.finding(line, at="desktop shot on an idle host")
for line in mac_power_checks(REAL, echo=True):
    gate.finding(line, at="Mac power history")
for line in mac_unified_log_checks(REAL, echo=True):
    gate.finding(line, at="Mac unified log")
for line in mac_timeout_checks(REAL, echo=True):
    gate.finding(line, at="Mac timeout kill")
for line in ios_recording_recovery(REAL):
    gate.finding(line, at="iOS recording recovery")
for line in ios_notification_checks(REAL, echo=True):
    gate.finding(line, at="iOS notification store")
for line in ios_app_log_checks(REAL, echo=True):
    gate.finding(line, at="iOS app log")
for line in ios_hang_record_checks(REAL, echo=True):
    gate.finding(line, at="iOS hang record")
for line in retention_checks(REAL, echo=True):
    gate.finding(line, at="red bundle retention")
for line in census_pass_path(REAL):
    gate.finding(line, at="pass path")
for line in census_lane_health(REAL):
    gate.finding(line, at="lane health")
for line in census_ios_park(REAL):
    gate.finding(line, at="iOS park account")
for line in lane_health_checks(REAL, echo=True):
    gate.finding(line, at="lane health drive")
for line in absent_tool_checks(REAL):
    gate.finding(line, at="absent capture tool")
for kind in ("fail", "pass", "nojournal"):
    if kind in DRIVES:
        for line in mac_drive_checks(DRIVES[kind]):
            gate.finding(line, at="mac recorder drive")
        print(f"check-flightrec: mac recorder drive ({kind}) read back")


def doctored(rel, pattern, repl, label, *, flags=re.M, want=1):
    src = dict(REAL)
    src[rel] = gate.doctor(label, REAL[rel], pattern, repl, flags=flags,
                           want=want)
    return src


# The frontmost-shot refusals, each removed from a copy.
nf1 = doctored(LANE_PY,
               r"^        if not isinstance\(pid, int\) or isinstance\(pid, bool\) "
               r"or pid <= 0:\n            return False\n",
               "", "NF1 removed shot_pid's pid refusal")
gate.negative("NF1 shot_pid taking a missing pid",
              lambda: census_frontmost(nf1), want="does not refuse a pid")
nf2 = doctored(WINLIST, r'is not a pid"\)', 'is odd")',
               "NF2 removed the window list's refusal sentence")
gate.negative("NF2 the window list reading nonsense as no filter",
              lambda: census_frontmost(nf2), want="does not refuse an argument")

# The android app's own picture, each link cut from a copy.
na1 = doctored(COMPOSE, r"^ *mountedActivity\?\.let \{ KayaFailShot\.take\(it, "
                        r"\"the first failed step, \$line\"\) \}\n",
               "", "NA1 cut the step's picture")
gate.negative("NA1 no picture at a step's final failure",
              lambda: census_android_app_shot(na1), want="takes no picture at a step")
na2 = doctored(COMPOSE, r"^( *)(mountedActivity\?\.let \{ "
                        r"KayaFailShot\.take\(it, \"the failed verdict\"\) \}\n)"
                        r"((?:.*\n){1,6}?)( *Log\.e\(\"kaya\", line\)\n)",
               r"\3\4\1\2", "NA2 moved the verdict's picture after the publish")
gate.negative("NA2 the verdict published before the picture",
              lambda: census_android_app_shot(na2), want="published before the app's picture")
na3 = doctored(ANDROID, r"^ *app_shot\(serial, package, name, log\)\n", "",
               "NA3 cut the pull of the app's picture")
gate.negative("NA3 a red leg's picture never pulled",
              lambda: census_android_app_shot(na3), want="does not pull the app's own picture")
na4 = doctored(ANDROID, r'\.with_suffix\("\.desktop-shot\.png"\)', '.with_suffix(".shot.png")',
               "NA4 the screencap filed as the leg's shot, as shipped")
gate.negative("NA4 the launcher's picture as the leg's shot",
              lambda: census_android_app_shot(na4), want="filed as the leg's `shot`")

na5 = doctored(COMPOSE, r"^ *val sheets = sheetLayers\(activity, bitmap\)\n", "",
               "NA5 cut the sheets from the app's picture")
gate.negative("NA5 the app's picture without its sheets",
              lambda: census_android_app_shot(na5), want="draws each sheet's own window")
na6 = doctored(ANDROID,
               r'^ *run_as\(serial, package, "rm", "-f", '
               r'f"files/verb-trace-\{name\}\.txt"\)\n', "",
               "NA6 cut the pre-launch verb trace delete, as shipped")
gate.negative("NA6 a red bundle carrying earlier reds' dumps",
              lambda: census_android_app_shot(na6),
              want="delete the leg's verb trace before its launch")

# The mac guest's own picture, each link cut from a copy.
nm1 = doctored(SWIFTUI, r'^ *KayaFailShot\.take\("the first failed step, \\\(line\)"\)\n',
               "", "NM1 cut the mac step's picture")
gate.negative("NM1 no mac picture at a step's final failure",
              lambda: census_mac_app_shot(nm1), want="mac: the harness takes no picture")
nm2 = doctored(SWIFTUI, r'^ *KayaFailShot\.take\("the failed verdict"\)\n', "",
               "NM2 cut the mac verdict's picture")
gate.negative("NM2 the mac verdict published with no picture",
              lambda: census_mac_app_shot(nm2), want="published before the guest's picture")
nm3 = doctored(LANE_PY, r'^ *env\["KAYA_FAIL_SHOT"\] = str\(scratch / "fail-shot\.png"\)\n',
               "", "NM3 cut the leg's KAYA_FAIL_SHOT")
gate.negative("NM3 a mac leg run with no KAYA_FAIL_SHOT",
              lambda: census_mac_app_shot(nm3), want="no longer names KAYA_FAIL_SHOT")
nm4 = doctored(LANE_PY, r'^ *shutil\.copy2\(fail, bundle / "shot\.png"\)\n', "",
               "NM4 cut the adoption of the guest's picture")
gate.negative("NM4 the guest's picture never adopted",
              lambda: census_mac_app_shot(nm4), want="does not adopt the guest's own picture")

# The iOS app's own picture, each link cut from a copy.
np1 = doctored(SWIFTUI, r'^( *)(KayaFailShot\.take\("the first failed step, \\\(line\)"\)\n)',
               r"\1#if os(macOS)\n\1\2\1#endif\n",
               "NP1 fenced the step's picture to macOS, as shipped")
gate.negative("NP1 no iOS picture at a step's final failure",
              lambda: census_ios_app_shot(np1), want="the step's fail shot is not taken on iOS")
np2 = doctored(SWIFTUI, r'^( *)(KayaFailShot\.take\("the failed verdict"\)\n)',
               r"\1#if os(macOS)\n\1\2\1#endif\n", "NP2 fenced the verdict's picture to macOS")
gate.negative("NP2 no iOS picture at the failed verdict",
              lambda: census_ios_app_shot(np2), want="the verdict's fail shot is not taken on iOS")
np3 = doctored(SWIFTUI, r"window\.drawHierarchy\(in: window\.frame", "_ = (window.frame",
               "NP3 cut the iOS window drawing")
gate.negative("NP3 an iOS fail shot that draws nothing",
              lambda: census_ios_app_shot(np3), want="no longer draws the app's windows")
np4 = doctored(IOS, r'^ *env\["SIMCTL_CHILD_KAYA_FAIL_SHOT"\] = f"fail-shot-\{name\}\.png"\n', "",
               "NP4 cut the leg's KAYA_FAIL_SHOT")
gate.negative("NP4 an iOS leg run with no KAYA_FAIL_SHOT",
              lambda: census_ios_app_shot(np4), want="no longer names KAYA_FAIL_SHOT")
np5 = doctored(IOS, r'^ *\(f"fail-shot-\{name\}\.png", "\.shot\.png"\),\n', "",
               "NP5 cut the pull of the app's picture")
gate.negative("NP5 an iOS picture never pulled",
              lambda: census_ios_app_shot(np5), want="does not pull the app's own picture")
np6 = doctored(IOS, r'\.with_suffix\("\.desktop-shot\.png"\)\n    got = run',
               '.with_suffix(".shot.png")\n    got = run',
               "NP6 the simulator screenshot filed as the leg's shot, as shipped")
gate.negative("NP6 SpringBoard's picture as the leg's shot",
              lambda: census_ios_app_shot(np6), want="device_capture files the device's screen")
np7 = doctored(IOS, r'^ *for stale in \(f"fail-shot-\{name\}\.png", '
                    r'f"fail-shot-\{name\}\.png\.when"\):\n.*\n', "",
               "NP7 cut the pre-launch delete of the last fail shot")
gate.negative("NP7 a red iOS leg adopting an earlier leg's picture",
              lambda: census_ios_app_shot(np7), want="does not delete the leg's last fail shot")

# The desktop shot's two idle refusals, each cut from a copy.
nd1 = doctored(LANE_PY,
               r"^        if idle < mac_lane\.DESKTOP_SHOT_IDLE_S:\n.*?\n(?=        if )",
               "", "ND1 cut shot_desktop's in-use refusal", flags=re.M | re.S)
gate.negative("ND1 a desktop shot of an in-use host",
              lambda: desktop_shot_checks(nd1), want="HIDIdleTime 5 photographed")
nd2 = doctored(LANE_PY, r"^        if idle is None:\n.*?\n(?=        if )",
               "", "ND2 cut shot_desktop's unreadable-clock refusal",
               flags=re.M | re.S)
gate.negative("ND2 a desktop shot when the idle clock is unreadable",
              lambda: desktop_shot_checks(nd2), want="HIDIdleTime None")
ni1 = doctored(LANE_PY, r'^            dest\.with_suffix\("\.when"\)\.write_text\(\n'
                        r'(?:.*\n){3}.*encoding="utf-8"\)\n',
               "", "NI1 cut the desktop shot's idle sentence")
gate.negative("NI1 a desktop shot that does not say what idle reading admitted it",
              lambda: desktop_shot_checks(ni1), want="wrote no sentence naming that reading")

# N1: a section the collect stops writing.
n1 = doctored(LANE_PY, r'self\.mark\(bundle, "unified-log",',
              'self.mark(bundle, "unified-nope",',
              "N1 renamed the mac unified-log section away")
gate.negative("N1 a mac section the collect stopped writing",
              lambda: census_sections(n1), want="`unified-log` is declared")

# N2: the same, on the lane whose runner is shell.
n2 = doctored(LINUX, r'flightrec_section "\$bundle" xvfb ""',
              'flightrec_section "$bundle" xvfbnope ""',
              "N2 renamed the linux xvfb section away")
gate.negative("N2 a linux section the collect stopped writing",
              lambda: census_sections(n2), want="`xvfb` is declared")

# N3: a lane that declares no picture at all — the state every lane but
# the mac and windows was in before this pass.
n3 = doctored(LANE_PY, r'"ios": \("leg-log", "verb-trace", "shot", ',
              '"ios": ("leg-log", "verb-trace", ',
              "N3 dropped the iOS shot from the declaration")
gate.negative("N3 a lane declaring no picture",
              lambda: census_sections(n3), want="declares no `shot` section")

# N4: a skip writer's sentence blanked, in each half.
n4 = doctored(LANE_PY, r'self\.skip\(bundle, "desktop-shot",\n\s+"flightrec: '
                       r'the window list would not build, so "\n\s+"this '
                       r'bundle has no image of any kind — " \+ why_not\)',
              'self.skip(bundle, "desktop-shot", "")',
              "N4 blanked a python skip sentence")
gate.negative("N4 a python skip with no sentence",
              lambda: census_skips(n4), want="empty sentence")

n5 = doctored(LINUX, r'flightrec_adopt "\$bundle" desktop \\\n'
                     r'\s+"\$FLIGHTREC_SCRATCH/\$name\.desktop\.txt" \\\n'
                     r'\s+"[^"]*"',
              'flightrec_skip "$bundle" desktop ""',
              "N5 blanked a shell skip sentence")
gate.negative("N5 a shell skip with no sentence",
              lambda: census_skips(n5), want="called with no sentence")

# N6: a .skip written past the one writer.
n6 = doctored(LANE_PY, r'self\.skip\(bundle, "windows", no_list\)',
              '(bundle / "windows.skip").write_text("x", encoding="utf-8")',
              "N6 wrote a .skip past the one writer")
gate.negative("N6 a .skip written outside skip()",
              lambda: census_skips(n6), want="outside skip()")

# N7: a lane that stops closing its bundle with finish(). The mac's
# finish() is in _capture, which mac_leg calls, so the whole class is
# what this clause reads.
n7 = doctored(LANE_PY, r'self\.finish\(bundle, out=out\)\n'
                       r'(\s+)def mac_leg',
              r'self.bundle_report(bundle, out=out)\n\1def mac_leg',
              "N7 replaced the mac finish() with a bare report")
gate.negative("N7 a lane that never marks its unreached sections",
              lambda: census_finish(n7), want="never calls finish()")

# N8: the picture moved to after the display reboot — a PNG of a fresh
# empty session, which passes every "is it a plausible image" test.
n8 = doctored(LINUX, r'                flightrec_shot_x11 "\$name-\$proto" '
                     r'"\$kaya_display" "\$kaya_t0"\n',
              "", "N8 moved the x11 shot off the failure path")
gate.negative("N8 a linux picture taken after the reboot",
              lambda: census_when(n8), want="takes no picture")

# N9: a launcher whose verb-trace path drifts from the one pulled.
n9 = dict(REAL)
n9[LANE_PY] = gate.doctor("N9 renamed the verb-trace file the recorder pulls",
                          REAL[LANE_PY],
                          r'self\.pull\(bundle, leg, "vtrace\.txt", '
                          r'"verb-trace",',
                          'self.pull(bundle, leg, "vtrace-elsewhere.txt", '
                          '"verb-trace",')
gate.negative("N9 the recorder pulling a verb trace no launcher writes",
              lambda: census_vtrace(n9), want="vtrace-elsewhere.txt")

# N10: the collect polling an answer the previous run left.
n10 = doctored(LANE_PY, r'        self\._ssh\(f\'cmd /c "del \{outputs\} 2>nul & exit /b 0"\'\)\n',
               "", "N10 removed the collect's delete of its previous outputs")
gate.negative("N10 a windows collect that polls the last run's answer",
              lambda: census_collect_fresh(n10), want="does not delete its previous outputs")

# N11: the toast-moment pull taken off the windows collect while the
# section stays declared. THE CALL, not the method: five bundles named the
# toast's class and never its sender because the record was taken at
# collect, and a writer nobody calls leaves exactly that hole again
# (docs/deferred.md, the notes_rust toast entry).
n11 = doctored(LANE_PY, r'\n *self\.toast_moment\(bundle, leg, t0\)',
               "", "N11 removed the windows toast-moment call")
gate.negative("N11 a windows toast-moment writer nothing calls",
              lambda: census_sections(n11), want="`toast-moment` is declared")

# N12: the guest's own name for a toast record moved and the recorder's
# pull left where it was.
n12 = doctored(WINUI, r'crate::vtrace::sibling\("toast\.bmp"\)',
               'crate::vtrace::sibling("toast-elsewhere.bmp")',
               "N12 renamed the guest's toast picture")
gate.negative("N12 a toast record the guest writes under another name",
              lambda: census_toast_files(n12), want="toast.bmp")

# N13: the pre-leg delete of a toast record dropped — the previous run's
# capture then reads as this leg's.
n13 = doctored(WIN,
               r'\n *f"C:\\\\kaya\\\\flightrec\\\\\{name\}-toastwpn\.db "',
               "", "N13 dropped the pre-leg delete of the toast database")
gate.negative("N13 a windows leg that keeps the last run's toast capture",
              lambda: census_toast_files(n13), want="does not delete")

# NS1/NS2: the guest's picture at its failed step, the same three places.
ns1 = doctored(WINUI, r'crate::vtrace::sibling\("failshot\.bmp"\)',
               'crate::vtrace::sibling("failshot-elsewhere.bmp")',
               "NS1 renamed the guest's failed-step picture")
gate.negative("NS1 a failed-step picture the guest writes under another name",
              lambda: census_toast_files(ns1), want="failshot.bmp")
ns2 = doctored(WIN,
               r'\n *f"C:\\\\kaya\\\\flightrec\\\\\{name\}-failshot\.bmp "',
               "", "NS2 dropped the pre-leg delete of the failed-step picture")
gate.negative("NS2 a windows leg that keeps the last run's failed-step picture",
              lambda: census_toast_files(ns2), want="does not delete")

# N14: the guest's epoch stamp back on PowerShell 5.1's local-time-as-UTC
# call — the shape every windows bundle carried until 2026-09-17.
n14 = doctored(GUEST_PS1,
               r'\$at = \[DateTimeOffset\]::UtcNow\.ToUnixTimeSeconds\(\)',
               "$at = [int64](Get-Date -UFormat %s)",
               "N14 put the sampler's stamp back on -UFormat %s")
gate.negative("N14 a guest epoch stamped in local time",
              lambda: census_guest_clock(n14), want="LOCAL time")

# N15: the host's end of the same clock, alone — the two must move
# together, and either one left behind measures a timezone.
n15 = doctored(LANE_PY,
               r'"\[DateTimeOffset\]::UtcNow\.ToUnixTimeSeconds\(\)"',
               '"[int64](Get-Date -UFormat %s)"',
               "N15 put clock_sync's read back on -UFormat %s")
gate.negative("N15 a host reading the guest's clock in local time",
              lambda: census_guest_clock(n15), want="LOCAL time")

# N16: the linux focus section's collect renamed away — the shell lane's
# N2 one section over, on the section a wayland clipboard red needs.
n16 = doctored(LINUX, r'flightrec_adopt "\$bundle" focus(?= )',
               'flightrec_adopt "$bundle" focusnope',
               "N16 renamed the linux focus section away")
gate.negative("N16 the linux focus section the collect stopped writing",
              lambda: census_sections(n16), want="`focus` is declared")

# N17: the sampler writes one name and the collect cuts another — the
# windows verb-trace drift (N9) one lane over.
n17 = doctored(FOCUS_RING, r'f"focus-wl-\{number\}\.txt"',
               'f"focus-wayland-{number}.txt"',
               "N17 renamed the sampler's wayland ring file")
gate.negative("N17 a focus ring written under a name the collect never cuts",
              lambda: census_focus_ring(n17), want="the collect cuts no")

# N18: the sampler started and never stopped.
n18 = doctored(LINUX, r"trap 'flightrec_flush; focus_ring_stop; ",
               "trap 'flightrec_flush; ",
               "N18 took the focus sampler out of the EXIT trap")
gate.negative("N18 a focus sampler the lane never stops",
              lambda: census_focus_ring(n18), want="does not stop the focus sampler")

# N19: the hand run launching its own guest — the bundle is still built
# and the three sections the scratch feeds are silently skips.
n19 = doctored(HAND, r"rc = FR\.watched_leg\(SCRATCH / name, argv, env, lf, "
                     r"cwd=ROOT,\n\s+echo=sys\.stdout\)",
               "rc = subprocess.run(argv, cwd=ROOT, env=env).returncode",
               "N19 unwired the hand run's launch")
gate.negative("N19 a hand run whose bundle loses every sampled section",
              lambda: census_hand_run(n19), want="nothing fills the scratch")

# N20: the hand run keeping no bundle at all — the state a hand red was
# in until 2026-09-18.
n20 = doctored(HAND, r"FR\.mac_leg\(name, ", "FR.leg(name, ",
               "N20 took the hand run's collect off mac_leg")
gate.negative("N20 a hand red that leaves no bundle",
              lambda: census_hand_run(n20), want="leaves no bundle at all")

for worker, call in (("_leg_worker", "keep_binary_stamp(name, args[0])"),
                     ("_proof_worker", "keep_binary_stamp(name, app)"),
                     ("_witness_worker", "keep_binary_stamp(name, app)")):
    changed = dict(REAL)
    body = py_block(REAL[IOS], worker)
    patched = gate.doctor(f"iOS {worker} SDK capture cut", body, re.escape(call), "pass", want=1)
    changed[IOS] = REAL[IOS].replace(body, patched, 1)
    gate.negative(f"iOS {worker} without SDK evidence",
                  lambda: census_ios_stamp(changed), want="does not keep")
stamp_cut = doctored(LANE_PY, r'self\.adopt\(bundle, "binary-stamp",',
                     'self.adopt(bundle, "wrong-stamp",', "iOS SDK section adopt cut")
gate.negative("iOS SDK section unwritten", lambda: census_sections(stamp_cut),
              want="`binary-stamp` is declared")

for label, rel, before, after, want in (
        ("capture cut", IOS, "notification_capture(udid, bundle_id, name, installed_at, log)",
         "pass", "does not keep the notification side"),
        ("window from the verdict", IOS, "    installed_at = time.time()\n", "",
         "does not start at the leg's install"),
        ("log window dropped", IOS, '"--start", start,', '"--last", "1m",',
         "no longer reads the store and the log window"),
        ("SpringBoard dropped", LANE_PY, 'OR (process == "SpringBoard" AND ',
         "OR (", "lost SpringBoard"),
        ("adoption cut", LANE_PY, 'log.with_suffix(".notifications")',
         'log.with_suffix(".notifs")', "does not adopt")):
    changed = doctored(rel, re.escape(before), after, f"iOS notifications {label}")
    gate.negative(f"iOS notifications {label}",
                  lambda: census_ios_notifications(changed), want=want)
notif_section = doctored(LANE_PY, r'self\.adopt\(bundle, "notifications",',
                         'self.adopt(bundle, "lost-notifications",',
                         "iOS notifications section cut")
gate.negative("iOS notifications section unwritten", lambda: census_sections(notif_section),
              want="`notifications` is declared")
for label, before, after, want in (
        ("orphan", "orphaned += owner is None", "orphaned += 0", "orphaned record"),
        ("age", "age is not None and age > 7", "age is not None and age > 70", "expiry age"),
        ("own section", "maps to section {mapping.get(bundle_id) or 'NONE'}",
         "maps to section NONE", "own section"),
        ("decode", 'out.append(f"  {d.name}/{store} did not decode',
         'print(f"  {d.name}/{store} did not decode',
         "hid an undecodable file")):
    changed = doctored(LANE_PY, re.escape(before), after, f"iOS store {label} mutation")
    gate.negative(f"iOS store {label} corrupted",
                  lambda: ios_notification_checks(changed), want=want)

for call in ("android_system_events", "android_anr_history", "android_shade_history"):
    changed = doctored(ANDROID, re.escape(f"flightrec_lane.{call}("),
                       f"flightrec_lane.unwired_{call}(", f"Android {call} capture cut")
    gate.negative(f"Android {call} capture unwritten",
                  lambda: census_android_history(changed), want="failure path does not write")
for name in ("system-events", "anr-history", "shade-history"):
    changed = doctored(LANE_PY, re.escape(f'self.adopt(bundle, "{name}",'),
                       f'self.adopt(bundle, "wrong-{name}",', f"Android {name} adoption cut")
    gate.negative(f"Android {name} section unwritten",
                  lambda: census_sections(changed), want=f"`{name}` is declared")
for label, before, after, want in (
        ("package", 'if f"Process: {package}" in entry.splitlines()', "if True",
         "filter by exact package"),
        ("attribution", "Reports can predate this leg", "Reports belong to this leg",
         "current-leg attribution"),
        ("read status", "if returncode != 0:", "if False:",
         "diagnostic lost its measured result"),
        ("focus", "input_focus:", "lost_focus:", "dropped a focus/ANR event"),
        ("native drag", "WindowManager:", "LostWindowManager:", "drag event"),
        ("view drop", "VRI", "LostView", "drag event"),
        ("Kaya drag", "KAYA_DRAG_", "LOST_DRAG_", "drag event"),
        ("media codec", "C2Goldfish", "LostGoldfish", "media codec event"),
        ("shade panel", "New panel State:|", "Lost panel State:|", "shade history dropped"),
        ("shade focus", "should be (?:visible and )?focusable|", "should be lost|",
         "shade history dropped"),
        ("shade order", "lines = sorted({", "lines = list({", "not oldest first"),
        ("shade status", "    if status:\n", "    if False:\n", "read failure lost"),
        ("shade attribution", "oldest first. History can predate this leg",
         "oldest first. History belongs to this leg", "current-leg attribution")):
    changed = doctored(LANE_PY, re.escape(before), after, f"Android {label} report mutation")
    gate.negative(f"Android {label} report corrupted",
                  lambda: android_report_checks(changed), want=want)

power_cut = doctored(LANE_PY, r'self\._text_section\(bundle, "power-history",',
                     'self._text_section(bundle, "lost-history",', "Mac power section cut")
gate.negative("Mac power section unwritten", lambda: census_sections(power_cut),
              want="`power-history` is declared")
for label, before, after, want in (
        ("capture", "mac_power_history(power_text, power_code)", "power_text",
         "no longer reads and renders"),
        ("newest", "lines[-200:]", "lines[:200]", "lost newest events"),
        ("filter", "(?:Sleep|Wake|DarkWake)", "(?:Gone|Wake|DarkWake)", "lost newest events"),
        ("status", "if code:", "if False:", "diagnostic lost its measured result"),
        ("attribution", "not current-leg attribution", "current-leg attribution",
         "claimed current-leg attribution")):
    changed = doctored(LANE_PY, re.escape(before), after, f"Mac power {label} mutation")
    gate.negative(f"Mac power {label} corrupted", lambda: mac_power_checks(changed), want=want)

for label, before, after, want in (
        ("capture", "mac_unified_log(self._sampler_pid(scratch))", "mac_unified_log(None)",
         "over the leg's guest pid"),
        ("one query", '[("this leg\'s guest", f"processID == {pid}"),',
         '[("this leg\'s guest", f"processID == {pid} OR process == \\"replayd\\""),',
         "share a query with replayd"),
        ("head kept", "data = data[-room:]", "data = data[:room]", "kept its oldest lines"),
        ("no collapse", "        data = mac_log_collapse(data)\n", "",
         "the step before it was cut"),
        ("no MediaRemote section",
         "              (\"MediaRemote's commands\",\n"
         "               '(process == \"mediaremoted\" AND eventMessage "
         "CONTAINS[c] \"command\") OR '\n"
         "               '(process == \"perl\" AND subsystem BEGINSWITH "
         "\"com.apple.amp.mediaremote\")'),\n",
         "", "no MediaRemote section"),
        ("no connection-loss section",
         "              (\"replayd connections cut, every process\",\n"
         "               'eventMessage == \"RPDaemonProxy: connection INTERRUPTED\"')]",
         "]", "no every-process replayd connection-loss section"),
        ("status", 'state = "ok" if all(c == 0 for c in codes) else "error"', 'state = "ok"',
         "not reported with its exit")):
    changed = doctored(LANE_PY, re.escape(before), after, f"Mac unified log {label} mutation")
    gate.negative(f"Mac unified log {label} corrupted",
                  lambda: mac_unified_log_checks(changed), want=want)

with tempfile.TemporaryDirectory(prefix="kaya-record-probe-") as directory:
    record_dir = pathlib.Path(directory)
    film = record_dir / "edge.mp4"
    png = record_dir / "white.png"
    subprocess.run([
        "ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
        "color=white:s=16x16:r=10:d=1", "-f", "lavfi", "-i",
        "color=black:s=16x16:r=10:d=1", "-filter_complex",
        "[0:v][1:v]concat=n=2:v=1:a=0", "-c:v", "libx264", str(film)], check=True)
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(film),
                    "-frames:v", "1", str(png)], check=True)
    for finding in ios_recording_checks(REAL, png, film):
        gate.finding(finding, at="iOS recording")
    for finding in android_recording_checks(REAL, film):
        gate.finding(finding, at="Android recording")
    for finding in windows_recording_diagnostic(REAL, record_dir):
        gate.finding(finding, at="Windows recording")
    for label, before, after, want in (
            ("frame identity", 'f"{name}: no frames overlap the leg\'s transcript: slot={slot}, "',
             'f"{name}: no frames overlap the leg\'s transcript: slot=unknown, "', "lost slot=2"),
            ("capturer log", '(recdir / "recorder.log").write_text(recorder_log, encoding="utf-8")',
             'pass', "did not retain capturer transcript")):
        changed = doctored(WIN, re.escape(before), after, f"Windows recording {label}")
        gate.negative(f"Windows recording {label} corrupted",
                      lambda: windows_recording_diagnostic(changed, record_dir), want=want)
    for label, before, after, want in (
            ("log level", '"ffprobe", "-v", "error"',
             '"ffprobe", "-v", "exclusive"', "Invalid loglevel"),
            ("exit status", 'if got.returncode:\n', 'if False:\n', "hid command failure"),
            ("guessed duration", 'duration = 0', 'duration = 2000', "guessed duration"),
            ("reader call", 'dur_ms = recording_duration_ms(rec_dir / "video.mp4", log)',
             'dur_ms = 2000', "reader is not reached"),
            ("capture", 'if failed or "KAYA_SELFTEST: OK" not in out:',
             'if "KAYA_SELFTEST: OK" not in out:', "skipped recorder sections"),
            ("pull status", 'if pulled:', 'if False:', "reuse stale video")):
        changed = doctored(ANDROID, re.escape(before), after, f"Android recording {label}")
        gate.negative(f"Android recording {label} corrupted",
                      lambda: android_recording_checks(changed, film), want=want)
    for label, before, after, count, want in (
            ("log level", '"ffprobe", "-v", "error"',
             '"ffprobe", "-v", "exclusive"', 2, "Invalid loglevel"),
            ("exit status", "if got.returncode:\n", "if False:\n", 1,
             "hid the command failure"),
            ("guessed luma", 'die(f"recording: ffprobe returned no numeric luma '
             'for {png}: {got!r}")', "return 175", 1, "invented a luma"),
            ("first frame", "eq(n\\\\,0)+", "", 1, "read None")):
        changed = doctored(IOS, re.escape(before), after,
                           f"iOS recording {label}", want=count)
        gate.negative(f"iOS recording {label} corrupted",
                      lambda: ios_recording_checks(changed, png, film), want=want)

for finding in windows_recording_width(REAL):
    gate.finding(finding, at="Windows recording")
changed = doctored(WIN, re.escape('1 if os.environ.get("KAYA_RECORD") else '), "",
                   "Windows recording serialization")
gate.negative("Windows recording pool loses window identity",
              lambda: windows_recording_width(changed), want="recording pool width")

for call in ("xcuidrive_stop_all()", "xcuidrive_launch_all()", "xcuidrive_join()"):
    changed = dict(REAL)
    body = py_block(REAL[IOS], "rec_suite_start")
    cut = gate.doctor(f"iOS recording recovery {call}", body, re.escape(call), "pass", want=1)
    changed[IOS] = REAL[IOS].replace(body, cut, 1)
    gate.negative(f"iOS recording recovery without {call}",
                  lambda: ios_recording_recovery(changed), want="driver lifecycle")

# The ceiling's stacks: the pre-fix read-after-exit, the load sample and
# the debuginfod lookup, each taken out of a copy.
for label, pattern, repl, want in (
        ("NW1 pipes read after exit",
         r"    let out = drain\(child\.stdout\.take\(\)\);\n"
         r"    let err = drain\(child\.stderr\.take\(\)\);\n",
         "", "does not drain its pipes"),
        ("NW2 no load sample", r'std::fs::read_to_string\("/proc/loadavg"\)',
         'std::fs::read_to_string("/proc/version")', "no load sample"),
        ("NW3 debuginfod asked", r'        \.env_remove\("DEBUGINFOD_URLS"\)\n', "",
         "debuginfod"),
        ("NW4 test gone", r"fn ceiling_capture_drains_a_large_output\(\)",
         "fn ceiling_capture_small()", "unit test")):
    changed = doctored(HARNESS, pattern, repl, label)
    gate.negative(label, lambda: census_wedge_capture(changed), want=want)

for label, rel, pattern, repl, want in (
        ("LC1 an x11 leg back on a bare timeout", LINUX,
         r'GDK_BACKEND=x11 \\\n(\s+)(XDG_STATE_HOME="\$kaya_state" '
         r'KAYA_VERB_TRACE="\$LEGS_DIR/\$name-\$proto\.vtrace") \\\n'
         r'\s+python3 /work/tools/linux/leg-ceiling\.py 180',
         r'GDK_BACKEND=x11 \\\n\1\2 timeout 180',
         "bare `timeout 180`"),
        ("LC2 the lane skipping the ceiling's self-test", LINUX,
         r"^python3 /work/tools/linux/leg-ceiling\.py --self-test.*\n", "", "never runs"),
        ("LC3 the ceiling's stacks without build ids", LEG_CEILING,
         r'"eu-stack", "-m", "-b", "-p"', '"eu-stack", "-m", "-p"', "no build ids"),
        ("LC4 the harness's stacks without build ids", HARNESS,
         r'&\["-m", "-b", "-p", &pid\]', '&["-m", "-p", &pid]', "no build ids"),
        ("LC6 GTK's display failure unmeasured", GTK_RS,
         r"crate::display_probe::display_why_not\(", "crate::display_probe::unused(",
         "socket answered"),
        ("LC5 the drain naming no frame", LINUX,
         r'python3 /work/tools/linux/stack-names\.py "\$LEGS_DIR/\$name\.log"',
         'true "$LEGS_DIR/$name.log"', "never runs"),
    ):
    changed = doctored(rel, pattern, repl, label)
    gate.negative(label, lambda changed=changed: census_leg_ceiling(changed), want=want)

for label, rel, pattern, repl, want in (
        ("ND3 persist-leg pushing its launcher itself", DOOR_LEGS[0],
         r"door_record\.push\(", "subprocess_run(", "door_record.push"),
        ("ND4 link-leg printing no record", DOOR_LEGS[1],
         r"door_record\.report\(", "print_nothing(", "door_record.report"),
        ("ND5 persist-leg polling without its watch", DOOR_LEGS[0],
         r"^        watch\.sample\(\)\n", "", "never samples the watch"),
        ("ND6 act2-exec.sh exec'ing again", ACT2_EXEC,
         r'^"\$@" >>', 'exec "$@" >>', "drops the launcher's exit status"),
        ("ND7 the lane skipping the record's self-test", LINUX,
         r"^python3 /work/tools/linux/door_record\.py --self-test.*\n", "",
         "never runs"),
        ("ND8 persist-leg's door back on gio launch", DOOR_LEGS[0],
         r"launcher = \[sys\.executable, str\(LAUNCH_ENTRY\), str\(entry\)\]",
         'launcher = ["gio", "launch", str(entry)]', "launch-entry.py")):
    changed = doctored(rel, pattern, repl, label)
    gate.negative(label, lambda: census_door_record(changed), want=want)

for label, rel, pattern, repl, want in (
        ("NS1 the watchdog leaving without the stacks", SWIFTUI,
         r"^( +)kayaCeilingStacks\(step\)\n", "", "no longer asks the host"),
        ("NS2 the request renamed on the host side", IOS,
         r'docs / "kaya-stacks-request"', 'docs / "kaya-stack-request"',
         "kaya-stacks-request is not the one file name"),
        ("NS3 no watcher around the launch", IOS,
         r"^    stacks\.start\(\)\n", "    pass\n",
         "does not run stacks_watch"),
        ("NS4 a sample bound past the harness's wait", IOS,
         r"^STACKS_SAMPLE_CAP = 20$", "STACKS_SAMPLE_CAP = 30",
         "not inside the harness's wait"),
        ("NS5 the sidecar adopted under another name", LANE_PY,
         r'log\.with_suffix\("\.stacks"\)', 'log.with_suffix(".stack")',
         "does not adopt")):
    changed = doctored(rel, pattern, repl, label)
    gate.negative(label, lambda: census_ios_stacks(changed), want=want)
for label, rel, pattern, repl, want in (
        ("NS7 the ceiling without the animation census", SWIFTUI,
         r"animations at the ceiling: \\\(kayaCeilingAnimations\(\)\)",
         "animations at the ceiling: none", "every layer's animations"),
        ("NS8 the leg log without XCTest's idle waits", IOS,
         r"xl\.seek\(xcode_log_at\)", "xl.seek(0)", "XCTest's own idle waits")):
    changed = doctored(rel, pattern, repl, label)
    gate.negative(label, lambda: census_ios_stacks(changed), want=want)
stacks_section = doctored(LANE_PY, r'self\.adopt\(bundle, "stacks",',
                          'self.adopt(bundle, "lost-stacks",', "NS6 iOS stacks section cut")
gate.negative("NS6 iOS stacks section unwritten", lambda: census_sections(stacks_section),
              want="`stacks` is declared")

for label, rel, pattern, repl, want, check in (
        ("NL1 the app log selected by process name again", IOS,
         r'f"processID == \{pid\}" if pid is not None',
         "f'process == \"{executable}\"' if pid is not None",
         "selected by the launch's pid", census_ios_app_log),
        ("NL2 the app log's window back to the last two minutes", IOS,
         r'"show", "--start", since,', '"show", "--last", "2m",',
         "selected by the launch's pid", census_ios_app_log),
        ("NL3 the launch's pid not handed over", IOS,
         r"flightrec_lane\.ios_launch_pid\(out, bundle_id\), launched_at\)",
         "None, launched_at)", "hand device_capture", census_ios_app_log),
        ("NL4 the launch stamped after the launch", IOS,
         r"^    launched_at = time\.time\(\)\n", "", "start at the leg's launch",
         census_ios_app_log),
        ("NL5 the idle summary dropped from the slice", IOS,
         r"flightrec_lane\.ios_xctest_idle\(body\)", '""', "lead with",
         census_ios_app_log),
        ("NL6 an answer that clears no request", LANE_PY,
         r"if pending:\n( +)at = pending\.pop\(0\)", r"if pending:\n\1at = pending[0]",
         "misreads an answered", ios_app_log_checks),
        ("NL7 an unanswered wait never listed", LANE_PY,
         r'unanswered \+= \[f"\{kind\} asked at \{at\}" for at in pending\]',
         "unanswered += []", "lost the unanswered", ios_app_log_checks),
        ("NL8 any launch line's pid taken", LANE_PY,
         r'rf"\^\{re\.escape\(bundle_id\)\}: ', r'r"^\\S+: ',
         "simctl's own line", ios_app_log_checks),
        ("NL9 a 60 s idle wait never called late", LANE_PY,
         r'late\.append\(f"\{kind\} asked at \{at\} answered \{wait:\.2f\} s later"\)',
         "pass", "calls a 60 s animations wait answered", ios_app_log_checks)):
    changed = doctored(rel, pattern, repl, label)
    gate.negative(label, lambda: check(changed), want=want)

for label, rel, pattern, repl, want, check in (
        ("NH1 the ceiling without XCTest's count and the ledger", SWIFTUI,
         r'^ +Data\("KAYA_HARNESS: \\\(KayaAnimationLedger\.shared\.reading'
         r'\("at the ceiling"\)\)\\n"\.utf8\)\)\n',
         "", "no longer prints XCTest's animation count", census_ios_hang_record),
        ("NH2 a slow driver request read nothing", SWIFTUI,
         r"KayaAnimationLedger\.shared\.reading\(moment\)", '"nothing"',
         "kayaDriverSlowReading no longer prints", census_ios_hang_record),
        ("NH3 the ledger swallowing XCTest's start", SWIFTUI,
         r"^ +prevStart\(state, startSel, anim\)\n", "", "the replaced start still called",
         census_ios_hang_record),
        ("NH4 the ledger never installed", SWIFTUI,
         r"DispatchQueue\.main\.sync \{ KayaAnimationLedger\.shared\.install\(\) \}",
         "DispatchQueue.main.sync {}", "no longer installs", census_ios_hang_record),
        ("NH5 a slow reading past the ceiling", SWIFTUI,
         r"kayaDriverSlowReading: TimeInterval = 15", "kayaDriverSlowReading: TimeInterval = 60",
         "not inside the step ceiling", census_ios_hang_record),
        ("NH6 the Swift reading renamed under the reader", SWIFTUI,
         r'"XCTest IN PROGRESS \(', '"XCTest BUSY (', "'XCTest IN PROGRESS'",
         census_ios_hang_record),
        ("NH7 a failed leg without the system's account", IOS,
         r"^ +system_capture\(udid, name, log, launched_at,\n.*\n", "",
         "no longer keeps the system's account", census_ios_hang_record),
        ("NH8 the system log without its Info lines", IOS,
         r'"--start", since, "--info",', '"--start", since,', "the Info lines",
         census_ios_hang_record),
        ("NH9 the system log beyond the secure scan", IOS,
         r'^ +\("system log", leg_log\.with_suffix\("\.syslog"\)\),\n', "",
         "without the secure scan", census_ios_hang_record),
        ("NH10 a held count judged without its open animation", LANE_PY,
         r'f"animation\(s\) no stop has matched; the oldest: \{opens\[0\]\}"',
         'f"animation(s) no stop has matched"', "held reading lost", ios_hang_record_checks),
        ("NH11 a session ended before the exit read as the exit", LANE_PY,
         r"if lead > 1 else", "if lead > 1e9 else", "let go reading lost",
         ios_hang_record_checks),
        ("NH12 a crash report never matched to its pid", LANE_PY,
         r'doc\.get\("pid"\) == pid', "False", "crash reading lost",
         ios_hang_record_checks),
        ("NH17 the driver attached without the quiet wait", SWIFTUI,
         r"while !KayaAnimationLedger\.shared\.quiet\(for: kayaDriverAttachQuiet\), "
         r"Date\(\) < settled \{",
         "while false, Date() < settled {", "after the ledger reads no UIView animation",
         census_ios_hang_record),
        ("NH18 a driver leg never told to attach early", IOS,
         r'^    if needs_driver\(script\):\n'
         r'        env\["SIMCTL_CHILD_KAYA_DRIVER_ATTACH"\] = "1"\n',
         "", "is not told to attach it", census_ios_hang_record),
        ("NH15 the reading blind to XCTest loading over an open animation", LANE_PY,
         r"^( +)if blind:\n", r"\1if False:\n", "blind reading lost", ios_hang_record_checks),
        ("NH16 the ledger never marking what XCTest saw start", SWIFTUI,
         r"blind = loaded && !open\[at\]\.xctest", "blind = false",
         "what XCTest saw start", census_ios_hang_record),
        ("NH19 the layer an animation is added to never recorded", SWIFTUI,
         r"^ +KayaAnimationLedger\.shared\.added\(layer, key as String\?\)\n", "",
         "the add recorded", census_ios_hang_record),
        ("NH20 an open start printed without its add's layer", SWIFTUI,
         r"\n +\+ \(gotNow\[entry\.id\] \?\? \"\"\)\)", ")",
         "read beside each open start", census_ios_hang_record)):
    changed = doctored(rel, pattern, repl, label)
    gate.negative(label, lambda: check(changed), want=want)
for label, name, want in (("NH13 iOS animations section unwritten", "animations",
                           "`animations` is declared"),
                          ("NH14 iOS system-log section unwritten", "system-log",
                           "`system-log` is declared")):
    changed = doctored(LANE_PY, rf'self\.adopt\(bundle, "{name}",',
                       f'self.adopt(bundle, "lost-{name}",', label)
    gate.negative(label, lambda: census_sections(changed), want=want)

for label, pattern, repl, want in (
        ("NR1 a pruned run's red bundles deleted with it, as shipped",
         r"^ +os\.rename\(b, dest\)\n", "", "lost red bundle"),
        ("NR2 the time bound ignored", r"< horizon\]", "< horizon - 1e12]",
         "older than 90 days"),
        ("NR3 the disk bound ignored", r"while sized and total > limit:",
         "while False:", "past the disk bound"),
        ("NR4 the newest red bundle dropped first", r"over\.append\(sized\.pop\(0\)\)",
         "over.append(sized.pop())", "lost red bundle"),
        ("NR5 a dry run that deletes", r'(say\(f"would remove red bundle .*\n) +continue\n',
         r"\1", "dry run moved or removed"),
        ("NR6 a removed run not printed", r'^ +say\(f"removed run \{d\} \(\{what\}\)"\)\n',
         "", "did not print each removed run"),
        ("NR7 a kept bundle without its journal",
         r"^( +)_journal_copy\(d / \"journal\.jsonl\", journal, d\.name\)\n", r"\1pass\n",
         "lost its run's journal"),
        ("NR8 every run kept whole", r"doomed = dirs\[: max\(0, len\(dirs\) - cap\)\]",
         "doomed = []", "runs kept")):
    changed = doctored(JOURNAL, pattern, repl, label)
    gate.negative(label, lambda: retention_checks(changed), want=want)

for label, rel, pattern, repl, want, check in (
        ("MD6 LaneRecorder.leg spawns", LANE_PY,
         r"(\n +)fd = os\.open\(str\(self\.spool\)",
         r'\1subprocess.run(["true"])\1fd = os.open(str(self.spool)',
         "LaneRecorder.leg spawns", census_pass_path),
        ("MD7 flightrec_leg spawns python3", LANE_SH,
         r"^(    printf '%s\\t%s\\t%s)", r"    python3 -c pass\n\1",
         "flightrec_leg calls 'python3'", census_pass_path),
        ("MD8 an absent log tool raises out of the collect", LANE_PY,
         r"\n +except OSError as error:\n +data, code = str\(error\)\.encode\(\), "
         r"f\"not run: \{error\.strerror\}\"", "",
         "absent `log` tool raised", mac_unified_log_checks),
        ("MD9 section() without its absent-tool skip", LANE_PY,
         r"\n +except FileNotFoundError:\n +dest\.unlink\(missing_ok=True\)\n"
         r" +self\.skip\(bundle, name,\n.*\n.*\n +return", "",
         "an absent capture tool", absent_tool_checks)):
    changed = doctored(rel, pattern, repl, label)
    gate.negative(label, lambda: check(changed), want=want)
for tag, want in (("MD1", "never resolved the guest's pid"),
                  ("MD2", "never reached section windowserver"),
                  ("MD3", "carries no measured reason"),
                  ("MD4", "PASSING leg scaffolded a bundle"),
                  ("MD5", "an unwritable journal cost the leg")):
    if tag in DRIVES:
        label, drive = DRIVES[tag]
        gate.negative(label, lambda: mac_drive_checks(drive), want=want)

for label, rel, pattern, repl, want, check in (
        ("LH1 the windows lane's end reading cut", WIN,
         r'^lane_health_reading\("end"\)\n', "", "called 1/0 times", census_lane_health),
        ("LH2 the windows lane's start reading cut", WIN,
         r'^lane_health_reading\("start"\)\n', "", "called 0/1 times", census_lane_health),
        ("LH3 the iOS end reading after the verdict", IOS,
         r'^(lane_health\.ios_report\("ios", "end", .*\n)((?:.*\n)*?)(if status == 0:\n'
         r' +print\("run-sim: ALL PASS"\)\n.*\n.*\n)', r"\2\3\1",
         "does not come after the start and before the verdict", census_lane_health),
        ("LH4 the android end reading cut", ANDROID,
         r'^lane_health\.android_report\("android", "end".*\n', "", "called 1/0 times",
         census_lane_health),
        ("LH5 the mac end reading cut", MAC_RUNNER,
         r'^lane_health\.mac_report\("mac", "end"\)\n', "", "called 1/0 times",
         census_lane_health),
        ("LH6 the linux end reading cut", LINUX_HOST,
         r'^lane_health\.linux_report\("linux", "end".*\n', "", "called 1/0 times",
         census_lane_health),
        ("LH7 the guest no longer read", WIN,
         r"lane_health\.windows_report\(\"windows\", when,", "print(when,",
         "no longer reads the guest", census_lane_health),
        ("LH8 a lane's exit without the host's reading", VALIDATE_ALL,
         r'^ +print\(f"\{name\}: exited after .*\n.*lane_health\.host_line\(\).*\n', "",
         "no longer prints the host's reading", census_lane_health),
        ("LH9 the leg-time comparison cut", VALIDATE_ALL,
         r"lane_health\.compare_runs\(", "dict(", "no leg-time comparison",
         census_lane_health),
        ("LH10 a shift without the lane's readings", VALIDATE_ALL,
         r"lane_health\.health_lines\(log_text\)", "[]", "no longer reprints",
         census_lane_health),
        ("LH11 a scan with no end read as finished", LANE_HEALTH,
         r"elif end is None or start > end:", "elif end is None:",
         "branch `scan running` did not print", lane_health_checks),
        ("LH12 a shift under the ceiling never reported", LANE_HEALTH,
         r"fires = over or abs\(change\) > SHIFT", "fires = over",
         "branch `shift` did not print", lane_health_checks),
        ("LH13 a simulator's processes read off the root alone", LANE_HEALTH,
         r"stack\.append\(child\[\"pid\"\]\)", "pass",
         "branch `simulator` did not print", lane_health_checks),
        ("LH14 the runtimes' exclusions compared case-sensitively", LANE_HEALTH,
         r"low = where\.lower\(\)", "low = where", "branch `excluded path` did not print",
         lane_health_checks),
        ("LH15 Defender exclusions no longer read", LANE_HEALTH,
         r"try\{\$f=Get-MpPreference;", "try{$f=$null;", "lost its Defender exclusions",
         lane_health_checks),
        ("LH16 a windows reading past cmd.exe's line", LANE_HEALTH,
         r'^(\"took=\"\+\$w\.ElapsedMilliseconds\n)', "\\1" + "#" + "x" * 2600 + "\n",
         "cmd.exe refuses", lane_health_checks)):
    changed = doctored(rel, pattern, repl, label)
    gate.negative(label, lambda: check(changed), want=want)
for label, rel, pattern, repl, want, check, subs in (
        ("NG1 the native-image phase cut", WIN, r"^native_images\(\)\n", "",
         "called 0 times", census_lane_health, 1),
        ("NG2 the native-image phase after the start reading", WIN,
         r'^native_images\(\)\ntiming\("native-images"\)\nlane_health_reading\("start"\)\n',
         'lane_health_reading("start")\nnative_images()\ntiming("native-images")\n',
         "does not run after vm-ready and before", census_lane_health, 1),
        ("NG3 a pending queue never drained", WIN,
         r"lane_health\.ngen_drain_command\(framework\)", "framework", "no longer drains",
         census_lane_health, 1),
        ("NG4 a refusal printed and the lane run anyway", WIN, r"^( +)die\(refusal\)\n",
         r"\1print(refusal)\n", "does not stop the lane", census_lane_health, 2),
        ("NG5 the pending count read off another word", LANE_HEALTH,
         r"-SimpleMatch 'StatusPending'", "-SimpleMatch 'Pending'",
         "lost its pending native images", lane_health_checks, 1),
        ("NG6 the PowerShell start's CPU not read", LANE_HEALTH,
         r"\$p\.TotalProcessorTime\.TotalMilliseconds", "0",
         "lost its PowerShell start's CPU", lane_health_checks, 1),
        ("NG7 a slow PowerShell start not called slow", LANE_HEALTH,
         r"if cpu_ms > PS_SLOW_MS else", "if False else",
         "branch `slow powershell` did not print", lane_health_checks, 1),
        ("NG8 items left after the drain read as drained", LANE_HEALTH,
         r"^    if todo:\n        left", "    if False:\n        left",
         "branch `drain failed` did not print", lane_health_checks, 1),
        ("NG9 a framework with nothing pending drained", LANE_HEALTH,
         r"for f, n in pending\.items\(\) if n\]", "for f, n in pending.items()]",
         "branch `plan drains only the pending` did not print", lane_health_checks, 1)):
    changed = doctored(rel, pattern, repl, label, want=subs)
    gate.negative(label, lambda: check(changed), want=want)
for label, pattern, repl, want in (
        ("VP1 the aim unrecorded", r'^ +note\(node, "scroll_to_row r\\\(index\)"\)\n', "",
         "lost the aim"),
        ("VP2 a cancelled park unrecorded", r'"park cancelled: the offset moved from "',
         '"park off "', "lost the cancel"),
        ("VP3 the park's passes unrecorded", r"if anchorRow != nil \{ note\(node, \"\"\) \}",
         "_ = anchorRow", "lost each pass of a park"),
        ("VP4 the rows above the target dropped", r"rows\.append\(\"r\\\(index\) ",
         'rows.append("', "lost the rows"),
        ("VP5 expect_window's refusal unrecorded",
         r"if read != want \{ window\.noteRead\(node, read\) \}", "_ = want",
         "no longer records the window")):
    changed = doctored(SWIFTUI, pattern, repl, label)
    gate.negative(label, lambda: census_ios_park(changed), want=want)

for label, rel, pattern, repl, want, check in (
        ("AP1 a pooled leg's end without the app reading", MAC_RUNNER,
         r"^( +)lane_health\.MAC_APPS\.leg_ended\(entry\)\n\n\n", r"\1pass\n\n\n",
         "_run_leg no longer reads the apps", census_mac_apps),
        ("AP2 the serial leg's end without the app reading", MAC_RUNNER,
         r"^( +)lane_health\.MAC_APPS\.leg_ended\(entry\)\n( +)secs = ", r"\2secs = ",
         "the serial path no longer reads the apps", census_mac_apps),
        ("AP3 the lane's end reading without its apps", LANE_HEALTH,
         r"for sentence in MAC_APPS\.end\(\):", "for sentence in []:",
         "mac_report no longer takes the app reading", census_mac_apps),
        ("AP4 the java guest launched by another spelling", MAC_LANE,
         r'"-XstartOnFirstThread", "-cp",', '"-XstartOnFirstThread", "-classpath",',
         "the exclusion `java` is no longer named", census_mac_apps),
        ("AP5 a leg's end that reads nothing", LANE_HEALTH,
         r'self\.sample\(f"after \{entry\[0\]\}"\)', "pass",
         "a leg's end no longer reads the apps", census_mac_apps),
        ("AP6 talagentd's relaunch unread", LANE_HEALTH,
         r'elif proc == "talagentd" and bundle in msg:', "elif False:",
         "branch `TAL relaunch` did not print", lane_health_checks),
        ("AP7 legs a second away counted as running", LANE_HEALTH,
         r"if began < t \+ 1 and \(ended is None or ended >= t\)",
         "if began <= t + 1 and (ended is None or ended >= t - 1)",
         "branch `app appeared` did not print", lane_health_checks),
        ("AP8 a lane binary under another app's id excluded", LANE_HEALTH,
         r'if owner and \(not app\["bundle"\] or LANE_BUNDLE\.match\(app\["bundle"\]\)\):',
         "if owner:", "branch `lane binary under another id` did not print",
         lane_health_checks),
        ("AP9 the new app's windows unread", LANE_HEALTH,
         r'first\["windows"\] = window_sentence\(app\["pid"\], '
         r'\*self\.windows\(app\["pid"\], self\.root\)\)',
         'first["windows"] = "windows not read"', "branch `window on screen` did not print",
         lane_health_checks),
        ("AP10 an adopted identity printed and the lane passed", MAC_RUNNER,
         r"(identity \(IDENTITY ADOPTED above\)\",\n +file=sys\.stderr\)\n +)status = 1\n",
         r"\1pass\n", "no longer fails the lane", census_mac_apps),
        ("AP11 records never read for an adopted identity", LANE_HEALTH,
         r"^ +self\.adoption\(app, where\)\n", "",
         "sample no longer reads every record", census_mac_apps),
        ("AP12 a record held since the start refused", LANE_HEALTH,
         r"\n +or self\.exe_at_start\.get\(app\[\"pid\"\]\) == app\[\"exe\"\]\):", "):",
         "branch `a record held since the start and kaya's own bundle not refused` did not "
         "print", lane_health_checks),
        ("AP13 kaya's own bundle refused", LANE_HEALTH,
         r"if \(not owner or not bundle or LANE_BUNDLE\.match\(bundle\)",
         "if (not owner or not bundle",
         "branch `a record held since the start and kaya's own bundle not refused` did not "
         "print", lane_health_checks),
        ("AP15 a host agent reported as an appearance", LANE_HEALTH,
         r"^( +)if agent and not owner:\n", r"\1if False:\n",
         "branch `summary` did not print", lane_health_checks),
        ("AP16 a host agent this host no longer has", LANE_HEALTH,
         r'"AXVisualSupportAgent\.app/Contents/MacOS/AXVisualSupportAgent",',
         '"AXVisualSupportAgent.app/Contents/MacOS/AXVisualSupportAgentGone",',
         "which this host no longer has", census_mac_apps),
        ("AP14 the adoption's legs unread", LANE_HEALTH,
         r"running = legs_at\(self\.legs, t\)\n( +)when = \(f\"checked in",
         "running = []\n\\1when = (f\"checked in",
         "branch `identity adopted` did not print", lane_health_checks)):
    changed = doctored(rel, pattern, repl, label)
    gate.negative(label, lambda: check(changed), want=want)

for label, pattern, repl, want in (
        ("MT1 the exit status unrecorded",
         r'^ +\(scratch / "exit-status\.txt"\)\.write_text\(f"\{rc\}\\n", encoding="utf-8"\)\n',
         "", "no longer records the leg's exit status"),
        ("MT2 the timeout sentence never written to the log",
         r"if rc == 124:\n", "if False:\n", "no longer writes the timeout sentence"),
        ("MT3 the verb-trace absence back to the generic sentence",
         r"why_absent=mac_no_trace_sentence\(scratch, log\)\)",
         'why_absent="flightrec: the guest wrote no verb trace")',
         "no longer reads the exit status"),
        ("MT4 the step dropped from the timeout sentence",
         r'where = f"in step `\{step\}`" if step else', 'where = "somewhere" if step else',
         "branch `killed in a step` did not print")):
    changed = doctored(LANE_PY, pattern, repl, label)
    gate.negative(label, lambda: mac_timeout_checks(changed), want=want)

for verb, _ in GTK_MEDIA_NOTES:
    label = f"MG {verb} cut from the GTK media arm"
    changed = doctored(GTK_RS, rf'super::sheet_note\("{verb}", ', "drop((), ", label,
                       want=2 if verb == "player_command" else 1)
    gate.negative(label, lambda: census_gtk_media_ring(changed), want=f"({verb})")

gate.negatives_ran(224 + (5 if DRIVES else 0))
gate.verdict(f"{len(TABLE)} lanes, "
             f"{sum(len(v) for v in TABLE.values())} sections")
