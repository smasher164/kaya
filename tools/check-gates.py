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
# (five lanes queued together, the niced sweep after Android and the mac
# lane exit, the runner and probe agreeing on the four-phone pool). CLAUDE.md alone,
# not AGENTS.md: check-mirror.py holds those two level.

import ast
import contextlib
import io
import json
import re
import shutil
import subprocess
import tempfile
import types

from lanes import mac as mac_lane

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
              r"|java-typecheck|js-typecheck|go-typecheck|py-typecheck)"
              r"\.py|swift-typecheck\.sh)")
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


def mac_sweep_problem(text):
    """A MATRIX SWEEPS ONCE, and it is never the mac lane's.

    validate-all runs the sweep itself after Android and the mac lane
    exit, over the same tree, so a second sweep inside the lane decides
    nothing — and under a plain matrix it cost 314s and 611s of
    `core-build+gates`, breaching the 1000s mac ceiling twice, because
    the token it compared against had been moved by the OTHER LANES'
    build-time writes rather than by any source edit (docs/deferred.md's
    mac-lane re-sweep entry, measured 2026-09-07). The lane still sweeps
    when it runs standalone, which is the branch with no token.
    """
    lines = text.splitlines()
    branch = next((i for i, line in enumerate(lines)
                   if line.strip() == "if _token:"), None)
    if branch is None:
        return ("tools/validate-mac.py has no `if _token:` branch — the "
                "matrix handshake moved, and with it the rule that a matrix "
                "sweeps once")
    # The SWEEP call, never the `--fingerprint` read of the same script
    # two lines above the branch (which is how this clause's own first
    # draft read 143 < 145 and agreed with everything).
    sweeps = [i for i, line in enumerate(lines)
              if 'ROOT / "tools/gates.py"' in line and "--fingerprint" not in line]
    if not sweeps:
        return None          # the delegation clause above owns that finding
    # The `else:` at column 0 that closes the matrix branch.
    closing = next((i for i, line in enumerate(lines)
                    if i > branch and line == "else:"), len(lines))
    inside = [i + 1 for i in sweeps if branch < i < closing]
    if inside:
        return ("tools/validate-mac.py runs tools/gates.py INSIDE its "
                f"`if _token:` branch (line {inside[0]}) — under a matrix "
                "that is a second sweep of a tree validate-all sweeps "
                "anyway, and it cost the mac ceiling twice "
                "(docs/deferred.md's mac-lane re-sweep entry)")
    if "skipped — validate-all sweeps this matrix" not in text:
        return ("tools/validate-mac.py no longer says it skipped because "
                "validate-all sweeps the matrix — the phases row is what "
                "makes this legible, and a silent skip reads as a lost gate")
    return None


def census(on_disk, listed, excluded):
    """Gate scripts that exist and are in neither list."""
    return sorted(set(on_disk) - set(listed) - set(excluded))


# The matrix driver's exact launch spellings (the linux and windows
# launches span two lines — their env riders — and are matched as prefixes).
PLATFORM_LAUNCHES = [
    'run_lane("mac", ["tools/validate-mac.py"])',
    'run_lane("linux", ["tools/validate-linux.py"],',
    'run_lane("windows", ["tools/deploy-win.py", HOST, "all"],',
    'run_lane("ios", ["tools/ios/run-sim.py"])',
    'run_lane("android", ["tools/android/run-emulator.py"])',
]
GATE_LAUNCH = 'run_lane("gates", ["nice", "-n", "10", "tools/gates.py"])'
ANDROID_PID = "android_lane_proc = lane_procs[-1]"
ANDROID_WAIT = "android_lane_proc.wait()"
MAC_PID = "mac_lane_proc = lane_procs[0]"
MAC_WAIT = "mac_lane_proc.wait()"
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
    # THE SWEEP WAITS FOR ANDROID, and is four wide (2026-09-07): at t0
    # beside the lanes it cost every lane 150-200s for a 116s gain
    # (matrix #24, docs/measurements/gate-sweep-2026-09-07.md).
    # AND FOR THE MAC LANE (2026-09-21): the mac guests load the host
    # libkaya by path and a gate's cargo build relinks it — seven legs died
    # in dyld under a sweep that overlapped a token-slowed mac lane
    # (docs/traps.md, the sweep-relinked-libkaya entry).
    tail = lines[at:at + 5]
    if tail != [ANDROID_PID, MAC_PID, ANDROID_WAIT, MAC_WAIT, GATE_LAUNCH]:
        return ("tools/validate-all.py must record Android's and the mac "
                "lane's exact lane processes, wait for both, then start the "
                "one gate sweep at niceness 10")
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
def wiring_method(pylib):
    """The MacRecorder method that launches a leg the way the recorder can
    read it: the one whose body holds BOTH the pool's `timeout 120`
    wrapper and the per-leg sampler. Read by name out of the library, so a
    rename moves both runners with it instead of going quiet."""
    lines = pylib.splitlines(keepends=True)
    for node in ast.walk(ast.parse(pylib)):
        if not isinstance(node, ast.ClassDef) or node.name != "MacRecorder":
            continue
        for fn in node.body:
            if not isinstance(fn, ast.FunctionDef):
                continue
            body = "".join(lines[fn.lineno - 1:fn.end_lineno])
            if '"timeout", "120"' in body and "sampler_start(" in body:
                return fn.name
    return None


