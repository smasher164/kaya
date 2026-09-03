#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()


# THE THREE LISTS OF GATES MUST BE ONE LIST: what tools/gates.py RUNS,
# what tools/validate-mac.py runs BY DELEGATION and not by copy, and
# what CLAUDE.md documents — rung 2, the list a session with no context
# reads and believes. Plus the CENSUS clause (every gate script ON DISK
# is in the list or in gates.py's EXCLUDED table WITH A REASON; nothing
# else in the tree can see a gate nobody runs) and the matrix launch
# (five lanes queued together, the niced sweep after Android exits, the
# runner and probe agreeing on the four-phone pool). CLAUDE.md alone,
# not AGENTS.md: check-mirror.py holds those two level.

import json
import re
import subprocess

root = ROOT

status = 0


def fail(msg):
    global status
    print(f"check-gates: {msg}", file=sys.stderr)
    status = 1


# A GATE'S SCRIPT PATH IS ITS NAME EVERYWHERE, so one pattern serves all
# three readers. The naming clause below FORCES every gate into a shape
# this pattern can see, or the prose scan goes quietly blind.
# Every gate is python but tools/swift-typecheck.sh, which stays shell
# (an in-toolchain launcher shape).
SHELL_GATE = (r"tools/(?:(?:check-[a-z0-9-]+|gen-(?:header|bindings|guests)"
              r"|java-typecheck|js-typecheck)\.py|swift-typecheck\.sh)")
PY_GATE = r"bindings/(?:python/[a-z0-9_]+\.py|js/[a-z0-9_]+\.ts)"
TOKEN = re.compile(f"{SHELL_GATE}|{PY_GATE}")


def rung2(text):
    """CLAUDE.md's fast-gate block. Anchored on the ladder's numbering,
    and a moved anchor is a loud failure rather than an empty set — an
    empty set would agree with nothing and pass nothing, but it would
    also be the shape a vacuous scan takes."""
    try:
        start = text.index("2. Fast gates")
        end = text.index("3. `tools/validate-mac.py`", start)
    except ValueError:
        return None
    return text[start:end]


def documented(block):
    return set(TOKEN.findall(block))


def script_of(cmd):
    """The gate script inside an argv — `tools/x.sh` or the .py an
    interpreter is pointed at."""
    for word in cmd:
        if TOKEN.fullmatch(word):
            return word
    return None


def drift(listed, doc):
    """The two directions of disagreement, in that order. Kept as one
    function because the message has to name BOTH lists: 'check-roles is
    missing' is useless without 'missing from WHICH'."""
    return sorted(set(listed) - set(doc)), sorted(set(doc) - set(listed))


def drift_lines(only_listed, only_doc):
    out = []
    if only_listed:
        out.append("in tools/gates.py's list (run or excluded) but NOT named in "
                   "CLAUDE.md rung 2: " + " ".join(only_listed))
    if only_doc:
        out.append("named in CLAUDE.md rung 2 but NOT in tools/gates.py's list: "
                   + " ".join(only_doc))
    return out


def code_lines(text):
    """Shell lines that are not whole-line comments. A gate NAMED in a
    comment is a citation; a gate INVOKED is a second list."""
    return [ln for ln in text.splitlines() if not ln.strip().startswith("#")]


def direct_invocations(text):
    """Gate scripts validate-mac runs itself, plus any keyed.py call.
    Both are the same defect: a second place that decides what the
    sweep is."""
    hits = set()
    for line in code_lines(text):
        hits.update(TOKEN.findall(line))
        if re.search(r"(?:^|[\s;&|(])tools/keyed\.py\b", line):
            hits.add("tools/keyed.py")
    return hits


def census(on_disk, listed, excluded):
    """Gate scripts that exist and are in neither list."""
    return sorted(set(on_disk) - set(listed) - set(excluded))


