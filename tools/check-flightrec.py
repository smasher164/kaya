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
import io
import re
import subprocess
import tempfile
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

# The recorder class whose body IS each python lane's collect path.
RECORDERS = {"mac": "MacRecorder", "windows": "WinRecorder",
             "ios": "IosRecorder", "android": "AndroidRecorder"}

# What every lane owes a reader, whatever its platform.
UNIVERSAL = ("leg-log", "verb-trace", "shot")


def sources():
    return {rel: gate.read(rel) for rel in
            (LANE_PY, LANE_SH, LINUX, IOS, ANDROID, WIN,
             STEPS, WINUI, GUEST_PS1, FOCUS_RING, HAND)}


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
        r'C:/kaya/flightrec/\{leg\}-(toast[\w.-]*)"', src[LANE_PY])))
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


def census_android_history(src):
    found = []
    sections = declared(src).get("android", ())
    for name in ("system-events", "anr-history"):
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
                         ("android_anr_history", ".anr-history")):
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


def android_report_checks(src, echo=False):
    scope = {"re": re}
    for name in ("android_system_events", "android_anr_history"):
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
              "wm_set_resumed_activity:"]
    timeline = scope["android_system_events"]("\n".join([*events, "unrelated noise"]))
    if any(event not in timeline for event in events) or "unrelated noise" in timeline:
        found.append("android: system timeline dropped a focus/ANR event or kept unrelated noise")
    if "Selected 0 line(s)" not in scope["android_system_events"]("unrelated noise"):
        found.append("android: empty system timeline did not report its zero count")
    if echo:
        print(f"check-flightrec: Android timeline: {timeline.strip()}")
        print(f"check-flightrec: Android history: {answer.strip()}")
    return found


# ---------------------------------------------------------------- run it

REAL = sources()
CENSUSES = (("sections", census_sections), ("skip writers", census_skips),
            ("finish", census_finish), ("capture point", census_when),
            ("windows verb trace", census_vtrace),
            ("windows toast files", census_toast_files),
            ("windows collect freshness", census_collect_fresh),
            ("guest clock", census_guest_clock),
            ("linux focus ring", census_focus_ring),
            ("hand run", census_hand_run), ("iOS SDK stamp", census_ios_stamp),
            ("Android history", census_android_history))
TABLE = declared(REAL)
gate.counted("lanes declaring a bundle shape", list(TABLE), floor=5)
gate.counted("sections declared across the five lanes",
             [s for names in TABLE.values() for s in names], floor=25)
for label, fn in CENSUSES:
    for line in fn(REAL):
        gate.finding(line, at=label)
for line in android_report_checks(REAL, echo=True):
    gate.finding(line, at="Android report renderers")
for line in mac_power_checks(REAL, echo=True):
    gate.finding(line, at="Mac power history")
for line in ios_recording_recovery(REAL):
    gate.finding(line, at="iOS recording recovery")


def doctored(rel, pattern, repl, label, *, flags=re.M, want=1):
    src = dict(REAL)
    src[rel] = gate.doctor(label, REAL[rel], pattern, repl, flags=flags,
                           want=want)
    return src


# N1: a section the collect stops writing.
n1 = doctored(LANE_PY, r'self\.section\(bundle, "unified-log", \[',
              'self.section(bundle, "unified-nope", [',
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
                       r'the window list would not build AND "\n\s+"`screen'
                       r'capture -x -o` took no picture — this "\n\s+"bundle '
                       r'has no image of any kind"\)',
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

for call in ("android_system_events", "android_anr_history"):
    changed = doctored(ANDROID, re.escape(f"flightrec_lane.{call}("),
                       f"flightrec_lane.unwired_{call}(", f"Android {call} capture cut")
    gate.negative(f"Android {call} capture unwritten",
                  lambda: census_android_history(changed), want="failure path does not write")
for name in ("system-events", "anr-history"):
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
        ("focus", "input_focus:", "lost_focus:", "dropped a focus/ANR event")):
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

gate.negatives_ran(54)
gate.verdict(f"{len(TABLE)} lanes, "
             f"{sum(len(v) for v in TABLE.values())} sections")