def recorder_calls(text):
    """Every method called ON THE RECORDER a runner opened, or None when
    it opens none. Read off the variable a `MacRecorder(...)` was
    assigned to: a bare `.flush(` on any object would otherwise satisfy
    the clause while the journal never got the record."""
    tree = ast.parse(text)
    held = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) \
                or not isinstance(node.value, ast.Call):
            continue
        func = node.value.func
        if getattr(func, "attr", "") == "MacRecorder" \
                or getattr(func, "id", "") == "MacRecorder":
            held.update(t.id for t in node.targets
                        if isinstance(t, ast.Name))
    if not held:
        return None
    return {node.func.attr for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id in held}


def override_says_so(hand):
    """A hand run that takes its steps from KAYA_SELFTEST_SCRIPT must say
    it did: it would otherwise name a scene it never ran, which is the
    trap lanes.mac.leg_env's per-leg env exists for."""
    lines = hand.splitlines(keepends=True)
    for node in ast.walk(ast.parse(hand)):
        if not isinstance(node, ast.If):
            continue
        block = "".join(lines[node.lineno - 1:node.end_lineno])
        if 'env["KAYA_SELFTEST_SCRIPT"] =' in block and "print(" in block:
            return True
    return False


def lane_log_problems(text, report=False):
    functions = [node for node in ast.parse(text).body
                 if isinstance(node, ast.FunctionDef) and node.name == "keep_lane_log"]
    if len(functions) != 1:
        return [f"matrix: expected one keep_lane_log, read {len(functions)}"]
    code = compile(ast.Module(body=functions, type_ignores=[]),
                   "tools/validate-all.py keep_lane_log", "exec")
    problems = []
    for explicit in (False, True):
        for blocked in (None, "destination", "archive", "source"):
            with tempfile.TemporaryDirectory(prefix="kaya log check ") as scratch:
                base = pathlib.Path(scratch)
                source_dir = base / "scratch"
                source_dir.mkdir()
                payload = "current lane evidence\n"
                if blocked != "source":
                    (source_dir / "mac.log").write_text(payload, encoding="utf-8")
                default = base / "target/validate-failures"
                destination = base / "target/validate-lanes" if explicit else default
                archive = base / "target/validate-lanes/runs/test-run"
                if blocked in ("destination", "archive"):
                    obstacle = destination if blocked == "destination" else archive
                    obstacle.parent.mkdir(parents=True, exist_ok=True)
                    obstacle.write_text("not a directory", encoding="utf-8")
                scope = dict(ROOT=base, KEEP_DIR=default, LANES_DIR=source_dir,
                             RUN_STAMP="test-run", shutil=shutil, sys=sys)
                exec(code, scope)
                output, errors = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                    result = scope["keep_lane_log"]("mac", destination if explicit else None)
                case = f"explicit={explicit}, blocked={blocked}"
                if result is not (blocked is None):
                    problems.append(f"matrix log {case}: wrong retention verdict {result}")
                if blocked is None:
                    expected = f"== mac log kept at {destination / 'mac.log'} ==\n"
                    if output.getvalue() != expected or errors.getvalue():
                        problems.append(f"matrix log {case}: wrong success destination")
                    for parent in (destination, archive):
                        saved = parent / "mac.log"
                        if not saved.is_file() or saved.read_text(encoding="utf-8") != payload:
                            problems.append(f"matrix log {case}: current bytes missing at {saved}")
                else:
                    expected = {"destination": destination, "archive": archive,
                                "source": source_dir / "mac.log"}[blocked]
                    reason = "No such file or directory" if blocked == "source" else "File exists"
                    if (not errors.getvalue().startswith(
                            f"== mac log retention failed for {destination / 'mac.log'} ")
                            or str(expected) not in errors.getvalue()
                            or reason not in errors.getvalue()
                            or output.getvalue()):
                        problems.append(f"matrix log {case}: refusal lacks actual path "
                                        "and OS error")
                if report:
                    message = output.getvalue() or errors.getvalue()
                    print(f"check-gates: matrix log {case}: {message}",
                          end="")
    return problems


