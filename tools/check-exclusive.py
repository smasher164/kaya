#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE MATRIX-WIDE EXCLUSIVE TOKEN IS WIRED WHERE IT CANNOT BE FORGOTTEN
# (tools/lib/exclusive.py). Every runner admits a leg through ONE funnel and
# that funnel must ask the token first, and hold it around the lane's own
# exclusive legs; a runner that stopped asking would run its input-driving
# legs under the other four lanes again and no lane could see it — the
# leg would merely flake, which is the state this pass came from. Beside
# it: every EXCLUSIVE name is a leg its lane actually runs (a name nothing
# wires is the "hand-queued and absent" defect of check-staging, one file
# over), the python and shell spellings say ONE set of sentences (two
# spellings of one sentence is how expect_ax's divergence lived for
# months), validate-all hands the directory to every lane and the
# container is told its path, and the sweep yields.
#
# AND THE MAC FUNNEL WAITS FOR AN IDLE HOST (clause 7, 2026-09-18): the
# token holds the other four lanes off, and nothing held off the HUMAN at
# the keyboard — matrix #38's save-java-swiftui died with every press
# swallowed while a browser was frontmost, and AX reported success for all
# three (docs/deferred.md, the swallowed-press entry). The wait sits INSIDE
# the hold and before the leg, its three numbers are literals that fit the
# mac ceiling, its sentences say what they measured and that the leg runs
# anyway, its self-test door has exactly one reader, and a red mac leg's
# verdict line names the frontmost app AT THE MOMENT OF THE RED.

import importlib.util
import re

gate = Gate("check-exclusive")

LANES = [
    # (lane, runner, funnel function, roster module or shell)
    ("mac", "tools/validate-mac.py", "queue_leg", "tools/lib/lanes/mac.py"),
    ("windows", "tools/deploy-win.py", "run_suite", "tools/lib/lanes/win.py"),
    ("ios", "tools/ios/run-sim.py", "queue_leg", "tools/lib/lanes/ios.py"),
    ("android", "tools/android/run-emulator.py", "queue_leg", "tools/lib/lanes/android.py"),
]
LINUX = "tools/linux/run-suites.sh"
EXCLUSIVE_PY = "tools/lib/exclusive.py"
EXCLUSIVE_SH = "tools/linux/exclusive.sh"


def py_function(text, name):
    """A top-level def's body: from its line to the next top-level def."""
    m = re.search(r"^def " + re.escape(name) + r"\(", text, re.M)
    if not m:
        return ""
    rest = text[m.end():]
    nxt = re.search(r"^(?:def |class |[A-Za-z_]\w* = )", rest, re.M)
    return rest[: nxt.start()] if nxt else rest