# The matrix driver's exact launch spellings (the linux launch spans two
# lines — its env rider — and is matched as a prefix).
PLATFORM_LAUNCHES = [
    'run_lane("mac", ["tools/validate-mac.py"])',
    'run_lane("linux", ["tools/validate-linux.py"],',
    'run_lane("windows", ["tools/deploy-win.py", HOST, "all"])',
    'run_lane("ios", ["tools/ios/run-sim.py"])',
    'run_lane("android", ["tools/android/run-emulator.py"])',
]
GATE_LAUNCH = 'run_lane("gates", ["nice", "-n", "10", "tools/gates.py"])'
ANDROID_PID = "android_lane_proc = lane_procs[-1]"
ANDROID_WAIT = "android_lane_proc.wait()"
# The runners are python and the probe is shell, so each default is
# spelled in two languages; these clauses hold BOTH.
ANDROID_RUNNER_POOL = 'POOL = int(os.environ.get("KAYA_ANDROID_EMUS", "4"))'
ANDROID_PROBE_POOL = 'ANDROID_POOL="${KAYA_ANDROID_EMUS:-4}"'
IOS_RUNNER_POOL = 'POOL = int(os.environ.get("KAYA_IOS_SIMS", "3"))'
IOS_PROBE_POOL = 'IOS_POOL="${KAYA_IOS_SIMS:-3}"'


def matrix_parallel_problem(text):
    parallel = re.search(
        r'(?ms)^if MODE == "parallel":\n(.*?)^else:$', text)
    if parallel is None:
        return "tools/validate-all.py's parallel matrix block is missing"
    lines = [line.strip() for line in code_lines(parallel.group(1))
             if line.strip()]
    launches = [line for line in lines if line.startswith("run_lane(")]
    if len(launches) != 6 or launches[5] != GATE_LAUNCH or any(
            not launches[i].startswith(PLATFORM_LAUNCHES[i])
            for i in range(5)):
        return ("tools/validate-all.py must queue all five platform lanes and "
                "the one niced gate sweep exactly once")
    start = next(i for i, line in enumerate(lines)
                 if line.startswith(PLATFORM_LAUNCHES[0]))
    # The five platform launches must be CONSECUTIVE statements — the
    # linux launch's env rider spans two extra lines, and nothing else
    # may sit between them (an admission barrier would).
    at = start
    for want in PLATFORM_LAUNCHES:
        if not lines[at].startswith(want):
            return ("tools/validate-all.py must queue all five platform lanes "
                    "together without an admission barrier between them")
        at += 1
        while at < len(lines) and not lines[at].startswith("run_lane(") \
                and lines[at].startswith(('"', "'", "env=")):
            at += 1
    tail = lines[at:at + 3]
    if tail != [ANDROID_PID, ANDROID_WAIT, GATE_LAUNCH]:
        return ("tools/validate-all.py must record Android's exact lane "
                "process, wait for it, then start the one gate sweep at "
                "niceness 10")
    run_lane = re.search(r"(?ms)^def run_lane\(.*?(?=^[A-Za-z_#])", text)
    if run_lane is None or not all(part in run_lane.group(0) for part in (
        "subprocess.Popen(argv, env=lane_env, stdout=lf, stderr=lf)",
        "lane_procs.append(proc)", "lane_names.append(name)")):
        return ("tools/validate-all.py's run_lane no longer backgrounds and "
                "records every concurrent matrix unit")
    gate_lines = [line for line in lines if "tools/gates.py" in line]
    # The build LEADS the fingerprint: the keyed keys carry the
    # artifacts' real bytes, and a token over the previous build's
    # made the mac lane sweep twice (docs/traps.md, 2026-09-01).
    build = 'if subprocess.run(["tools/gates.py", "--build"]).returncode != 0:'
    fingerprint = 'got = subprocess.run(["tools/gates.py", "--fingerprint"],'
    if gate_lines != [build, fingerprint, GATE_LAUNCH]:
        return ("tools/validate-all.py must invoke gates only for the "
                "artifact build, the same-tree fingerprint taken after it, "
                "and the one delayed niced sweep")
    return None