def hand_relaunch_problems(hand):
    branches = [node for node in ast.parse(hand).body
                if isinstance(node, ast.If)
                and isinstance(node.test, ast.Name) and node.test.id == "second"
                and any(isinstance(call, ast.Call)
                        and isinstance(call.func, ast.Attribute)
                        and call.func.attr == "second_act"
                        for call in ast.walk(node))]
    if len(branches) != 1:
        return [f"run-leg: expected one relaunch branch, read {len(branches)}"]
    code = compile(ast.Module(body=branches, type_ignores=[]),
                   "tools/run-leg.py relaunch branch", "exec")
    problems = []
    with tempfile.TemporaryDirectory() as scratch:
        log = pathlib.Path(scratch) / "leg.log"
        for second, rc, text, pushes in (
                (True, 0, "", 0),
                (True, 0, "KAYA_SELFTEST: OK\n", 0),
                (True, 3, "", 0),
                (True, 3, "KAYA_SELFTEST: ACT 1 OK\n", 0),
                (True, 0, "KAYA_SELFTEST: ACT 1 OK\n", 1),
                (False, 0, "KAYA_SELFTEST: OK\n", 0)):
            log.write_text(text, encoding="utf-8")
            calls = []
            def door(*args):
                calls.append(args)
                return 0
            scope = dict(second=second, rc=rc, log=log, ROOT=root,
                         scene="tasks", argv=[], env={}, sys=sys,
                         lane=types.SimpleNamespace(
                             act_one_ok=mac_lane.act_one_ok,
                             second_act=door, RELAUNCH_DOOR={"tasks": "test"}))
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                exec(code, scope)
            expected_rc = (rc or 1) if second and not pushes else rc
            case = f"second={second}, exit={rc}, marker={mac_lane.act_one_ok(text)}"
            if len(calls) != pushes or scope["rc"] != expected_rc:
                problems.append(f"run-leg relaunch {case}: door calls {len(calls)} "
                                f"and exit {scope['rc']}, expected {pushes} and {expected_rc}")
            if second and not pushes:
                measured = (f"act one exited {rc}; ACT 1 OK present: "
                            f"{mac_lane.act_one_ok(text)}; the door was not pushed")
                recorded = log.read_text(encoding="utf-8")
                if measured not in output.getvalue() or measured not in recorded:
                    problems.append(f"run-leg relaunch {case}: missing measured refusal "
                                    "in terminal or leg log")
    return problems