def sh_function(text, name):
    at = text.find(f"\n{name}() {{")
    if at < 0:
        return ""
    start = text.find("{", at)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def load_lane(rel):
    spec = importlib.util.spec_from_file_location("kaya_lane_exclusive", rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def roster(lane, mod):
    """Every leg name a lane can run, spelled as the lane spells it."""
    if lane == "android":
        return {leg for legs in mod.LEGS.values() for leg in legs}
    if lane == "windows":
        return {leg for block in mod.ORDER for leg in block}
    if lane == "mac":
        out = set()
        for entry in mod.ORDER:
            if entry[0] in ("drain", "panel_mode", "panel_check", "dark_leg"):
                continue
            scene, langs = entry
            out |= {mod.leg_name(scene, lang) for lang in langs}
        return out
    if lane == "ios":
        out = set()
        for e in mod.SWIFT_ENTRIES:
            out.add(f"{e.split(':')[0]}-swift")
        out |= {f"{s}-go" for s in mod.GO_SCENES}
        out |= {f"{s}-python" for s in mod.PYTHON_SCENES}
        out |= {f"{s}-swiftui" for s in mod.RUST_SCENES}
        return out
    return set()


def flatten_py(sentence):
    s = re.sub(r"\{[a-z_]+\}s\b", "<v>s", sentence)
    return re.sub(r"\{[a-z_]+\}", "<v>", s)


def flatten_sh(sentence):
    s = sentence
    s = re.sub(r"\$\(\([^)]*\)\)\.0s", "<v>s", s)
    s = re.sub(r"\$\{[A-Za-z_]+\}\.0s", "<v>s", s)
    s = re.sub(r"\$\{[A-Za-z_]+\}s\b", "<v>s", s)
    s = re.sub(r"\$[A-Za-z_][A-Za-z0-9_]*s\b(?=\s|;|,|$)", "<v>s", s)
    s = re.sub(r"\$\(\([^)]*\)\)", "<v>", s)
    s = re.sub(r"\$\{[^}]+\}", "<v>", s)
    s = re.sub(r"\$[A-Za-z_][A-Za-z0-9_]*", "<v>", s)
    s = re.sub(r"\$[0-9]+", "<v>", s)
    return s


# The sentences both spellings must say; the python module names them.
SHARED = ("waiting", "waited", "expired", "hold_waits", "held", "held_late",
          "hold_expired", "released", "broke", "summary")


MAC_RUNNER = "tools/validate-mac.py"
MAC_LANE = "tools/lib/lanes/mac.py"
# The idle wait's own sentence keys, and the phrase each must still carry —
# a sentence that stopped saying what it measured is believed anyway
# (CLAUDE.md invariant 3).
IDLE_SAYS = {
    "waiting": ("HIDIdleTime {idle}s", "wants {want}s", "(waited {waited}s of {bound}s)"),
    "cleared": ("HIDIdleTime {idle}s",),
    "expired": ("HIDIdleTime {idle}s", "running it anyway"),
    "spent": ("idle-wait budget", "HIDIdleTime {idle}s"),
    "unreadable": ("cannot read HIDIdleTime", "running without the idle wait"),
    "summary": ("idle waits", "budget"),
}


def literal(text, name):
    """A module-level `NAME = <number>` as a float, or None."""
    m = re.search(r"^" + re.escape(name) + r" = (\d+(?:\.\d+)?)$", text, re.M)
    return float(m.group(1)) if m else None


def mac_idle(texts, mod, tools):
    """Clause 7: the mac funnel waits for an idle host, inside the hold."""
    out = []
    runner, lane_text = texts[MAC_RUNNER], texts[MAC_LANE]
    body = py_function(runner, "queue_leg")
    hold = body.find('with exclusive.hold("mac", name):')
    call = body.find("lane.idle_wait(name)")
    worker = body.find("_leg_worker(name", hold + 1) if hold >= 0 else -1
    if call < 0:
        out.append(f"{MAC_RUNNER}: queue_leg never calls lane.idle_wait(name) — an "
                   f"input-driving leg is admitted without asking whether a human is at "
                   f"the host, which is matrix #38's swallowed-press red "
                   f"(docs/deferred.md, that entry)")
    elif not (0 <= hold < call < worker):
        out.append(f"{MAC_RUNNER}: lane.idle_wait(name) is not between the token's hold "
                   f"and the leg — outside the hold another lane admits its own "
                   f"input-driving leg into the same busy host while this one waits")
    if "lane.idle_summary()" not in runner:
        out.append(f"{MAC_RUNNER}: never prints lane.idle_summary() — what waiting for a "
                   f"quiet host cost this lane would stand nowhere")
    # THE THREE NUMBERS ARE LITERALS THAT FIT THE CEILING.
    want = literal(lane_text, "IDLE_S")
    bound = literal(lane_text, "IDLE_BOUND_S")
    budget = literal(lane_text, "IDLE_BUDGET_S")
    mm = re.search(r'^\s*"mac": (\d+),', texts["tools/validate-all.py"], re.M)
    ceiling = int(mm.group(1)) if mm else 0
    if want is None or bound is None or budget is None:
        out.append(f"{MAC_LANE}: IDLE_S / IDLE_BOUND_S / IDLE_BUDGET_S are not all "
                   f"module-level number literals — a bound read from somewhere else is "
                   f"a bound nobody can check against the lane's ceiling")
    elif not ceiling:
        out.append("tools/validate-all.py: BUDGETS names no mac ceiling to size the "
                   "idle wait against")
    else:
        if want >= bound:
            out.append(f"{MAC_LANE}: IDLE_S {want:.0f}s is not under IDLE_BOUND_S "
                       f"{bound:.0f}s — a bound shorter than the threshold can never "
                       f"clear, so every wait is the whole bound")
        if bound > budget:
            out.append(f"{MAC_LANE}: IDLE_BOUND_S {bound:.0f}s is over IDLE_BUDGET_S "
                       f"{budget:.0f}s — one leg would outspend the lane")
        if budget * 2 > ceiling:
            out.append(f"{MAC_LANE}: IDLE_BUDGET_S {budget:.0f}s is over half the mac "
                       f"lane's {ceiling}s ceiling — a lane may not spend that much of "
                       f"its budget waiting for a human, and a duration anomaly then "
                       f"names the wait instead of the code")
    # THE SENTENCES SAY WHAT THEY MEASURED.
    wait_body = py_function(lane_text, "idle_wait")
    summary_body = py_function(lane_text, "idle_summary")
    for key, phrases in IDLE_SAYS.items():
        where = summary_body if key == "summary" else wait_body
        if f'IDLE_SENTENCES["{key}"]' not in where:
            out.append(f"{MAC_LANE}: {'idle_summary' if key == 'summary' else 'idle_wait'} "
                       f"never prints IDLE_SENTENCES[{key!r}] — a branch that says nothing "
                       f"is a state nobody can read")
        text = getattr(mod, "IDLE_SENTENCES", {}).get(key, "")
        for phrase in phrases:
            if phrase not in text:
                out.append(f"{MAC_LANE}: IDLE_SENTENCES[{key!r}] no longer says "
                           f"{phrase!r} — {text!r}")
    # THE SELF-TEST DOOR HAS EXACTLY ONE READER.
    door = getattr(mod, "IDLE_DOOR", "")
    if not door:
        out.append(f"{MAC_LANE}: no IDLE_DOOR — the wait's self-test door is unnamed")
    else:
        # The door's whole span: its own line, _hid_idle_ns() and idle_wait().
        # Neither the value nor the name may be spelled outside it.
        at = lane_text.find("IDLE_DOOR = ")
        end = lane_text.find("\ndef idle_summary(")
        off = 0
        for line_no, line in enumerate(lane_text.splitlines(), 1):
            inside = at >= 0 and end > at and at <= off < end
            if not inside and (door in line or "IDLE_DOOR" in line):
                out.append(f"{MAC_LANE}:{line_no}: names the idle wait's self-test door "
                           f"outside it — one reader, or a doctored run reads as a real "
                           f"one")
            off += len(line) + 1
        for rel, text in sorted(tools.items()):
            if rel == MAC_LANE or door not in text:
                continue
            out.append(f"{rel}: reads {door}, the mac idle wait's self-test door — a "
                       f"door with a second reader is no longer a door, and a doctored "
                       f"run would read as a real one")
    # A RED MAC LEG NAMES THE FRONTMOST APP, AT THE MOMENT OF THE RED.
    if "flightrec_lane.mac_frontmost(ROOT)" not in py_function(runner, "_leg_worker"):
        out.append(f"{MAC_RUNNER}: _leg_worker does not read "
                   f"flightrec_lane.mac_frontmost(ROOT) on a red — read at drain time "
                   f"instead, the pool has finished and the foreground has moved on")
    if '.front"' not in py_function(runner, "drain"):
        out.append(f"{MAC_RUNNER}: drain() does not put the frontmost reading on the "
                   f"leg's verdict line — the read would be one bundle away again "
                   f"(docs/deferred.md, the swallowed-press entry)")
    if "def mac_frontmost(" not in texts["tools/lib/flightrec_lane.py"]:
        out.append("tools/lib/flightrec_lane.py: no module-level mac_frontmost() — the "
                   "bundle's window census and the verdict line would read the window "
                   "list two ways")
    if "_mac.hid_idle_seconds()" not in texts["tools/validate-all.py"]:
        out.append("tools/validate-all.py: the launch line carries no HIDIdleTime — load "
                   "says how busy the machine is, never whether a human is at it")
    return out


def census(texts, lanes=None, tools=None):
    out = []
    lanes = lanes or {}
    # 1. THE FUNNELS ASK AND HOLD.
    for lane, runner, funnel, roster_rel in LANES:
        body = py_function(texts[runner], funnel)
        if not body:
            out.append(f"{runner}: no `def {funnel}(` to read — the funnel moved")
            continue
        if f'exclusive.wait("{lane}", name)' not in body:
            out.append(f"{runner}: {funnel} does not call exclusive.wait(\"{lane}\", name) — the "
                       f"lane starts legs while another holds the token")
        if f'exclusive.hold("{lane}", name)' not in body:
            out.append(f"{runner}: {funnel} never holds the token for the lane's exclusive legs")
        if 'os.environ.get("KAYA_EXCLUSIVE", "")' not in body:
            out.append(f"{runner}: {funnel} does not read KAYA_EXCLUSIVE — --exclusive and "
                       f"--no-exclusive would run everything on this lane")
        if "lane.EXCLUSIVE" not in body:
            out.append(f"{runner}: {funnel} does not read lane.EXCLUSIVE — the set is data nobody "
                f"uses")
        if "import exclusive" not in texts[runner]:
            out.append(f"{runner}: does not import exclusive")
        if f'exclusive.summary("{lane}")' not in texts[runner]:
            out.append(f"{runner}: never prints exclusion's summary — the wall cost of exclusion "
                       f"would "
                       f"stand nowhere beside the lane's duration")
        # 2. EVERY EXCLUSIVE NAME IS A LEG THE LANE RUNS.
        mod = lanes.get(lane)
        if mod is not None:
            known = roster(lane, mod)
            if len(known) < 10:
                out.append(f"{roster_rel}: the roster read {len(known)} legs — a reader that "
                           f"finds that few agrees with anything")
            for name in sorted(getattr(mod, "EXCLUSIVE", set())):
                if name not in known:
                    out.append(f"{roster_rel}: EXCLUSIVE names {name!r}, which no leg of this lane "
                               f"is "
                               f"called — an exclusive set naming nothing excludes nothing")
    # 3. THE LINUX HALF.
    sh = texts[LINUX]
    run_body = sh_function(sh, "run")
    for want in ('kaya_exclusive_wait linux "$name-$proto"',
                 'kaya_exclusive_hold_begin linux "$name-$proto"',
                 'kaya_exclusive_hold_end linux "$name-$proto"'):
        if want not in run_body:
            out.append(f"{LINUX}: run() lacks `{want}`")
    if ("source /work/tools/linux/exclusive.sh" not in sh
            or "kaya_exclusive_selftest linux" not in sh):
        out.append(f"{LINUX}: does not source tools/linux/exclusive.sh and run its self-test")
    if 'case "${KAYA_EXCLUSIVE:-}" in' not in run_body:
        out.append(f"{LINUX}: run() does not read KAYA_EXCLUSIVE")
    if "kaya_exclusive_summary linux" not in sh:
        out.append(f"{LINUX}: never prints exclusion's summary")
    m = re.search(r'^KAYA_EXCLUSIVE_LEGS="([^"]*)"', sh, re.M)
    if not m:
        out.append(f"{LINUX}: no KAYA_EXCLUSIVE_LEGS line")
    else:
        for name in m.group(1).split():
            stem, _, proto = name.rpartition("-")
            if proto not in ("x11", "wayland") or not re.search(
                    r'run "\$proto" ' + re.escape(stem) + r"\b", sh):
                out.append(f"{LINUX}: KAYA_EXCLUSIVE_LEGS names {name!r}, which no `run \"$proto\" "
                           f"{stem}` line runs")
    # 4. ONE SET OF SENTENCES.
    py = texts[EXCLUSIVE_PY]
    py_sentences = {}
    for key in SHARED:
        mm = re.search(r'^\s*"' + key + r'": "([^"]*)",', py, re.M)
        if mm:
            py_sentences[key] = flatten_py(mm.group(1))
        else:
            out.append(f"{EXCLUSIVE_PY}: SENTENCES lacks {key!r}")
    sh_sentences = {flatten_sh(s)
                    for s in re.findall(r'echo "(exclusive: [^"]*)"', texts[EXCLUSIVE_SH])}
    for key, flat in py_sentences.items():
        if flat not in sh_sentences:
            out.append(f"{EXCLUSIVE_SH}: does not say the python module's {key!r} sentence "
                       f"({flat!r}) — two spellings of one protocol")
    # 5. A NOTIFICATION LEG NEVER RUNS IN THE POOL AN EXCLUSIVE FUNNEL
    # DRAINS. The windows funnel JOINS every leg started before the
    # exclusive one in its block, and the block before it has just drained
    # — so a notification delivered there is in flight exactly when the
    # typing leg foregrounds, and the shell's notification host window
    # comes up ~2s later holding the foreground with nothing in it
    # (docs/deferred.md, the phantom notification window).
    win = lanes.get("windows")
    if win is not None:
        notify_legs = win.notification_legs(str(ROOT / "tools/scenes"))
        if not notify_legs:
            out.append("tools/lib/lanes/win.py: notification_legs read no leg at all — a census "
                       "that finds none agrees with every order")
        blame = ("the exclusive funnel joins it, so its toast is in flight when {leg} "
                 "foregrounds to type, and the shell's notification host window comes up ~2s "
                 "later holding the foreground with nothing in it for 30s "
                 "(docs/deferred.md, the phantom notification window). Move the notification "
                 "leg after the exclusive one")
        for at, block in enumerate(win.ORDER):
            for i, leg in enumerate(block):
                if leg not in win.EXCLUSIVE:
                    continue
                for name in [n for n in block[:i] if n in notify_legs]:
                    out.append(f"tools/lib/lanes/win.py: {name!r} is pooled before the exclusive "
                               f"leg {leg!r} in the same block — "
                               + blame.format(leg=leg))
                if i:
                    continue
                for name in [n for n in win.ORDER[at - 1] if n in notify_legs] if at else []:
                    out.append(f"tools/lib/lanes/win.py: {name!r} ends the block before the one "
                               f"{leg!r} opens — the drain between blocks joins it and "
                               + blame.format(leg=leg))
    # 6. THE COORDINATOR HANDS THE DIRECTORY; THE SWEEP YIELDS.
    if 'os.environ["KAYA_EXCLUSIVE_DIR"] = ' not in texts["tools/validate-all.py"]:
        out.append("tools/validate-all.py: never sets KAYA_EXCLUSIVE_DIR — the lanes cannot share "
                   "a token")
    if "KAYA_EXCLUSIVE_DIR=/flightrec-state/kaya/exclusive" not in texts["tools/validate-linux.py"]:
        out.append("tools/validate-linux.py: does not tell the container where the token lives")
    if 'exclusive.wait("gates", name)' not in texts["tools/gates.py"]:
        out.append("tools/gates.py: the sweep does not yield to a held token")
    # 7. THE MAC FUNNEL WAITS FOR AN IDLE HOST.
    mac_mod = lanes.get("mac")
    if mac_mod is not None:
        out += mac_idle(texts, mac_mod, TOOLS if tools is None else tools)
    return out


FILES = [r for _, r, _, _ in LANES] + [LINUX, EXCLUSIVE_PY, EXCLUSIVE_SH, "tools/validate-all.py",
                                        "tools/validate-linux.py", "tools/gates.py",
                                        "tools/lib/flightrec_lane.py", MAC_LANE]
REAL = {rel: gate.read(rel) for rel in FILES}
MODS = {lane: load_lane(r) for lane, _, _, r in LANES}

# EVERY RUNNER AND GATE IN tools/, for the door's one-reader clause: a
# self-test door read by a second script is a knob, and a doctored run
# would then read as a real one.
TOOLS = {str(p.relative_to(ROOT)): p.read_text(encoding="utf-8", errors="replace")
         for p in gate.walk("*.py", "*.sh", "*.ps1", under="tools")}


def watched(label, texts, want, lanes=None, tools=None):
    gate.negative(label,
                  lambda: census(texts, lanes if lanes is not None else MODS, tools),
                  want=want)


# 1. A RUNNER STOPS ASKING.
no_wait = gate.doctor("the ios wait cut out", REAL["tools/ios/run-sim.py"],
                      r'\n\s*exclusive\.wait\("ios", name\)\n', "\n")
watched("an iOS funnel that starts legs under a held token",
        {**REAL, "tools/ios/run-sim.py": no_wait}, 'exclusive.wait("ios", name)')

# 2. A RUNNER STOPS HOLDING.
no_hold = gate.doctor("the android hold renamed", REAL["tools/android/run-emulator.py"],
                      r'with exclusive\.hold\("android", name\):',
                      'with exclusive.hold("droid", name):')
watched("an android funnel that never holds",
        {**REAL, "tools/android/run-emulator.py": no_hold}, "never holds the token")

# 3. AN EXCLUSIVE NAME NOTHING RUNS.
class Ghost:
    pass
ghost = Ghost()
for attr in ("LEGS",):
    setattr(ghost, attr, MODS["android"].LEGS)
ghost.EXCLUSIVE = MODS["android"].EXCLUSIVE | {"dnd-ghost"}
watched("an android EXCLUSIVE name no leg is called", REAL, "dnd-ghost",
        lanes={**MODS, "android": ghost})

# 4. THE LINUX FUNNEL STOPS HOLDING.
sh_no_hold = gate.doctor("the linux hold_begin cut out", REAL[LINUX],
                         r'\n\s*kaya_exclusive_hold_begin linux "\$name-\$proto"\n', "\n")
watched("a linux run() that never holds", {**REAL, LINUX: sh_no_hold}, "kaya_exclusive_hold_begin")

# 5. THE SHELL DRIFTS FROM THE PYTHON SENTENCE.
sh_drift = gate.doctor("the shell release sentence reworded", REAL[EXCLUSIVE_SH],
                       r'echo "exclusive: \$lane released after \$leg',
                       'echo "exclusive: $lane let go after $leg')
watched("a shell sentence the python module does not say", {**REAL, EXCLUSIVE_SH: sh_drift},
        "does not say the python module's 'released'")

# 6. THE COORDINATOR FORGETS THE DIRECTORY.
no_dir = gate.doctor("validate-all's KAYA_EXCLUSIVE_DIR line cut", REAL["tools/validate-all.py"],
                     r'os\.environ\["KAYA_EXCLUSIVE_DIR"\] = str\(EXCLUSIVE_DIR\)\n', "\n")
watched("a matrix whose lanes share no token", {**REAL, "tools/validate-all.py": no_dir},
        "never sets KAYA_EXCLUSIVE_DIR")

# 7. A LANE STOPS SAYING WHAT EXCLUSION COST IT.
no_summary = gate.doctor("the mac summary cut out", REAL["tools/validate-mac.py"],
                         r'\n\s*exclusive\.summary\("mac"\)\n', "\n")
watched("a mac lane with no exclusion summary", {**REAL, "tools/validate-mac.py": no_summary},
        "never prints exclusion's summary")

# 8. A RUNNER STOPS READING THE MODE.
no_mode = gate.doctor("the windows mode read cut out", REAL["tools/deploy-win.py"],
                      r'mode = os\.environ\.get\("KAYA_EXCLUSIVE", ""\)',
                      'mode = ""')
watched("a windows funnel that ignores --exclusive", {**REAL, "tools/deploy-win.py": no_mode},
        "does not read KAYA_EXCLUSIVE")

# 9. A NOTIFICATION LEG BACK IN THE POOL THE EXCLUSIVE FUNNEL DRAINS —
# the roster as it stood before the phantom slice, one leg moved. A DATA
# perturbation, so the copy is a doctored win.py loaded as a module.
WIN_LANE = "tools/lib/lanes/win.py"
_moved = gate.doctor("the windows notify leg lifted out from after notes_rust",
                     gate.read(WIN_LANE),
                     r'\n     # The notification conformance scene[\s\S]*?\n     "notify_rust",\n',
                     "\n")
_moved = gate.doctor("the windows notify leg put back before notes_rust", _moved,
                     r'\n     "richrows_rust",\n',
                     '\n     "richrows_rust",\n     "notify_rust",\n')
_ghost_win = gate.scratch() / "win-notify-before-notes.py"
_ghost_win.write_text(_moved, encoding="utf-8")
watched("a windows pool whose notification leg the exclusive funnel drains", REAL,
        "is pooled before the exclusive leg 'notes_rust'",
        lanes={**MODS, "windows": load_lane(_ghost_win)})

# 10. THE MAC WAIT CUT OUT — the state the tree was in until 2026-09-18.
_no_idle = gate.doctor("the mac idle wait cut from queue_leg", REAL[MAC_RUNNER],
                       r"\n *# AND THE HOST'S OWN IDLE CLOCK[\s\S]*?\n *lane\.idle_wait\(name\)\n",
                       "\n")
watched("a mac funnel that admits an input-driving leg without asking about the human",
        {**REAL, MAC_RUNNER: _no_idle}, "never calls lane.idle_wait(name)")

# 11. THE WAIT MOVED OUT OF THE HOLD — it would then wait while the other
# four lanes are free to admit their own input-driving legs.
_outside = gate.doctor("the mac idle wait lifted above the hold", REAL[MAC_RUNNER],
                       r'( *)(with exclusive\.hold\("mac", name\):)',
                       r"\1lane.idle_wait(name)\n\1\2")
_outside = gate.doctor("the mac idle wait removed from inside the hold", _outside,
                       r"\n *# AND THE HOST'S OWN IDLE CLOCK[\s\S]*?\n *lane\.idle_wait\(name\)\n",
                       "\n")
watched("a mac idle wait outside the token's hold",
        {**REAL, MAC_RUNNER: _outside}, "is not between the token's hold and the leg")

# 12. A BUDGET THE CEILING CANNOT PAY.
_fat = gate.doctor("the mac idle budget raised past half the ceiling", REAL[MAC_LANE],
                   r"^IDLE_BUDGET_S = \d+(?:\.\d+)?$", "IDLE_BUDGET_S = 900.0", flags=re.M)
_fat_mod = gate.scratch() / "mac-fat-budget.py"
_fat_mod.write_text(_fat, encoding="utf-8")
watched("a mac idle budget over half the lane's ceiling", {**REAL, MAC_LANE: _fat},
        "over half the mac lane's", lanes={**MODS, "mac": load_lane(_fat_mod)})

# 13. THE EXPIRY STOPS SAYING THE LEG RUNS ANYWAY — a reader would then
# take the sentence for a refusal and hunt the tree for the red's cause.
_quiet = gate.doctor("the mac expiry sentence's promise reworded", REAL[MAC_LANE],
                     '— running it anyway, so "\n *"a red here is the host\'s',
                     "— giving up")
_quiet_mod = gate.scratch() / "mac-quiet-expiry.py"
_quiet_mod.write_text(_quiet, encoding="utf-8")
watched("a mac expiry sentence that stopped saying the leg runs", {**REAL, MAC_LANE: _quiet},
        "no longer says 'running it anyway'", lanes={**MODS, "mac": load_lane(_quiet_mod)})

# 14. A SECOND READER OF THE SELF-TEST DOOR.
_knob = {**TOOLS, "tools/validate-mac.py": TOOLS["tools/validate-mac.py"]
         + '\nif os.environ.get("KAYA_HID_IDLE_NS_OVERRIDE", ""):\n    pass\n'}
watched("a self-test door with a second reader", REAL,
        "the mac idle wait's self-test door", tools=_knob)

# 15. A RED MAC LEG THAT NAMES NOBODY.
_blind = gate.doctor(
    "the mac frontmost read cut from _leg_worker", REAL[MAC_RUNNER],
    r'\n *if verdict != "PASS":\n[\s\S]*?'
    r'flightrec_lane\.mac_frontmost\(ROOT\) \+ "\\n", encoding="utf-8"\)\n',
    "\n")
watched("a red mac leg whose verdict line names no frontmost app",
        {**REAL, MAC_RUNNER: _blind}, "does not read flightrec_lane.mac_frontmost(ROOT)")

gate.negatives_ran(15)

gate.counted("windows legs whose scene posts a notification",
             sorted(MODS["windows"].notification_legs(str(ROOT / "tools/scenes"))), floor=2)
gate.counted("tools/ scripts read for the idle wait's self-test door",
             sorted(TOOLS), floor=60)

for line in census(REAL):
    gate.finding(line)

gate.verdict("every lane asks the token at its funnel and holds it for its exclusive legs")
