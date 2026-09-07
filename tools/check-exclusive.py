#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

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


def census(texts, lanes=None):
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
    # 5. THE COORDINATOR HANDS THE DIRECTORY; THE SWEEP YIELDS.
    if 'os.environ["KAYA_EXCLUSIVE_DIR"] = ' not in texts["tools/validate-all.py"]:
        out.append("tools/validate-all.py: never sets KAYA_EXCLUSIVE_DIR — the lanes cannot share "
                   "a token")
    if "KAYA_EXCLUSIVE_DIR=/flightrec-state/kaya/exclusive" not in texts["tools/validate-linux.py"]:
        out.append("tools/validate-linux.py: does not tell the container where the token lives")
    if 'exclusive.wait("gates", name)' not in texts["tools/gates.py"]:
        out.append("tools/gates.py: the sweep does not yield to a held token")
    return out


FILES = [r for _, r, _, _ in LANES] + [LINUX, EXCLUSIVE_PY, EXCLUSIVE_SH, "tools/validate-all.py",
                                        "tools/validate-linux.py", "tools/gates.py"]
REAL = {rel: gate.read(rel) for rel in FILES}
MODS = {lane: load_lane(r) for lane, _, _, r in LANES}


def watched(label, texts, want, lanes=None):
    gate.negative(label, lambda: census(texts, lanes if lanes is not None else MODS), want=want)


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

gate.negatives_ran(8)

for line in census(REAL):
    gate.finding(line)

gate.verdict("every lane asks the token at its funnel and holds it for its exclusive legs")