def hand_run_problems(hand, mac, pylib):
    """ONE WIRING FOR THE HAND RUN AND THE LANE. tools/run-leg.py runs one
    mac leg the way tools/validate-mac.py's pool runs it — under
    `timeout 120`, because a guest launched bare opens its undeclared
    window at another size (docs/traps.md, "A guest launched without the
    pool's timeout wrapper") — and through the same flight recorder,
    because a red is read from its bundle first (CLAUDE.md) and a hand red
    left nothing to read until 2026-09-18 (docs/deferred.md's hand-run
    entry). Both are one call now: tools/lib/flightrec_lane.py's
    MacRecorder wiring, which neither runner may spell for itself."""
    problems = []
    wiring = wiring_method(pylib)
    if wiring is None:
        return ["tools/lib/flightrec_lane.py: MacRecorder has no method "
                "that launches a leg under `timeout 120` with its own "
                "sampler running — that one wiring is what the lane's pool "
                "and the hand run share, and without it each spells its "
                "own launch again"]
    for rel, text in (("tools/run-leg.py", hand),
                      ("tools/validate-mac.py", mac)):
        calls = recorder_calls(text)
        if calls is None:
            problems.append(
                f"{rel} constructs no flightrec_lane.MacRecorder — it opens "
                f"no flight-recorder run at all, so its legs are journaled "
                f"nowhere and a red keeps nothing")
            continue
        if wiring not in calls:
            problems.append(
                f"{rel} does not run its leg through "
                f"MacRecorder.{wiring} — the leg then launches bare (an "
                f"undeclared window at another size) or with no sampler, "
                f"verb trace or bundle behind it")
        if '"timeout", "120"' in text:
            problems.append(
                f"{rel} spells its own `timeout 120` leg launch — the "
                f"wrapper is MacRecorder.{wiring}'s, because it is also "
                f"the sampler's pid anchor, and a second copy is how the "
                f"two paths drift")
        for method, why in (
                ("mac_leg", "journals no leg and collects no bundle — that "
                            "is the one collect entry every mac leg path "
                            "calls"),
                ("flush", "never writes its spooled records to the "
                          "journal")):
            if method not in calls:
                problems.append(f"{rel} {why} (no .{method}() on the "
                                f"recorder it opened)")
    if not override_says_so(hand):
        problems.append(
            "tools/run-leg.py takes steps from KAYA_SELFTEST_SCRIPT "
            "without printing that it did — a hand run that names one "
            "scene and runs another's steps is a diagnostic that cannot "
            "discriminate (invariant 3)")
    problems.extend(hand_relaunch_problems(hand))
    return problems


matrix_text = (root / "tools" / "validate-all.py").read_text(encoding="utf-8")
run_leg_text = (root / "tools" / "run-leg.py").read_text(encoding="utf-8")
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

# N2b — the mac lane's sweep put BACK inside the matrix branch, which is
# the shipped state that cost the ceiling twice. The perturbation moves
# the delegation up into the `if _token:` arm.
moved = mac_text.replace(
    '    if run([str(ROOT / "tools/swiftui/build-dylib.sh")]).returncode != 0:\n'
    '        sys.exit(1)\n',
    '    if run([str(ROOT / "tools/gates.py")]).returncode != 0:\n'
    '        sys.exit(1)\n'
    '    if run([str(ROOT / "tools/swiftui/build-dylib.sh")]).returncode != 0:\n'
    '        sys.exit(1)\n', 1)
print(f"check-gates: self-test N2b moved the sweep into the matrix branch, "
      f"{0 if moved == mac_text else 1} substitution(s)")
if moved == mac_text:
    fail("self-test N2b applied NO substitution — validate-mac.py's skip "
         "path does not look the way this negative expects, so the "
         "one-sweep clause is measuring nothing")
elif mac_sweep_problem(moved) is None:
    fail("self-test N2b: the mac lane sweeping inside the matrix branch was "
         "NOT refused — the one-sweep clause agrees with everything")

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
# schedule exists to bound (measured again 2026-09-07: matrix #24).
doctored, n = re.subn(
    r"(?m)^    android_lane_proc\.wait\(\)\n", "", matrix_text, count=1)
print("check-gates: self-test N11 removed the Android wait, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N11 did not remove exactly one Android wait — the delayed "
         "sweep clause is not reading the real matrix")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N11: an immediate gate sweep passed as delayed")

# N11b — the sweep must also wait for the mac lane: its guests load the
# host libkaya by path (2026-09-21, seven dyld reds).
doctored, n = re.subn(
    r"(?m)^    mac_lane_proc\.wait\(\)\n", "", matrix_text, count=1)
print("check-gates: self-test N11b removed the mac wait, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N11b did not remove exactly one mac wait — the delayed "
         "sweep clause is not reading the real matrix")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N11b: a sweep that waits for Android alone passed")

# N10b — and it must wait for THIS invocation's mac child.
doctored, n = re.subn(
    re.escape(MAC_PID), "mac_lane_proc = lane_procs[1]", matrix_text, count=1)
print("check-gates: self-test N10b replaced mac pid provenance, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N10b did not replace exactly one mac pid capture — the "
         "provenance clause is not reading the real matrix")
elif matrix_parallel_problem(doctored) is None:
    fail("self-test N10b: an unproven mac pid passed")

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

problem = mac_sweep_problem(mac_text)
if problem is not None:
    fail(problem)