def android_pool_problem(runner, probe):
    if runner.count(ANDROID_RUNNER_POOL) != 1:
        return ("tools/android/run-emulator.py must default to the guarded "
                "four-phone Android pool")
    if probe.count(ANDROID_PROBE_POOL) != 1:
        return ("tools/probe-env.sh must probe the same guarded four-phone "
                "Android pool the runner uses")
    return None


# The probe defaulted to 2 sims against the runner's 3 for five weeks —
# the exact drift the Android clause guards, unguarded one platform over.
def ios_pool_problem(runner, probe):
    if runner.count(IOS_RUNNER_POOL) != 1:
        return ("tools/ios/run-sim.py must default to the three-simulator "
                "iOS pool")
    if probe.count(IOS_PROBE_POOL) != 1:
        return ("tools/probe-env.sh must probe the same three-simulator "
                "iOS pool the runner uses")
    return None


# The five platform runners, by the two things a lane owes a reader who
# was not watching: the ANSWER, and the EVIDENCE.
LANE_RUNNERS = {
    "tools/validate-mac.py": ("validate-mac", "mac"),
    "tools/ios/run-sim.py": ("run-sim", "ios"),
    "tools/linux/run-suites.sh": ("run-suites", "linux"),
    "tools/android/run-emulator.py": ("run-emulator", "android"),
    "tools/deploy-win.py": ("deploy-win", "windows"),
}

# A python runner records through tools/lib/flightrec_lane.py rather
# than the sourced shell library: the lane's recorder CLASS declares its
# lane name once, in its constructor, and every journaled leg rides it.
PY_RECORDERS = {"windows": "WinRecorder", "ios": "IosRecorder",
                "android": "AndroidRecorder", "mac": "MacRecorder"}


def lane_contract_problems(texts, lib, pylib):
    """A lane must END WITH THE ANSWER and KEEP ITS EVIDENCE.

    Both were measured missing. Three runners ended with a bare
    `exit "$status"`, so a log that stopped early — a killed lane, a lost
    pipe — read exactly like a complete one; an ios run that reached no
    leg at all was read as a pass twice on 2026-08-29. And the flight
    recorder was wired into two runners of five, with the lane that had
    the intermittent legs among the three without it, so every rerun
    erased the only evidence (tools/lib/flightrec.sh's own header).
    """
    problems = []
    for rel, (name, lane) in LANE_RUNNERS.items():
        text = texts[rel]
        is_py = rel.endswith(".py")
        verdicts = ((f'print("{name}: ALL PASS")',
                     f'print("{name}: FAILURES ABOVE")') if is_py else
                    (f'echo "{name}: ALL PASS"',
                     f'echo "{name}: FAILURES ABOVE"'))
        for want in verdicts:
            if want not in text:
                problems.append(
                    f"{rel} never prints {want} — a lane that ends without "
                    f"its verdict cannot be told from one that was cut off, "
                    f"and a truncated log then reads as a pass")
        if is_py:
            # The recorder opens with the lane's own class, and that
            # class binds the lane name in its constructor — so a
            # journaled leg cannot ride another lane's name.
            cls = PY_RECORDERS.get(lane)
            if cls is None or f"flightrec_lane.{cls}(" not in text:
                problems.append(
                    f"{rel} does not construct flightrec_lane.{cls} — a leg "
                    f"that fails once and passes on the rerun would leave "
                    f"nothing behind, which is what the flight recorder "
                    f"exists to stop")
                continue
            block = re.search(
                rf"^class {cls}\(LaneRecorder\):(.*?)(?=^class |\Z)",
                pylib, re.S | re.M)
            journals = (block is not None
                        and f'super().__init__("{lane}"' in block.group(1)
                        and re.search(r"\.\w+_leg\(", text))
            if not journals:
                problems.append(
                    f"{rel} opens a flight-recorder run but journals no leg "
                    f"under lane `{lane}` — {cls} in "
                    f"tools/lib/flightrec_lane.py does not bind that lane, "
                    f"or the runner never calls its per-leg entry, and an "
                    f"empty journal is the same silence with more moving "
                    f"parts")
            continue
        if f"flightrec_start {lane}" not in text:
            problems.append(
                f"{rel} does not call `flightrec_start {lane}` — a leg that "
                f"fails once and passes on the rerun would leave nothing "
                f"behind, which is what tools/lib/flightrec.sh exists to stop")
        # DIRECTLY, or through a lane wrapper in the library that
        # journals under this lane's name — validate-mac calls
        # flightrec_mac_leg, which reaches flightrec_leg inside
        # tools/lib/flightrec.sh.
        journals = f"flightrec_leg {lane} " in text
        if not journals:
            for wrapper in re.findall(r"\bflightrec_\w*_leg\b", text):
                body = re.search(rf"^{wrapper}\(\) \{{(.*?)^\}}", lib,
                                 re.S | re.M)
                if body and f"flightrec_leg {lane} " in body.group(1):
                    journals = True
                    break
        if not journals:
            problems.append(
                f"{rel} opens a flight-recorder run but journals no leg under "
                f"lane `{lane}` — neither directly nor through a wrapper in "
                f"tools/lib/flightrec.sh, and an empty journal is the same "
                f"silence with more moving parts")
    return problems


