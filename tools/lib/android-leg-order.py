"""The Android stage, slot, and per-leg setup have load-bearing order.

Each constraint, and what it cost, is in docs/traps.md; the STEPS table
below carries the reason for every per-leg pair. None of it is visible
at the call site — each line is a plausible adb call in a plausible
place, and the failure surfaces much later as "the picker never
appeared" or as a duration anomaly.

Text, not execution: this reads tools/android/run-emulator.py (the
runner conversion's stage 3) rather than running it, so it cannot see
an order produced dynamically. That is the honest limit, and it still
catches a line moved to a reasonable-looking wrong place. The scene
censuses (A11Y_SCENES, IME_SCENES) and the per-suite rosters read
tools/lib/lanes/android.py, the same module the runner imports — one
source of truth, no regex over leg lines.
"""

import ast
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNNER = ROOT / "tools" / "android" / "run-emulator.py"
LANE = ROOT / "tools" / "lib" / "lanes" / "android.py"
# The probe keeps the same order for the same reasons, and is where two
# of these constraints were MEASURED. It is still shell.
PROBE = ROOT / "tools" / "android" / "pickerprobe" / "run.sh"
SCENES = ROOT / "tools" / "scenes"
PICKER_VERB = re.compile(
    r"^(?:file_dialog_goto|expect_file_dialog|file_choose|"
    r"expect_save_dialog|file_dialog_name|file_save)\b",
    re.MULTILINE,
)
COMPOSING_VERB = re.compile(r"^compose\b", re.MULTILINE)

# (label, pattern, why it must follow the step before it)
STEPS = [
    (
        "guarded disarm of prior accessibility",
        r"if needs_a11y and not a11y_disarm\(serial, package, a11y, "
        r"out=log\):\s*return False",
        "a previous picker may have left the service enabled; it must be "
        "disabled, unbound, and gone before the app is force-stopped and "
        "re-armed, but ordinary scenes must not pay a device query",
    ),
    (
        "force-stop",
        r'adb\(serial, "shell", "am", "force-stop", package,',
        "a leftover process from the previous leg would answer for this one",
    ),
    (
        "force-stop the picker",
        r'adb\(serial, "shell", "am", "force-stop", picker,',
        "DocumentsUI is a different package and survives the app's "
        "force-stop; left standing it sits on top of the app's task, and "
        "the next `am start` brings that task forward instead of starting "
        "the activity — no onCreate, no scene, and it reads as a clean run",
    ),
    (
        "logcat -c",
        r'adb\(serial, "logcat", "-c", stdout=log, stderr=log\)',
        "the force-stop's own noise must not land in this leg's verdict",
    ),
    (
        "picker-scene accessibility guard",
        r"if needs_a11y:\s*ready = False\s*bound = False\s*"
        r"for arm in range\(1, 4\):",
        "only scenes that leave the app for DocumentsUI need the service; "
        "arming ordinary legs adds a dozen adb round trips to every leg",
    ),
    (
        "enable accessibility",
        r'"enabled_accessibility_services", a11y,',
        "force-stop kills the service (the validation app declares it) and "
        "logcat -c erases its connection message — enabling before either "
        "leaves it dead and undetectable",
    ),
    (
        "readable-window handshake",
        r"KAYA_A11Y_WINDOWS: READY",
        "a bound service can still have an empty interactive-window list; "
        "starting the scene then turns the harness failure into a false "
        "missing-picker diagnosis",
    ),
    (
        "am start",
        r'adb\(serial, "shell", "am", "start", "-W", "-n", component,',
        "the app must not run before the service that watches it is up",
    ),
]

# `am start -S` force-stops the package before starting it, taking the
# accessibility service down with it (docs/traps.md). It looks like the
# fix for the stale-task problem above, which is why it needs saying.
# Two spellings: the runner's argv list, and the probe's shell text.
FORBIDDEN_START_PY = re.compile(r'"am", "start",[^)]*"-S"', re.DOTALL)
FORBIDDEN_START_SH = re.compile(r"am start\b[^\n]*\s-S\b")
FORBIDDEN_EMPTY_SETTING = re.compile(
    r'"enabled_accessibility_services", "",'
)