problem = matrix_parallel_problem(matrix_text)
if problem is not None:
    fail(problem)
for problem in lane_log_problems(matrix_text, report=True):
    fail(problem)
problem = android_pool_problem(android_text, probe_text)
if problem is not None:
    fail(problem)
problem = ios_pool_problem(ios_text, probe_text)
if problem is not None:
    fail(problem)
for problem in hand_run_problems(run_leg_text, mac_text, flightrec_pylib_text):
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

# N18 — the hand runner launching itself must be named: bare (an
# undeclared window at another size) AND with no recorder behind it,
# which is the state a hand red was in until 2026-09-18.
doctored, n = re.subn(
    r"rc = FR\.watched_leg\(SCRATCH / name, argv, env, lf, cwd=ROOT,\n"
    r"\s+echo=sys\.stdout\)",
    "rc = subprocess.run(argv, cwd=ROOT, env=env).returncode",
    run_leg_text, count=1)
print(f"check-gates: self-test N18 unwired the hand run's recorder, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N18 did not replace exactly one launch — the hand-run "
         "clause is not reading tools/run-leg.py")
else:
    problems = hand_run_problems(doctored, mac_text, flightrec_pylib_text)
    if not problems:
        fail("self-test N18: a hand runner launching its own leg passed")
    elif not any("run-leg" in x and "watched_leg" in x for x in problems):
        fail("self-test N18 failed for another reason: " + "; ".join(problems))

# N19 — the lane's pool spelling the launch for itself again, beside the
# wiring: two copies of one shape is how the hand run drifted off it.
doctored, n = re.subn(
    r"return FR\.watched_leg\(scratch, argv, leg_env, lf\)",
    'proc = subprocess.Popen(["timeout", "120", *argv], env=leg_env,\n'
    "                                    stdout=lf, stderr=lf)\n"
    "            return proc.wait()",
    mac_text, count=1)
print(f"check-gates: self-test N19 re-inlined the pool's own leg launch, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N19 did not replace exactly one pooled launch — the "
         "hand-run clause is not reading tools/validate-mac.py")
else:
    problems = hand_run_problems(run_leg_text, doctored, flightrec_pylib_text)
    if not any("validate-mac" in x and "timeout 120" in x for x in problems):
        fail("self-test N19: a runner spelling its own `timeout 120` leg "
             "launch passed: " + ("; ".join(problems) or "no finding"))

# N20 — the hand run taking its steps from the environment in silence.
doctored, n = re.subn(
    r'    print\(f"run-leg: the steps come from KAYA_SELFTEST_SCRIPT in this "\n'
    r'[^\n]*\n[^\n]*\n',
    "", run_leg_text, count=1)
print(f"check-gates: self-test N20 silenced the hand run's scene override, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N20 did not remove exactly one override sentence — the "
         "hand-run clause is not reading tools/run-leg.py")
else:
    problems = hand_run_problems(doctored, mac_text, flightrec_pylib_text)
    if not any("KAYA_SELFTEST_SCRIPT" in x for x in problems):
        fail("self-test N20: a hand run that swaps the scene's steps in "
             "silence passed: " + ("; ".join(problems) or "no finding"))

# N21 — the wrapper gone from the one wiring, which is where the
# bare-launch trap now lives for both runners (docs/traps.md).
doctored, n = re.subn(r'\["timeout", "120", \*argv\], cwd=cwd, env=env,',
                      "argv, cwd=cwd, env=env,", flightrec_pylib_text,
                      count=1)
print(f"check-gates: self-test N21 removed the wiring's timeout wrapper, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N21 did not remove exactly one wrapper — the hand-run "
         "clause is not reading tools/lib/flightrec_lane.py")
else:
    problems = hand_run_problems(run_leg_text, mac_text, doctored)
    if not any("under `timeout 120`" in x for x in problems):
        fail("self-test N21: a wiring that launches the guest bare passed: "
             + ("; ".join(problems) or "no finding"))

# N22 — the hand run opening no recorder at all, which is the state a
# hand red was in before this: every other clause reads the recorder it
# opened, so this branch is the one that must still speak.
doctored, n = re.subn(r"FR = flightrec_lane\.MacRecorder\(ROOT\)",
                      "FR = None", run_leg_text, count=1)