# ---------------------------------------------------------------- data

out = subprocess.run([str(root / "tools" / "gates.py"), "--list"],
                     cwd=root, stdout=subprocess.PIPE, text=True, check=False)
if out.returncode != 0:
    print("check-gates: tools/gates.py --list failed — the list is unreadable, "
          "so nothing below could be checked", file=sys.stderr)
    sys.exit(1)
listing = json.loads(out.stdout)
GATES = listing["gates"]
EXCLUDED = listing["excluded"]

claude_text = (root / "CLAUDE.md").read_text(encoding="utf-8")
mac_text = (root / "tools" / "validate-mac.py").read_text(encoding="utf-8")
lane_texts = {rel: (root / rel).read_text(encoding="utf-8")
              for rel in LANE_RUNNERS}
flightrec_lib_text = (root / "tools" / "lib" / "flightrec.sh").read_text(
    encoding="utf-8")
flightrec_pylib_text = (root / "tools" / "lib" / "flightrec_lane.py"
                        ).read_text(encoding="utf-8")
matrix_text = (root / "tools" / "validate-all.py").read_text(encoding="utf-8")
android_text = (root / "tools" / "android" / "run-emulator.py").read_text(
    encoding="utf-8")
ios_text = (root / "tools" / "ios" / "run-sim.py").read_text(encoding="utf-8")
probe_text = (root / "tools" / "probe-env.sh").read_text(encoding="utf-8")
block = rung2(claude_text)
if block is None:
    print("check-gates: could not find CLAUDE.md's rung-2 block (the anchors "
          "'2. Fast gates' and '3. `tools/validate-mac.py`' moved). Fix the "
          "anchors here or the ladder there — do not let this gate go quiet.",
          file=sys.stderr)
    sys.exit(1)

on_disk = sorted(
    f"tools/{p.name}"
    for p in list((root / "tools").glob("*.py")) + list((root / "tools").glob("*.sh"))
    if re.fullmatch(SHELL_GATE, f"tools/{p.name}")
)

# --------------------------------------------------- 0. the self-tests
#
# A set comparison that parsed nothing agrees with everything, so each
# clause is watched failing FIRST against the real bytes of the real
# files, doctored in memory, with the substitution count printed. Zero
# substitutions is a FAILED self-test (docs/traps.md).

