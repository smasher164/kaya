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
# of these constraints were MEASURED.
PROBE = ROOT / "tools" / "android" / "pickerprobe" / "run.sh"
SCENES = ROOT / "tools" / "scenes"
PICKER_VERB = re.compile(
    r"^(?:file_dialog_goto|expect_file_dialog|file_choose|"
    r"expect_save_dialog|file_dialog_name|file_save|expect_toast_announced)\b",
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
        "restore touch mode",
        r"if not restore_touch_mode\(serial, log\):\s*return False",
        "any key event (`press`'s `input keyevent`, the reply path's "
        "`input text`) leaves the display out of touch mode for every "
        "later leg, and there DocumentsUI's save picker raises the "
        "keyboard and spends the cancel door's one Back on it; it must "
        "follow the picker's force-stop so the touch lands on no picker",
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
# The worker's slot/IME/verdict order: claim, the device's adb state,
# slot-local IME assert, launch, release, verdict.
IME_ORDER_MARKERS = [
    "slot = _claim_device()",
    "ready = device_online(serial, log)",
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


STORAGE_RELEASE = "release_pinned_apks(serial, slog)"
STORAGE_PREFLIGHT = ("for _serial in [*SERIALS, TABLET_SERIAL]:\n"
                     "    storage_preflight(_serial)\n")


def storage_problem(text: str) -> str | None:
    """docs/traps.md: The emulator launcher pins every replaced APK"""
    stage = py_function(text, "stage_suite_apk")
    release = py_function(text, "release_pinned_apks")
    preflight = py_function(text, "storage_preflight")
    if stage is None or release is None or preflight is None:
        return ("stage_suite_apk, release_pinned_apks or storage_preflight "
                "is missing or unreadable")
    if stage.count(STORAGE_RELEASE) != 1:
        return ("every suite install must release the APKs the launcher "
                "pins, once per target, inside stage_suite_apk")
    reread = stage.find('"pm", "list",')
    release_at = stage.find(STORAGE_RELEASE)
    verdict_at = stage.find('target_verdict = "OK"')
    if not reread < release_at < verdict_at:
        return ("the launcher's pins must be released after the install is "
                "re-read and before the target's OK — a release before the "
                "install frees nothing the install is about to pin")
    if '"am", "force-stop", LAUNCHER' not in release:
        return "release_pinned_apks no longer force-stops the launcher"
    if not re.search(r"if free < STORAGE_FLOOR_MB:\s*die\(", preflight):
        return "storage_preflight no longer refuses a device under the floor"
    if text.count(STORAGE_PREFLIGHT) != 1:
        return ("the lane must read every device's free /data, tablet "
                "included, once at its start")
    first_install = text.find("if not cliphelper_prepare(_serial):")
    if first_install < 0 or text.find(STORAGE_PREFLIGHT) > first_install:
        return ("the storage preflight must run before the lane's first "
                "install (the clipboard helper's)")
    return None


UPRIGHT_LEG = ('    upright = hold_upright(serial, log, "leg start")\n'
               "    if not upright:\n        failed = True\n")
UPRIGHT_START = ["def upright_at_lane_start(serial):",
                 '"am", "start", "-W", "-n", SETTINGS_ACTIVITY,',
                 'hold_upright(serial, sys.stdout, "lane start")',
                 '"am", "force-stop", SETTINGS_ACTIVITY.split("/")[0],']
UPRIGHT_SWEEP = ("_upright = [threading.Thread(target=upright_at_lane_start, "
                 "args=(_serial,))\n"
                 "            for _serial in [*SERIALS, TABLET_SERIAL]]\n")


def upright_problem(text: str) -> str | None:
    """docs/traps.md: A rotation put back from the home screen comes back"""
    hold = py_function(text, "hold_upright")
    body = py_function(text, "run_apk_on")
    start = py_function(text, "upright_at_lane_start")
    if hold is None or body is None or start is None:
        return ("hold_upright, upright_at_lane_start or run_apk_on is "
                "missing or unreadable")
    reads = re.findall(r'"cmd", "window",\s*"user-rotation"\)', hold)
    if len(reads) != 2 or "user_rotation" in hold:
        return ("hold_upright must read the window manager's own "
                "`cmd window user-rotation`, before and after its write, "
                "and never the settings provider's user_rotation, which "
                "the launcher's override answers 0 for a turned device")
    if '"user-rotation", "lock", "0",' not in hold:
        return "hold_upright no longer puts the rotation back to lock 0"
    if body.count(UPRIGHT_LEG) != 1:
        return ("run_apk_on must read the rotation once per leg and fail "
                "the leg it found turned")
    if body.count("for _ in range(240 if upright else 0):") != 1:
        return ("a leg found turned must skip its poll: after the put-back "
                "rangertl and filedialog never answered and polled 134 s")
    launch = body.find('adb(serial, "shell", "am", "start", "-W", "-n", '
                       "component,")
    poll = body.find("for _ in range(240 if upright else 0):")
    if not 0 <= launch < body.find(UPRIGHT_LEG) < poll:
        return ("the per-leg rotation read must follow the leg's `am start "
                "-W` and precede its poll: before the launch the launcher "
                "is in front and the reading is lock 0 whatever the device "
                "holds")
    positions = [start.find(m) for m in UPRIGHT_START]
    if any(p < 0 for p in positions) or positions != sorted(positions):
        return ("upright_at_lane_start must read the rotation with Settings "
                "(an unspecified-orientation activity) in front, then stop it")
    sweep = text.find(UPRIGHT_SWEEP)
    if text.count(UPRIGHT_SWEEP) != 1 or not \
            text.find(start) < sweep < text.find("def run_apk_on("):
        return ("every device, tablet included, must be put upright once at "
                "the lane's start")
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
    problem = drain_problem(text)
    if problem is not None:
        return problem
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


# THE POOL DRAINS ONCE (docs/traps.md, the android pool's suite drains): a
# suite queues its pooled legs and returns, so the next suite's build and
# staging overlap its last legs; every suite's EXCLUSIVE and ALONE legs run
# after that one drain, and a device is claimed like a leg's before it is
# staged.
ISOLATED_ROUTE = ("        if leg in lane.EXCLUSIVE or leg in lane.ALONE:\n"
                  "            _isolated.append(leg_args)\n"
                  "        else:\n"
                  "            queue_leg(*leg_args)\n")
LANE_TAIL = ("    run_suite_legs(_suite)\n"
             "    _staged.append(_suite)\n"
             "drain()\n"
             'timing("legs-pooled")\n'
             "for _leg_args in _isolated:\n"
             "    queue_leg(*_leg_args)\n"
             "drain()\n")
STAGE_CLAIM_ORDER = ["with staging_claim(serial):", "stage_on(serial)",
                     "def stage_on(serial):", '"install", "-r", str(apk),']
CLAIM_BRACKET = ["_tablet_lock.acquire()", "_claim_device({slot})", "yield",
                 "_tablet_lock.release()", "_release_device(slot)"]


def drain_problem(text: str) -> str | None:
    legs_fn = py_function(text, "run_suite_legs")
    if legs_fn is None:
        return "run_suite_legs is missing or unreadable"
    if "drain()" in legs_fn:
        return ("run_suite_legs drains the pool: a suite queues its pooled "
                "legs and returns, and the lane drains once")
    if legs_fn.count(ISOLATED_ROUTE) != 1 or legs_fn.count("queue_leg(") != 1:
        return ("run_suite_legs must send every EXCLUSIVE and ALONE leg to "
                "_isolated and queue only the pooled ones")
    if len(re.findall(r"(?m)^ *drain\(\)$", text)) != 2 \
            or text.count(LANE_TAIL) != 1:
        return ("the lane must drain its pooled legs once, then run the "
                "isolated legs, then drain again")
    stage = py_function(text, "stage_suite_apk")
    if stage is None:
        return "stage_suite_apk is missing or unreadable"
    claim = py_function(text, "staging_claim")
    positions = [stage.find(m) for m in STAGE_CLAIM_ORDER]
    bracket = [claim.find(m) for m in CLAIM_BRACKET] if claim else [-1]
    if any(pos < 0 for pos in positions + bracket) \
            or positions != sorted(positions) or bracket != sorted(bracket):
        return ("stage_suite_apk must claim each phone's slot before it "
                "stages there and release it after: the previous suite's "
                "legs may still be running")
    return None


def steps_problems(body: str) -> list[str]:
    found = []
    for label, pattern, why in STEPS:
        match = re.search(pattern, body)
        if match is None:
            return [f"no `{label}` step in run_apk_on — either it was "
                    f"removed or its spelling changed, and this gate can "
                    f"no longer police the order it sits in"]
        found.append((match.start(), label, why))
    problems = []
    for i in range(1, len(found)):
        if found[i][0] > found[i - 1][0]:
            continue
        _, label, why = found[i]
        prev = found[i - 1][1]
        problems.append(f"`{label}` comes BEFORE `{prev}` in run_apk_on, "
                        f"and it must come after: {why}.")
    return problems


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
    problem = storage_problem(text)
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
    problem = upright_problem(text)
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
            f"with the shared verbs that need the service (missing={missing}, "
            f"extra={extra}); a missing scene launches DocumentsUI "
            "without the service, while an extra one restores the "
            "all-leg setup cost",
            file=sys.stderr,
        )
        return 1

    problems = steps_problems(body)
    for problem in problems:
        print(f"android-leg-order: {problem}", file=sys.stderr)
    if problems and problems[0].startswith("no `"):
        return 1
    status = 1 if problems else 0

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

    # ---- every clause watched red, counts printed, an unchanged text
    # ---- a failed test.
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
        r'(?m)^IME_SCENES = \["ranges", "richtext"\]$',
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
        r"(?m)^(drain\(\)\ntiming\(\"legs-pooled\"\)\n)",
        "select_helper_ime(serial, log)\n\\1",
    )
    if n != 1 or ime_problem(doctored, lane_ns) is None:
        print("android-leg-order: SELF-TEST FAIL (suite-wide IME call "
              "read as good)", file=sys.stderr)
        return 1

    # N19a..e: the per-suite drain back, an isolated leg queued in the pool,
    # the isolated block above the pooled drain, a stage with no claim, and
    # a claim around nothing must each red.
    drain_cuts = [
        ("per-suite drain", r'(?m)^(    timing\(f"queued-\{suite\}"\)\n)',
         "    drain()\n\\1"),
        ("isolated leg pooled", re.escape("            _isolated.append(leg_args)\n"),
         "            queue_leg(*leg_args)\n"),
        ("isolated block before the drain",
         r'(?m)^drain\(\)\ntiming\("legs-pooled"\)\n(for _leg_args in _isolated:\n'
         r"    queue_leg\(\*_leg_args\)\n)",
         '\\1drain()\ntiming("legs-pooled")\n'),
        ("stage with no claim",
         re.escape("        with staging_claim(serial):\n            stage_on(serial)\n"),
         "        stage_on(serial)\n"),
        ("a claim that takes no slot", re.escape("        _claim_device({slot})\n"),
         "        pass\n"),
        ("a claim that never releases", r"(?m)^ {12}_release_device\(slot\)\n",
         "            pass\n"),
    ]
    for label, pattern, repl in drain_cuts:
        doctored, n = doctor(label, text, pattern, repl)
        problem = ime_problem(doctored, lane_ns)
        if n != 1 or problem is None:
            print(f"android-leg-order: SELF-TEST FAIL ({label} read as "
                  f"good)", file=sys.stderr)
            return 1
        print(f"android-leg-order: {label} -> {problem}")

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

    # N28/N29: the touch-mode restore removed, then moved above the
    # picker's force-stop, must each red the steps clause.
    restore = ("    if not restore_touch_mode(serial, log):\n"
               "        return False\n")
    doctored, n = doctor("touch-mode restore removed", body,
                         re.escape(restore), "")
    if n != 1 or not steps_problems(doctored):
        print("android-leg-order: SELF-TEST FAIL (a leg with no "
              "touch-mode restore read as good)", file=sys.stderr)
        return 1
    picker_loop = '    for picker in ("com.google.android.documentsui",\n'
    moved = body.replace(restore, "", 1)
    removed = int(moved != body)
    doctored, n = doctor("touch-mode restore moved", moved,
                         re.escape(picker_loop),
                         (restore + picker_loop).replace("\\", r"\\"))
    if n != 1 or removed != 1 or not any(
            "`restore touch mode` comes BEFORE" in p
            for p in steps_problems(doctored)):
        print("android-leg-order: SELF-TEST FAIL (a restore above the "
              "picker's force-stop read as good)", file=sys.stderr)
        return 1

    # N30..N35: each storage link cut, or moved, must red the clause.
    def move(label, source, piece, before):
        cut = source.replace(piece, "", 1)
        indent = before[:len(before) - len(before.lstrip(" "))]
        moved = cut.replace(before, indent + piece.lstrip(" ") + before, 1)
        n = int(cut != source and moved != cut)
        print(f"android-leg-order: {label} self-test applied {n} move(s)")
        return moved, n

    release_line = "                    release_pinned_apks(serial, slog)\n"
    reread_line = "                pkgs = adb_out(serial, \"shell\", \"pm\", \"list\",\n"
    storage_cuts = [
        ("storage release removed",
         lambda l: doctor(l, text, re.escape(release_line), "")),
        ("storage release above the re-read",
         lambda l: move(l, text, release_line, reread_line)),
        ("launcher force-stop removed",
         lambda l: doctor(l, text, re.escape('"am", "force-stop", LAUNCHER'),
                          '"am", "force-stop", "com.example.none"')),
        ("storage floor refusal removed",
         lambda l: doctor(l, text, r"if free < STORAGE_FLOOR_MB:",
                          "if free < 0:")),
        ("storage preflight removed",
         lambda l: doctor(l, text, re.escape(STORAGE_PREFLIGHT), "")),
        ("storage preflight below the first install",
         lambda l: move(l, text, STORAGE_PREFLIGHT,
                        'timing("cliphelper")\n')),
    ]
    for label, cut in storage_cuts:
        doctored, n = cut(label)
        problem = storage_problem(doctored)
        if n != 1 or problem is None:
            print(f"android-leg-order: SELF-TEST FAIL ({label} read as "
                  f"good)", file=sys.stderr)
            return 1
        print(f"android-leg-order: {label} -> {problem}")

    # N36..N42: each rotation link cut, swapped or moved must red.
    upright_cuts = [
        ("per-leg rotation read removed",
         lambda l: doctor(l, text, re.escape(UPRIGHT_LEG), "")),
        ("per-leg rotation read above am start",
         lambda l: move(l, text, UPRIGHT_LEG,
                        '    adb(serial, "shell", "am", "start", "-W", '
                        '"-n", component, "--es",\n')),
        ("rotation read from the settings provider",
         lambda l: doctor(l, text, r'"cmd", "window",\n(\s*)"user-rotation"\)',
                          '"settings", "get",\\n\\1"system", "user_rotation")')),
        ("rotation never put back",
         lambda l: doctor(l, text, re.escape('"user-rotation", "lock", "0",'),
                          '"user-rotation",')),
        ("lane-start read with the launcher in front",
         lambda l: doctor(l, text,
                          r'(?m)^    adb\(serial, "shell", "am", "start", '
                          r'"-W", "-n", SETTINGS_ACTIVITY,\n.*\n', "")),
        ("turned leg still polls",
         lambda l: doctor(l, text, re.escape("range(240 if upright else 0)"),
                          "range(240)")),
        ("lane-start sweep removed",
         lambda l: doctor(l, text, re.escape(UPRIGHT_SWEEP), "_upright = []\n")),
    ]
    for label, cut in upright_cuts:
        doctored, n = cut(label)
        problem = upright_problem(doctored)
        if n != 1 or problem is None:
            print(f"android-leg-order: SELF-TEST FAIL ({label} read as "
                  f"good)", file=sys.stderr)
            return 1
        print(f"android-leg-order: {label} -> {problem}")

    return status


if __name__ == "__main__":
    sys.exit(main())