print(f"check-gates: self-test N22 took the recorder out of the hand run, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N22 did not remove exactly one recorder — the hand-run "
         "clause is not reading tools/run-leg.py")
else:
    problems = hand_run_problems(doctored, mac_text, flightrec_pylib_text)
    if not any("constructs no" in x for x in problems):
        fail("self-test N22: a hand run with no flight-recorder run passed: "
             + ("; ".join(problems) or "no finding"))

# N23 — the records spooled and never flushed: the bundle is on disk and
# the journal never learns the leg ran.
doctored, n = re.subn(r"    FR\.flush\(\)\n", "", run_leg_text, count=1)
print(f"check-gates: self-test N23 dropped the hand run's journal flush, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N23 did not remove exactly one flush — the hand-run "
         "clause is not reading tools/run-leg.py")
else:
    problems = hand_run_problems(doctored, mac_text, flightrec_pylib_text)
    if not any("spooled records" in x for x in problems):
        fail("self-test N23: a hand run that journals nothing passed: "
             + ("; ".join(problems) or "no finding"))

for label, old, new in (
        ("marker", "if rc != 0 or not act_one:", "if rc != 0:"),
        ("exit", "if rc != 0 or not act_one:", "if not act_one:"),
        ("verdict", "rc = rc or 1", "rc = 0"),
        ("recorded refusal", 'lf.write(refusal + "\\n")', "pass")):
    doctored, n = re.subn(re.escape(old), lambda _: new, run_leg_text, count=1)
    print(f"check-gates: hand relaunch cut {label}, {n} substitution(s)")
    if n != 1:
        fail(f"hand relaunch {label} negative changed {n} sites, expected one")
    else:
        problems = hand_relaunch_problems(doctored)
        print(f"check-gates: hand relaunch {label}: {len(problems)} refusal(s)")
        if not problems:
            fail(f"hand relaunch {label} negative passed")

for label, old, new in (
        ("success path", 'log kept at {destination}',
         'log kept at target/validate-failures/{name}.log'),
        ("failure path", 'log retention failed for {destination}',
         'log retention failed for target/validate-failures/{name}.log'),
        ("OS error", '): {error} ==', '): copy failed =='),
        ("archive copy", 'shutil.copy2(LANES_DIR / f"{name}.log", run_dir / f"{name}.log")',
         'pass')):
    n = matrix_text.count(old)
    print(f"check-gates: matrix log cut {label}, {n} substitution(s)")
    if n != 1:
        fail(f"matrix log {label} negative changed {n} sites, expected one")
    else:
        problems = lane_log_problems(matrix_text.replace(old, new))
        print(f"check-gates: matrix log {label}: {len(problems)} refusal(s)")
        if not problems:
            fail(f"matrix log {label} negative passed")

# The driver's own arithmetic: an under-run, a failing gate and a
# missing script must each come back red, watched on every run.
proof = subprocess.run([str(root / "tools" / "gates.py"), "--selftest"],
                       cwd=root, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, check=False)
if proof.returncode != 0:
    fail("tools/gates.py --selftest FAILED — the sweep's count does not refuse "
         "an under-run, so a sweep that ran nothing could print OK:\n"
         + proof.stdout)


# ONE FILTER ON THE MATRIX (tools/lib/only.py; the maintainer, 2026-09-24:
# "you only need one filter on the matrix"): `--only <prefix,...>` rides to
# every lane as KAYA_ONLY, each python lane reads it through the one module
# and refuses a run that queued nothing, the shell lane spells the same
# comma loop and the same refusal exit, and the matrix marks its verdict
# FILTERED and never counts a refusal as a pass. A lane that stopped
# reading the filter would run its whole roster under a flag that promised
# a few legs, and nothing but this clause could tell.
ONLY_FILES = {
    "tools/validate-mac.py": ("only.wanted(", "only.summary(\"validate-mac\""),
    "tools/ios/run-sim.py": ("only.wanted(", "only.summary(\"run-sim\""),
    "tools/android/run-emulator.py": ("only.matches(",
                                      "only.summary(\"run-emulator\""),
    "tools/deploy-win.py": ("only.matches(lane.legs())",
                            "only.summary(\"deploy-win\""),
}
ONLY_SHELL = ('IFS=, read -r -a kaya_prefixes <<< "$KAYA_ONLY"',
              'matched no leg of this runner — no verdict" >&2\n    exit 3')