listed_scripts = [script_of(g["cmd"]) for g in GATES]
if None in listed_scripts:
    for g in GATES:
        if script_of(g["cmd"]) is None:
            fail(f"gate {g['name']!r} runs {' '.join(g['cmd'])}, which names no "
                 f"gate-shaped script. Every gate must be spelled so the prose "
                 f"scan can see it (tools/check-*.py, tools/gen-*.py, "
                 f"tools/*-typecheck.py, tools/swift-typecheck.sh, or "
                 f"bindings/python/*.py) — or teach "
                 f"this gate's TOKEN the new shape, deliberately.")
    print("check-gates: FINDINGS ABOVE", file=sys.stderr)
    sys.exit(1)

# CLAUDE.md documents the EXCLUDED gates too, so the prose is compared
# against run-plus-excluded: otherwise rung 2 would be the one list
# allowed to forget a gate.
known = listed_scripts + sorted(EXCLUDED)
doc_names = documented(block)
shared = sorted(set(known) & doc_names)
if not shared:
    fail("self-test impossible: the list and CLAUDE.md have NO gate in common, "
         "so the scan below is measuring nothing")
else:
    victim = shared[0]
    # N1 — a gate dropped from the PROSE must be reported, naming both
    # lists. Applied to CLAUDE.md's real bytes.
    doctored, n = re.subn(re.escape(victim), "tools/check-REMOVED-BY-SELFTEST.sh", block)
    print(f"check-gates: self-test N1 removed {victim} from CLAUDE.md's rung-2 "
          f"block, {n} substitution(s)")
    if n < 1:
        fail(f"self-test N1 applied NO substitution — {victim} is not in the "
             f"block as written, so the prose scan is not reading what it thinks")
    else:
        only_listed, only_doc = drift(known, documented(doctored))
        if victim not in only_listed:
            fail(f"self-test N1: {victim} was deleted from the prose and the "
                 f"comparison did not report it — the prose scan is vacuous")
        lines = drift_lines(only_listed, only_doc)
        if not any("CLAUDE.md" in ln and "gates.py" in ln for ln in lines):
            fail("self-test N1: the drift message does not name both lists")

    # N2 — the other side: a gate dropped from the EXECUTABLE list must
    # be reported as documented-but-not-run.
    shrunk = [s for s in known if s != victim]
    print(f"check-gates: self-test N2 removed {victim} from the executable "
          f"list, {len(known) - len(shrunk)} entr(y|ies)")
    if len(shrunk) == len(known):
        fail("self-test N2 removed nothing — the executable list is not what "
             "this scan is reading")
    else:
        only_listed, only_doc = drift(shrunk, doc_names)
        if victim not in only_doc:
            fail(f"self-test N2: {victim} was dropped from the list and the "
                 f"comparison did not report it")

# N3 — a gate invoked DIRECTLY by validate-mac must be reported. The
# perturbation plants one into validate-mac.py's real text (the python
# spelling: an argv naming the gate's path).
planted, n = re.subn(
    r'(?m)^(\s*)if run\(\[str\(ROOT / "tools/gates\.py"\)\]\)',
    '\\1run([str(ROOT / "tools/check-mirror.py")])\n'
    '\\1if run([str(ROOT / "tools/gates.py")])', mac_text)
print(f"check-gates: self-test N3 planted a direct gate call in "
      f"validate-mac.py, {n} substitution(s)")
if n < 1:
    fail("self-test N3 applied NO substitution — validate-mac.py does not "
         "invoke tools/gates.py where this clause looks, so the delegation "
         "clause below is measuring nothing")
elif "tools/check-mirror.py" not in direct_invocations(planted):
    fail("self-test N3: a planted direct gate call was not seen — the "
         "delegation clause is vacuous")

# N4 — a gate script on disk that is in neither list must be reported.
if not census(on_disk + ["tools/check-invented-by-selftest.sh"],
              listed_scripts, EXCLUDED):
    fail("self-test N4: a gate script in neither list was not reported — the "
         "census clause is vacuous")

# N5 — every one of the five platform lanes must be queued.
doctored, n = re.subn(
    r'(?m)^    run_lane\("ios", \["tools/ios/run-sim\.py"\]\)\n', "",
    matrix_text, count=1)
