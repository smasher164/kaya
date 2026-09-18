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
import re

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

# The recorder class whose body IS each python lane's collect path.
RECORDERS = {"mac": "MacRecorder", "windows": "WinRecorder",
             "ios": "IosRecorder", "android": "AndroidRecorder"}

# What every lane owes a reader, whatever its platform.
UNIVERSAL = ("leg-log", "verb-trace", "shot")


def sources():
    return {rel: gate.read(rel) for rel in
            (LANE_PY, LANE_SH, LINUX, IOS, ANDROID, WIN,
             STEPS, WINUI, GUEST_PS1)}


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


# ---------------------------------------------------------------- run it

REAL = sources()
CENSUSES = (("sections", census_sections), ("skip writers", census_skips),
            ("finish", census_finish), ("capture point", census_when),
            ("windows verb trace", census_vtrace),
            ("windows toast files", census_toast_files),
            ("windows collect freshness", census_collect_fresh),
            ("guest clock", census_guest_clock))
TABLE = declared(REAL)
gate.counted("lanes declaring a bundle shape", list(TABLE), floor=5)
gate.counted("sections declared across the five lanes",
             [s for names in TABLE.values() for s in names], floor=25)
for label, fn in CENSUSES:
    for line in fn(REAL):
        gate.finding(line, at=label)


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
                     r'"\$kaya_display"\n',
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

gate.negatives_ran(15)
gate.verdict(f"{len(TABLE)} lanes, "
             f"{sum(len(v) for v in TABLE.values())} sections")