# stage_suite_apk's refusal skeleton, each spelling counted once in its
# body (the launch loop and the print loop both open `for serial in
# targets:`, hence 2 there).
STAGE_REQUIRED = [
    'expected = POOL + 1 if label == "compose" else POOL',
    "if len(targets) != expected:",
    "if len(set(targets)) != len(targets):",
    "threading.Thread(target=stage_one, args=(serial,),",
    'target_verdict = "OK"',
    'target_verdict + "\\n", encoding="utf-8")',
    "launched = len(threads)",
    "deadline_at = time.monotonic() + STAGE_DEADLINE",
    "observed += 1",
    'if verdict == "OK":',
    'print(f"stage-{label}-{serial}: {verdict}")',
    "if launched != expected or observed != expected:",
    "if passed != expected:",
    'print(f"stage-{label}: OK ({passed}/{expected} targets)")',
]
# The worker's slot/IME/verdict order: claim, slot-local IME assert,
# launch, release, verdict.
IME_ORDER_MARKERS = [
    "slot = _claim_device()",
    "select_helper_ime(serial, log)",
    "ok = ready and run_apk_on(serial, name, *args, log=log)",
    "_release_device(slot)",
    '.verdict").write_text(',
]
# build_suite's tail, in order: the apk's component verify, the two
# byte equalities, the staging barrier — and the compose-only tablet
# target spelled once.
BUILD_TAIL_MARKERS = [
    '"--component", "compose", str(apk)',
    "apk_icon_verify(apk)",
    "apk_assets_verify(apk)",
    "stage_suite_apk(suite, apk, package, targets)",
]
TARGETS_LINE = (
    '    targets = ([*SERIALS, TABLET_SERIAL] if suite == "compose"\n'
    "               else list(SERIALS))"
)