print("check-gates: self-test N5 removed one concurrent platform launch, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N5 did not remove exactly one iOS launch — the concurrent "
         "matrix clause is not reading the real block")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N5: a matrix with only four platform lanes passed")

# N6 — no barrier may split the five platform launches.
doctored, n = re.subn(
    r'(?m)^(    run_lane\("mac", \["tools/validate-mac\.py"\]\))$',
    "\\1\n    lane_procs[-1].wait()", matrix_text, count=1)
print("check-gates: self-test N6 inserted a barrier after the mac launch, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N6 did not insert exactly one barrier — the concurrent "
         "matrix clause is not reading the real launch sequence")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N6: staged platform admission passed as concurrent")

# N7 — run_lane must keep every queued unit in the background.
doctored, n = re.subn(
    r"subprocess\.Popen\(argv, env=lane_env, stdout=lf, stderr=lf\)",
    "subprocess.run(argv, env=lane_env, stdout=lf, stderr=lf)",
    matrix_text, count=1)
print("check-gates: self-test N7 foregrounded run_lane, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N7 did not foreground exactly one run_lane body — the "
         "backgrounding clause is not reading the real function")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N7: a serial run_lane passed as concurrent")

# N8 — restoring the measured-red three-phone pool must be reported.
doctored, n = re.subn(
    re.escape(ANDROID_RUNNER_POOL),
    'POOL = int(os.environ.get("KAYA_ANDROID_EMUS", "3"))',
    android_text,
    count=1,
)
print("check-gates: self-test N8 restored the runner's three-phone pool, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N8 did not change exactly one Android runner default — "
         "the pool-width clause is not reading the real file")
else:
    problem = android_pool_problem(doctored, probe_text)
    if problem is None:
        fail("self-test N8: the measured-red three-phone runner passed")
    elif "four-phone Android pool" not in problem:
        fail("self-test N8 failed for another reason: " + problem)

# N9 — the environment probe must describe the topology the runner uses.
doctored, n = re.subn(
    re.escape(ANDROID_PROBE_POOL),
    'ANDROID_POOL="${KAYA_ANDROID_EMUS:-3}"',
    probe_text,
    count=1,
)
print("check-gates: self-test N9 restored the probe's three-phone pool, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N9 did not change exactly one Android probe default — "
         "the pool-width clause is not reading the real file")
else:
    problem = android_pool_problem(android_text, doctored)
    if problem is None:
        fail("self-test N9: a probe for the wrong Android pool passed")
    elif "same guarded four-phone" not in problem:
        fail("self-test N9 failed for another reason: " + problem)

# N10 — the delayed sweep must wait for the Android child this invocation
# recorded, not for an ambient process or a guessed slot.
doctored, n = re.subn(
    re.escape(ANDROID_PID), "android_lane_proc = lane_procs[0]",
    matrix_text, count=1)
print("check-gates: self-test N10 replaced Android pid provenance, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N10 did not replace exactly one Android pid capture — the "
         "provenance clause is not reading the real matrix")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N10: an unproven Android pid passed")

# N11 — starting the sweep immediately reintroduces the contention this
# schedule exists to bound.
doctored, n = re.subn(
    r"(?m)^    android_lane_proc\.wait\(\)\n", "", matrix_text, count=1)
print("check-gates: self-test N11 removed the Android wait, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N11 did not remove exactly one Android wait — the delayed "
         "sweep clause is not reading the real matrix")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N11: an immediate gate sweep passed as delayed")

# N12 — the sweep's lower priority is part of the measured schedule.
doctored, n = re.subn(
    re.escape('["nice", "-n", "10", "tools/gates.py"]'),
    '["tools/gates.py"]', matrix_text, count=1)
print("check-gates: self-test N12 removed gate niceness, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N12 did not remove exactly one nice invocation — the gate "
         "priority clause is not reading the real matrix")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N12: an ordinary-priority delayed sweep passed")