ONLY_MATRIX = ('os.environ["KAYA_ONLY"] = _args.pop(0)',
               "rc == only.REFUSED and only.active()",
               'verdict = "SKIP"',
               "validate-all: ALL PASS — FILTERED (KAYA_ONLY=",
               "matched \"\n              f\"no leg on any lane — no verdict")


def only_problem(texts):
    """texts: {rel: text} for the six files; None when the filter is wired."""
    for rel, needles in ONLY_FILES.items():
        for needle in needles:
            if needle not in code_lines_text(texts[rel]):
                return (f"{rel} no longer reads the matrix filter "
                        f"({needle!r} missing)")
    for needle in ONLY_SHELL:
        if needle not in texts["tools/linux/run-suites.sh"]:
            return ("tools/linux/run-suites.sh no longer spells the filter's "
                    f"loop or refusal ({needle[:40]!r})")
    for needle in ONLY_MATRIX:
        if needle not in texts["tools/validate-all.py"]:
            return ("tools/validate-all.py no longer threads --only, skips a "
                    f"refusal or marks a filtered verdict ({needle[:40]!r})")
    return None


def code_lines_text(text):
    return "\n".join(code_lines(text))


only_texts = {rel: (root / rel).read_text(encoding="utf-8")
              for rel in [*ONLY_FILES, "tools/linux/run-suites.sh",
                          "tools/validate-all.py"]}
problem = only_problem(only_texts)
if problem:
    fail("the matrix filter: " + problem)

# N24 — a python lane that stopped filtering its queue must be reported.
doctored, n = re.subn(r"only\.wanted\(name\)", "True",
                      only_texts["tools/ios/run-sim.py"], count=1)
print(f"check-gates: self-test N24 unhooked the iOS runner's filter, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N24 did not unhook exactly one filter read — the clause "
         "is not reading the real runner")
elif only_problem({**only_texts, "tools/ios/run-sim.py": doctored}) is None:
    fail("self-test N24: an iOS runner ignoring KAYA_ONLY passed")

# N25 — the shell lane's refusal must be the shared exit, not a status.
doctored, n = re.subn(r'no verdict" >&2\n    exit 3', 'no verdict"\n    status=1',
                      only_texts["tools/linux/run-suites.sh"], count=1)
print("check-gates: self-test N25 turned the linux refusal back into a red "
      f"verdict, {n} substitution(s)")
if n != 1:
    fail("self-test N25 did not change exactly one refusal — the clause is "
         "not reading the real runner")
elif only_problem({**only_texts, "tools/linux/run-suites.sh": doctored}) is None:
    fail("self-test N25: a linux refusal that reads as a lane failure passed")

# N26 — the matrix counting a refusal as a pass, or a filtered verdict
# spelled like the record, must be reported.
doctored, n = re.subn(r'verdict = "SKIP"', 'verdict = "PASS"',
                      only_texts["tools/validate-all.py"], count=1)
print("check-gates: self-test N26 made the matrix read a refusal as PASS, "
      f"{n} substitution(s)")
if n != 1:
    fail("self-test N26 did not change exactly one verdict — the clause is "
         "not reading the real matrix")
elif only_problem({**only_texts, "tools/validate-all.py": doctored}) is None:
    fail("self-test N26: a matrix passing a lane that ran nothing passed")
doctored, n = re.subn(r"ALL PASS — FILTERED \(KAYA_ONLY=", "ALL PASS (KAYA_ONLY=",
                      only_texts["tools/validate-all.py"], count=1)
print("check-gates: self-test N27 spelled the filtered verdict like the "
      f"record, {n} substitution(s)")
if n != 1:
    fail("self-test N27 did not change exactly one verdict line — the clause "
         "is not reading the real matrix")
elif only_problem({**only_texts, "tools/validate-all.py": doctored}) is None:
    fail("self-test N27: a filtered verdict spelled like the record passed")

if status == 0:
    print(f"check-gates: OK ({len(GATES)} gates in one list, "
          f"{len(EXCLUDED)} excluded with a reason, five concurrent platform lanes, "
          "niced sweep delayed behind Android and the mac lane, four-phone "
          "Android pool, three-sim iOS pool, "
          "five lanes each ending with their verdict and journaling every leg, "
          "one matrix filter read by all five)")
else:
    print("check-gates: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)