def py_function(text: str, name: str) -> str | None:
    """The source span of one top-level def, by ast — a parse failure
    or a missing def is None, never a guess."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None
    lines = text.splitlines(keepends=True)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return "".join(lines[node.lineno - 1:node.end_lineno])
    return None


def load_lane(text: str) -> dict | None:
    """The lane module's namespace, evaluated from TEXT so the
    self-tests can perturb a copy. The module is plain data by its own
    contract (no imports, no I/O)."""
    ns: dict = {}
    try:
        exec(compile(text, str(LANE), "exec"), ns)  # noqa: S102
    except (SyntaxError, ValueError, KeyError):
        return None
    return ns


def no_restart_flag(label: str, text: str, pattern=FORBIDDEN_START_PY,
                    quiet: bool = False) -> int:
    """`-S` on any `am start` in this text is a failure."""
    hit = pattern.search(text)
    if hit is None:
        return 0
    if quiet:
        return 1
    print(
        f"android-leg-order: {label} runs `am start -S` "
        f"({hit.group(0).strip()!r}). -S force-stops the package first, "
        f"and the harness accessibility service lives in that process — "
        f"it kills the service the bind check just confirmed, and the "
        f"activity comes up where it is not watching. Force-stop the "
        f"picker's package instead; that is the stale task.",
        file=sys.stderr,
    )
    return 1


def no_empty_setting(label: str, text: str, quiet: bool = False) -> int:
    """An empty `settings put` is rejected; it does not clear the value."""
    hit = FORBIDDEN_EMPTY_SETTING.search(text)
    if hit is None:
        return 0
    if quiet:
        return 1
    print(
        f"android-leg-order: {label} writes an empty "
        f"enabled_accessibility_services ({hit.group(0)!r}). Android "
        f"prints `Bad arguments` and leaves the old component enabled, "
        f"so package replacement can resurrect it after force-stop. Use "
        f"`settings delete secure enabled_accessibility_services`.",
        file=sys.stderr,
    )
    return 1


def hygiene_problem(text: str) -> str | None:
    body = py_function(text, "a11y_hygiene")
    if body is None:
        return "a11y_hygiene is missing"
    route = re.search(
        r'for component in enabled\.split\(":"\):\s*'
        r'if component\.endswith\("/dev\.kaya\.KayaHarnessAccessibility"'
        r"\):\s*"
        r'package = component\.split\("/", 1\)\[0\]\s*'
        r"if not a11y_disarm\(serial, package, component\):\s*"
        r"return False",
        body,
    )
    if ("enabled_accessibility_services" not in body or route is None):
        return ("a11y_hygiene no longer reads and retires a stale "
                "harness service")
    invocations = re.findall(r"\ba11y_hygiene\(", text)
    if len(invocations) != 2:  # the def and the startup sweep
        return ("a11y_hygiene must run exactly once, in the startup "
                "device sweep")
    call = re.search(
        r"for _serial in \[\*SERIALS, TABLET_SERIAL\]:\s*"
        r"if not a11y_hygiene\(_serial\):\s*"
        r"sys\.exit\(1\)",
        text,
    )
    run = text.find("def run_apk_on(")
    if (call is None or run < 0 or call.start() < text.find(body)
            or call.start() > run):
        return "every device must complete a11y_hygiene before run_apk_on"
    return None


def guarded_disarm_problem(body: str) -> str | None:
    call = r"a11y_disarm\(serial, package, a11y, out=log\)"
    calls = list(re.finditer(call, body))
    pre = re.findall(
        r"if needs_a11y and not " + call + r":\s*return False",
        body,
    )
    post = re.findall(
        r"if needs_a11y and not " + call + r":\s*failed = True\s*"
        r"return not failed\s*\Z",
        body,
    )
    if len(calls) != 2:
        return ("run_apk_on must contain exactly two accessibility "
                "disarm calls")
    if len(pre) != 1:
        return "the picker pre-leg disarm must remain guarded"
    if len(post) != 1:
        return ("the picker post-leg disarm must be the final action "
                "before verdict")
    return None


def staging_problem(text: str) -> str | None:
    body = py_function(text, "stage_suite_apk")
    run_body = py_function(text, "run_apk_on")
    build_body = py_function(text, "build_suite")
    if body is None:
        return "stage_suite_apk is missing or unreadable"
    if run_body is None:
        return "run_apk_on is missing or unreadable"
    if build_body is None:
        return "build_suite is missing or unreadable"
    if ": PASS" in body:
        return "APK staging must not print the scene-leg PASS marker"
    install = '"install", "-r", str(apk),'
    if text.count(install) != 1 or install not in body:
        return ("the suite APK must be installed exactly once, inside "
                "stage_suite_apk")
    if '"install"' in run_body:
        return "run_apk_on still installs an APK per leg"
    adjacency = re.search(
        r"if a11y_disarm\(serial, package, a11y, out=slog\) and adb\(\s*"
        r'serial, "install", "-r", str\(apk\),',
        body,
    )
    if adjacency is None:
        return ("each target must disarm its stale service immediately "
                "before install")
    launch_loops = body.count("for serial in targets:")
    if launch_loops != 2:
        return ("stage_suite_apk lost its target/verdict refusal: "
                "for serial in targets:")
    missing = [item for item in STAGE_REQUIRED if body.count(item) != 1]
    if missing:
        return f"stage_suite_apk lost its target/verdict refusal: {missing[0]}"
    if text.count("stage_suite_apk(") != 2:  # the def and one call
        return "every suite must reach the one staging barrier exactly once"
    if TARGETS_LINE not in build_body:
        return ("compose must stage on phones plus tablet and the other "
                "suites on the phone pool alone — the targets line moved")
    positions = [build_body.find(m) for m in BUILD_TAIL_MARKERS]
    if any(pos < 0 for pos in positions) or positions != sorted(positions):
        return ("staging must follow every artifact verification — "
                "build_suite's verify/icon/assets/stage order moved")
    driver = re.search(
        r"if not build_suite\(_suite\):\s*sys\.exit\(1\)\s*"
        r"run_suite_legs\(_suite\)",
        text,
    )
    if driver is None:
        return "every suite's staging must precede its first leg"
    return None


def ime_problem(text: str, lane_ns: dict) -> str | None:
    actual = set(lane_ns.get("IME_SCENES", []))
    expected = {
        path.stem
        for path in SCENES.glob("*.steps")
        if COMPOSING_VERB.search(path.read_text(encoding="utf-8"))
        is not None
    }
    if actual != expected:
        return (f"lanes/android.py's IME_SCENES disagrees with shared "
                f"compose verbs (wanted={sorted(expected)}, "
                f"got={sorted(actual)})")
    worker = py_function(text, "_leg_worker")
    if worker is None:
        return "_leg_worker is missing or unreadable"
    call = re.findall(
        r"if \(script in lane\.IME_SCENES\s*"
        r"and not select_helper_ime\(serial, log\)\):\s*"
        r"ready = False",
        worker,
    )
    if len(call) != 1:
        return ("slot-local IME preparation must fail through the "
                "normal leg verdict path")
    positions = [worker.find(marker) for marker in IME_ORDER_MARKERS]
    if any(pos < 0 for pos in positions) or positions != sorted(positions):
        return ("IME preparation must sit after slot claim, before "
                "launch, and preserve slot cleanup/verdict")
    invocations = re.findall(r"select_helper_ime\(", text)
    if len(invocations) != 2:  # the def and the worker call
        return ("select_helper_ime must be invoked once from the "
                "slot-local worker only")
    if len(re.findall(r"(?m)^    drain\(\)$", text)) != 1:
        return ("each suite must end in exactly one drain, inside "
                "run_suite_legs")
    legs_fn = py_function(text, "run_suite_legs")
    if legs_fn is None or legs_fn.find("queue_leg(") < 0 \
            or legs_fn.find("queue_leg(") > legs_fn.find("    drain()"):
        return "the one drain must follow the suite's queued legs"
    legs = lane_ns.get("LEGS", {})
    for name in ("compose", "jvm", "go"):
        # The python suite's roster is varied+portfolio; no python scene
        # needs the IME, so the ranges rule is the three original
        # suites' (docs/deferred.md holds the portfolio entry).
        if f"ranges-{name}" not in legs.get(name, []):
            return f"{name} no longer carries its ranges leg"
    if "editor-go" not in legs.get("go", []):
        return "editor-go left the Go suite's roster"
    return None


def main() -> int:
    for path, label in ((RUNNER, "runner"), (LANE, "lane module")):
        if not path.exists():
            print(f"android-leg-order: {path} is missing ({label})",
                  file=sys.stderr)
            return 1
    text = RUNNER.read_text(encoding="utf-8")
    lane_text = LANE.read_text(encoding="utf-8")
    lane_ns = load_lane(lane_text)
    if lane_ns is None:
        print("android-leg-order: tools/lib/lanes/android.py did not "
              "evaluate — the lane data is unreadable", file=sys.stderr)
        return 1
    total = len(lane_ns["legs"]())
    if total < 100:
        print(f"android-leg-order: the lane module lists {total} legs — "
              f"a roster that small is this census reading nothing, not "
              f"the lane shrinking", file=sys.stderr)
        return 1

    body = py_function(text, "run_apk_on")
    if body is None:
        print(
            "android-leg-order: run_apk_on() not found — the runner's "
            "shape moved and this gate went vacuous",
            file=sys.stderr,
        )
        return 1

    problem = hygiene_problem(text)
    if problem is not None:
        print(f"android-leg-order: {problem}", file=sys.stderr)
        return 1
    problem = staging_problem(text)
    if problem is not None:
        print(f"android-leg-order: {problem}", file=sys.stderr)
        return 1
    problem = ime_problem(text, lane_ns)
    if problem is not None:
        print(f"android-leg-order: {problem}", file=sys.stderr)
        return 1
    problem = guarded_disarm_problem(body)
    if problem is not None:
        print(f"android-leg-order: {problem}", file=sys.stderr)
        return 1

    declared_scenes = set(lane_ns.get("A11Y_SCENES", []))
    picker_scenes = {
        path.stem
        for path in SCENES.glob("*.steps")
        if PICKER_VERB.search(path.read_text(encoding="utf-8"))
        is not None
    }
    if declared_scenes != picker_scenes:
        missing = sorted(picker_scenes - declared_scenes)
        extra = sorted(declared_scenes - picker_scenes)
        print(
            "android-leg-order: lanes/android.py's A11Y_SCENES disagrees "
            f"with the shared picker verbs (missing={missing}, "
            f"extra={extra}); a missing scene launches DocumentsUI "
            "without the service, while an extra one restores the "
            "all-leg setup cost",
            file=sys.stderr,
        )
        return 1

    found = []
    for label, pattern, why in STEPS:
        match = re.search(pattern, body)
        if match is None:
            print(
                f"android-leg-order: no `{label}` step in run_apk_on — "
                f"either it was removed or its spelling changed, and "
                f"this gate can no longer police the order it sits in",
                file=sys.stderr,
            )
            return 1
        found.append((match.start(), label, why))

    status = 0
    for i in range(1, len(found)):
        if found[i][0] > found[i - 1][0]:
            continue
        _, label, why = found[i]
        prev = found[i - 1][1]
        print(
            f"android-leg-order: `{label}` comes BEFORE `{prev}` in "
            f"run_apk_on, and it must come after: {why}.",
            file=sys.stderr,
        )
        status = 1

    status |= no_restart_flag("run_apk_on", body)
    status |= no_empty_setting("run-emulator", text)

    # The probe is policed for the flag but not for the order: its
    # reset is a loop over variants rather than run_apk_on's shape.
    # Absent is fine — it is a probe, and may be deleted. Still shell,
    # so the shell spelling.
    if PROBE.exists():
        status |= no_restart_flag(str(PROBE.relative_to(ROOT)),
                                  PROBE.read_text(encoding="utf-8"),
                                  FORBIDDEN_START_SH)

    # ---- the gate guards itself: every clause watched red, counts
    # ---- printed, an unchanged text is a failed test.
    def doctor(label, source, pattern, repl, count=1):
        doctored, n = re.subn(pattern, repl, source, count=count)
        print(f"android-leg-order: {label} self-test applied {n} "
              f"substitution(s)")
        return doctored, n

    # N1: a shuffled synthetic body must be caught by the order clause.
    shuffled = (
        'def run_apk_on(serial):\n'
        '    adb(serial, "shell", "am", "force-stop", package,\n'
        '        stderr=log)\n'
        '    if needs_a11y and not a11y_disarm(serial, package, a11y, '
        'out=log):\n'
        '        return False\n'
    )
    positions = [re.search(p, shuffled) for _, p, _ in
                 [STEPS[0], STEPS[1]]]
    if positions[0] is None or positions[1] is None:
        print("android-leg-order: SELF-TEST FAIL (patterns did not "
              "match)", file=sys.stderr)
        return 1
    if positions[0].start() < positions[1].start():
        print("android-leg-order: SELF-TEST FAIL (bad order read as "
              "good)", file=sys.stderr)
        return 1

    # N2/N3: the restart flag, both spellings, both directions.
    if no_restart_flag(
            "self-test",
            'adb(serial, "shell", "am", "start", "-S", "-W", "-n", c,',
            quiet=True) == 0:
        print("android-leg-order: SELF-TEST FAIL (`am start -S` argv "
              "read as good)", file=sys.stderr)
        return 1
    if no_restart_flag(
            "self-test",
            'adb(serial, "shell", "am", "start", "-W", "-n", component,',
            quiet=True) != 0:
        print("android-leg-order: SELF-TEST FAIL (a clean `am start` "
              "refused)", file=sys.stderr)
        return 1
    if no_restart_flag("self-test",
                       'adb -s "$s" shell am start -S -W -n "$c"',
                       FORBIDDEN_START_SH, quiet=True) == 0:
        print("android-leg-order: SELF-TEST FAIL (shell `am start -S` "
              "read as good)", file=sys.stderr)
        return 1

    # N4/N5: the empty-setting rule, both directions.
    if no_empty_setting(
            "self-test",
            '"enabled_accessibility_services", "",', quiet=True) == 0:
        print("android-leg-order: SELF-TEST FAIL (empty setting read "
              "as a clear)", file=sys.stderr)
        return 1
    if no_empty_setting(
            "self-test",
            '"enabled_accessibility_services", a11y,', quiet=True) != 0:
        print("android-leg-order: SELF-TEST FAIL (a real arm refused)",
              file=sys.stderr)
        return 1

    # N6/N7: the picker-verb census, both directions.
    if PICKER_VERB.search('expect label#0 "ready"\n') is not None:
        print("android-leg-order: SELF-TEST FAIL (ordinary scene read "
              "as picker)", file=sys.stderr)
        return 1
    if PICKER_VERB.search("file_save\n") is None:
        print("android-leg-order: SELF-TEST FAIL (picker scene read as "
              "ordinary)", file=sys.stderr)
        return 1

    # N8: a per-leg install must red the staging clause.
    doctored, n = doctor(
        "per-leg install",
        text,
        r"(?m)^(    failed = False\n)",
        '\\1    adb(serial, "install", "-r", str(apk), stdout=log)\n',
    )
    if n != 1 or staging_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (per-leg install read "
              "as staged)", file=sys.stderr)
        return 1

    # N9: an install without its adjacent disarm must red.
    doctored, n = doctor(
        "stage disarm",
        text,
        r"if a11y_disarm\(serial, package, a11y, out=slog\) and adb\(",
        "if adb(",
    )
    if n != 1 or staging_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (install without "
              "stage disarm read as good)", file=sys.stderr)
        return 1

    # N10: the stage verdict must never wear the scene-leg PASS marker.
    doctored, n = doctor(
        "stage PASS-marker",
        text,
        re.escape('print(f"stage-{label}: OK ({passed}/{expected} '
                  'targets)")'),
        'print(f"stage-{label}: PASS ({passed}/{expected} targets)")',
    )
    if n != 1 or staging_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (APK staging read as "
              "a scene leg)", file=sys.stderr)
        return 1

    # N11..: each stage refusal marker removed must red.
    for index, marker in enumerate(STAGE_REQUIRED, 1):
        doctored, n = doctor(f"stage refusal {index}", text,
                             re.escape(marker), "pass  #")
        if n != 1 or staging_problem(doctored) is None:
            print(f"android-leg-order: SELF-TEST FAIL (missing stage "
                  f"refusal {index} read as good)", file=sys.stderr)
            return 1

    # N12: the compose-only tablet targeting, both halves in one line —
    # compose losing the tablet, or another suite gaining it.
    doctored, n = doctor(
        "tablet targeting",
        text,
        re.escape('[*SERIALS, TABLET_SERIAL] if suite == "compose"'),
        '[*SERIALS, TABLET_SERIAL] if suite == "jvm"',
    )
    if n != 1 or staging_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (wrong tablet "
              "targeting read as good)", file=sys.stderr)
        return 1

    # N13: staging hoisted above the artifact proofs must red.
    doctored, removed = doctor(
        "early stage (removal)",
        text,
        r"(?m)^    if not apk_icon_verify\(apk\):\n        return False\n",
        "",
    )
    doctored, inserted = doctor(
        "early stage (insertion)",
        doctored,
        r"(?m)^(    if run\(\[str\(ROOT / \"tools/build-id\.py\"\), "
        r"\"--verify\",\n)",
        "    if not apk_icon_verify(apk):\n        return False\n\\1",
    )
    if removed != 1 or inserted != 1 or staging_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (stage before "
              "artifact proof read as good)", file=sys.stderr)
        return 1

    # N14: a second staging barrier must red.
    doctored, n = doctor(
        "duplicate stage",
        text,
        re.escape("    return stage_suite_apk(suite, apk, package, "
                  "targets)"),
        "    stage_suite_apk(suite, apk, package, targets)\n"
        "    return stage_suite_apk(suite, apk, package, targets)",
    )
    if n != 1 or staging_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (duplicate stage read "
              "as good)", file=sys.stderr)
        return 1

    # N15: a wrong IME census in the lane module must red.
    doctored, n = doctor(
        "IME scene census",
        lane_text,
        r'(?m)^IME_SCENES = \["ranges"\]$',
        'IME_SCENES = ["ordinary"]',
    )
    bad_ns = load_lane(doctored)
    if n != 1 or bad_ns is None or ime_problem(text, bad_ns) is None:
        print("android-leg-order: SELF-TEST FAIL (wrong IME scene "
              "census read as good)", file=sys.stderr)
        return 1

    # N16..: each worker order marker removed must red.
    for index, marker in enumerate(IME_ORDER_MARKERS, 1):
        doctored, n = doctor(f"IME order {index}", text,
                             re.escape(marker), "pass  #")
        if n != 1 or ime_problem(doctored, lane_ns) is None:
            print(f"android-leg-order: SELF-TEST FAIL (missing IME "
                  f"order step {index} read as good)", file=sys.stderr)
            return 1

    # N17: an IME failure that bypasses the verdict path must red.
    doctored, n = doctor(
        "IME cleanup bypass",
        text,
        r"(?m)^                ready = False$",
        "                sys.exit(1)",
    )
    if n != 1 or ime_problem(doctored, lane_ns) is None:
        print("android-leg-order: SELF-TEST FAIL (IME failure "
              "bypassing cleanup read as good)", file=sys.stderr)
        return 1

    # N18: a suite-wide IME call outside the worker must red.
    doctored, n = doctor(
        "suite IME call",
        text,
        r"(?m)^(    drain\(\)\n)",
        "    select_helper_ime(serial, log)\n\\1",
    )
    if n != 1 or ime_problem(doctored, lane_ns) is None:
        print("android-leg-order: SELF-TEST FAIL (suite-wide IME call "
              "read as good)", file=sys.stderr)
        return 1

    # N19: a second drain must red — the one drain is the suite's close.
    doctored, n = doctor(
        "extra drain",
        text,
        r"(?m)^(    drain\(\)\n)",
        "    drain()\n\\1",
    )
    if n != 1 or ime_problem(doctored, lane_ns) is None:
        print("android-leg-order: SELF-TEST FAIL (second drain read as "
              "good)", file=sys.stderr)
        return 1

    # N20/N21: a roster missing its ranges or editor leg must red.
    for leg, label in (("ranges-compose", "ranges roster"),
                       ("editor-go", "editor roster")):
        doctored, n = doctor(label, lane_text,
                             re.escape(f'"{leg}",'), "")
        bad_ns = load_lane(doctored)
        if n != 1 or bad_ns is None or ime_problem(text, bad_ns) is None:
            print(f"android-leg-order: SELF-TEST FAIL ({label} loss "
                  f"read as good)", file=sys.stderr)
            return 1

    # N22: the startup hygiene sweep removed must red.
    doctored, n = doctor(
        "hygiene",
        text,
        r"(?m)^for _serial in \[\*SERIALS, TABLET_SERIAL\]:\n"
        r"    if not a11y_hygiene\(_serial\):\n"
        r"        sys\.exit\(1\)\n",
        "",
    )
    if n != 1 or hygiene_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (missing startup "
              "hygiene read as good)", file=sys.stderr)
        return 1

    # N23: an unguarded ordinary-leg disarm must red.
    doctored, n = doctor(
        "ordinary-leg disarm",
        body,
        r"if needs_a11y and not (a11y_disarm\(serial, package, a11y, "
        r"out=log\):\s*return False)",
        r"if not \1",
    )
    if n != 1 or guarded_disarm_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (ordinary-leg device "
              "query read as good)", file=sys.stderr)
        return 1

    # N24: the post-leg disarm hoisted above am start must red.
    post_pattern = (
        r"(?m)^    if needs_a11y and not a11y_disarm\(serial, package, "
        r"a11y, out=log\):\n        failed = True\n"
    )
    post_match = re.search(post_pattern + r"    return not failed", body)
    doctored, removed = re.subn(post_pattern + r"    return not failed",
                                "    return not failed", body, count=1)
    inserted = 0
    if post_match is not None:
        doctored, inserted = re.subn(
            r'(?m)^(    adb\(serial, "shell", "am", "start", "-W", '
            r'"-n", component,)',
            post_match.group(0).rstrip("\n").replace("\\", "\\\\")
            + "\n\\1",
            doctored,
            count=1,
        )
    print(f"android-leg-order: early post-disarm self-test applied "
          f"{removed} removal(s), {inserted} insertion(s)")
    if removed != 1 or inserted != 1 \
            or guarded_disarm_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (early post-leg "
              "disarm read as good)", file=sys.stderr)
        return 1

    # N25: per-leg hygiene must red the once-per-run rule.
    doctored, n = doctor(
        "per-leg hygiene",
        text,
        r"(?m)^(    failed = False\n)",
        "\\1    a11y_hygiene(serial)\n",
    )
    if n != 1 or hygiene_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (per-leg hygiene read "
              "as good)", file=sys.stderr)
        return 1

    # N26: a hygiene that disarms before matching the component route
    # must red.
    doctored, n = doctor(
        "hygiene route",
        text,
        r'if component\.endswith\("/dev\.kaya\.KayaHarnessAccessibility"'
        r"\):",
        "if component:",
    )
    if n != 1 or hygiene_problem(doctored) is None:
        print("android-leg-order: SELF-TEST FAIL (unmatched stale "
              "service read as routed)", file=sys.stderr)
        return 1

    # N27: an emptied roster must hit the census floor.
    doctored, n = doctor(
        "roster floor",
        lane_text,
        r"(?s)LEGS = \{.*?\n\}",
        'LEGS = {"compose": [], "jvm": [], "go": [], "python": []}',
    )
    bad_ns = load_lane(doctored)
    if n != 1 or bad_ns is None or len(bad_ns["legs"]()) >= 100:
        print("android-leg-order: SELF-TEST FAIL (an empty roster "
              "passed the floor)", file=sys.stderr)
        return 1

    return status


if __name__ == "__main__":
    sys.exit(main())