# N12b — a token taken over the previous build's artifacts is the
# duplicate mac sweep measured 2026-09-01.
doctored, n = re.subn(
    r'(?m)^    if subprocess\.run\(\["tools/gates\.py", "--build"\]\)'
    r'\.returncode != 0:\n        sys\.exit\(1\)\n', "", matrix_text,
    count=1)
print("check-gates: self-test N12b removed the pre-token build, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N12b did not remove exactly one pre-token build — the "
         "token clause is not reading the real matrix")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N12b: a token taken over stale artifacts passed")

# N13 — narrowing the iOS runner's pool must be reported.
doctored, n = re.subn(
    re.escape(IOS_RUNNER_POOL),
    'POOL = int(os.environ.get("KAYA_IOS_SIMS", "2"))',
    ios_text,
    count=1,
)
print("check-gates: self-test N13 narrowed the runner's sim pool to two, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N13 did not change exactly one iOS runner default — "
         "the sim-pool clause is not reading the real file")
else:
    problem = ios_pool_problem(doctored, probe_text)
    if problem is None:
        fail("self-test N13: a two-simulator runner passed")
    elif "three-simulator iOS pool" not in problem:
        fail("self-test N13 failed for another reason: " + problem)

# N14 — the probe describing a narrower sim pool than the runner uses is
# the measured five-week drift, and must be reported.
doctored, n = re.subn(
    re.escape(IOS_PROBE_POOL),
    'IOS_POOL="${KAYA_IOS_SIMS:-2}"',
    probe_text,
    count=1,
)
print("check-gates: self-test N14 restored the probe's two-sim default, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N14 did not change exactly one iOS probe default — "
         "the sim-pool clause is not reading the real file")
else:
    problem = ios_pool_problem(ios_text, doctored)
    if problem is None:
        fail("self-test N14: a probe for the wrong iOS pool passed")
    elif "same three-simulator" not in problem:
        fail("self-test N14 failed for another reason: " + problem)

# ------------------------------------------------------- 1. the clauses

only_listed, only_doc = drift(known, doc_names)
for line in drift_lines(only_listed, only_doc):
    fail(line)
if only_listed or only_doc:
    fail("the three lists must be one list — add the gate to tools/gates.py's "
         "GATES (or its EXCLUDED table, with a reason) and name it in rung 2 "
         "of BOTH CLAUDE.md and AGENTS.md")

for script in census(on_disk, listed_scripts, EXCLUDED):
    fail(f"{script} exists but is in no list — tools/gates.py neither runs it "
         f"nor excludes it, so nothing in this repo runs it and nothing says "
         f"why not")

for script, why in sorted(EXCLUDED.items()):
    if not (root / script).is_file():
        fail(f"{script} is excluded from the sweep but does not exist — delete "
             f"the exclusion")
    if len(why.strip()) < 20:
        fail(f"{script} is excluded with no real reason given ({why!r}); an "
             f"exclusion nobody justified is how four gates went unnamed")
    if script in listed_scripts:
        fail(f"{script} is both run and excluded")

direct = direct_invocations(mac_text)
if direct:
    fail("tools/validate-mac.py invokes gates itself: "
         + " ".join(sorted(direct))
         + " — the lane must DELEGATE to tools/gates.py, or the sweep has two "
           "lists again and the count in one of them means nothing")
# The delegation sits inside the matrix-handshake conditional
# (ratified 2026-08-20); the clause's real quarry is DIRECT gate
# invocations, held above, and the spelling is the argv path.
if not re.search(r'ROOT / "tools/gates\.py"', mac_text):
    fail("tools/validate-mac.py does not call tools/gates.py — the lane runs "
         "no gate sweep at all")

problem = matrix_parallel_problem(matrix_text)
if problem is not None:
    fail(problem)
problem = android_pool_problem(android_text, probe_text)
if problem is not None:
    fail(problem)
problem = ios_pool_problem(ios_text, probe_text)
if problem is not None:
    fail(problem)
for problem in lane_contract_problems(lane_texts, flightrec_lib_text,
                                      flightrec_pylib_text):
    fail(problem)

# N15 — a lane that stops printing its verdict must be reported. The
# measured shape: three of five runners ended with a bare `exit "$status"`
# and a truncated log read as a complete one.
doctored, n = re.subn(
    re.escape('print("run-sim: ALL PASS")'), 'pass', lane_texts["tools/ios/run-sim.py"],
    count=1)
print("check-gates: self-test N15 silenced a lane's verdict, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N15 did not remove exactly one verdict — the lane "
         "contract clause is not reading the real runner")
else:
    hurt = dict(lane_texts, **{"tools/ios/run-sim.py": doctored})
    problems = lane_contract_problems(hurt, flightrec_lib_text,
                                      flightrec_pylib_text)
    if not problems:
        fail("self-test N15: a lane that never prints its verdict passed")
    elif not any("ALL PASS" in x for x in problems):
        fail("self-test N15 failed for another reason: " + "; ".join(problems))

# N16 — a lane that keeps no evidence must be reported. The measured
# shape: the recorder was wired into two runners of five, and the lane
# with the intermittent legs was one of the three without it.
doctored, n = re.subn(
    r"^flightrec_start linux$", "true",
    lane_texts["tools/linux/run-suites.sh"], count=1, flags=re.M)
print("check-gates: self-test N16 unwired a lane's flight recorder, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N16 did not remove exactly one flightrec_start — the "
         "lane contract clause is not reading the real runner")
else:
    hurt = dict(lane_texts, **{"tools/linux/run-suites.sh": doctored})
    problems = lane_contract_problems(hurt, flightrec_lib_text,
                                      flightrec_pylib_text)
    if not problems:
        fail("self-test N16: a lane that records nothing passed")
    elif not any("flightrec_start" in x for x in problems):
        fail("self-test N16 failed for another reason: " + "; ".join(problems))

# N17 — THE WRAPPER PATH ITSELF. deploy-win journals through
# WinRecorder.win_leg rather than spelling a journal line itself, so the
# clause has to read the recorder class out of
# tools/lib/flightrec_lane.py; a pattern that never matches would call
# that lane uncovered — or, if every lane journaled directly, would pass
# while reading nothing. This doctors the LIBRARY, which is the only
# half N15/N16 never touch.
doctored, n = re.subn(
    r'super\(\).__init__\("windows"', 'super().__init__("ghostlane"',
    flightrec_pylib_text, count=1)
print("check-gates: self-test N17 renamed the windows recorder's lane, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N17 did not rename exactly one recorder lane — the "
         "lane contract clause is not reading tools/lib/flightrec_lane.py")
else:
    problems = lane_contract_problems(lane_texts, flightrec_lib_text,
                                      doctored)
    if not problems:
        fail("self-test N17: a lane whose only journal is a recorder bound "
             "to another lane passed")
    elif not any("deploy-win" in x and "journals no leg" in x
                 for x in problems):
        fail("self-test N17 failed for another reason: " + "; ".join(problems))

# The driver's own arithmetic: an under-run, a failing gate and a
# missing script must each come back red, watched on every run.
proof = subprocess.run([str(root / "tools" / "gates.py"), "--selftest"],
                       cwd=root, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, check=False)
if proof.returncode != 0:
    fail("tools/gates.py --selftest FAILED — the sweep's count does not refuse "
         "an under-run, so a sweep that ran nothing could print OK:\n"
         + proof.stdout)

if status == 0:
    print(f"check-gates: OK ({len(GATES)} gates in one list, "
          f"{len(EXCLUDED)} excluded with a reason, five concurrent platform lanes, "
          "delayed niced sweep, four-phone Android pool, three-sim iOS pool, "
          "five lanes each ending with their verdict and journaling every leg)")
else:
    print("check-gates: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)
