"""The Android stage, slot, and per-leg setup have load-bearing order.

Each constraint, and what it cost, is in docs/traps.md; the STEPS table
below carries the reason for every per-leg pair. None of it is visible at
the call site — each line is a plausible adb command in a plausible place,
and the failure surfaces much later as "the picker never appeared" or as a
duration anomaly.

Text, not execution: this reads the shell rather than running it, so it
cannot see an order produced dynamically. That is the honest limit, and
it still catches a line moved to a reasonable-looking wrong place.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNNER = ROOT / "tools" / "android" / "run-emulator.sh"
# The probe keeps the same order for the same reasons, and is where two of
# these constraints were MEASURED.
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
        r'if \[ "\$needs_a11y" = 1 \]; then\s*'
        r'a11y_disarm "\$serial" "\$package" "\$a11y"',
        "a previous picker may have left the service enabled; it must be "
        "disabled, unbound, and gone before the app is force-stopped and "
        "re-armed, but ordinary scenes must not pay a device query",
    ),
    (
        "force-stop",
        r"adb -s \"\$serial\" shell am force-stop \"\$package\"",
        "a leftover process from the previous leg would answer for this one",
    ),
    (
        "force-stop the picker",
        r"am force-stop \"\$picker\"",
        "DocumentsUI is a different package and survives the app's "
        "force-stop; left standing it sits on top of the app's task, and "
        "the next `am start` brings that task forward instead of starting "
        "the activity — no onCreate, no scene, and it reads as a clean run",
    ),
    (
        "logcat -c",
        r"adb -s \"\$serial\" logcat -c",
        "the force-stop's own noise must not land in this leg's verdict",
    ),
    (
        "picker-scene accessibility guard",
        r'if \[ "\$needs_a11y" = 1 \]; then\s*'
        r'while \[ "\$arm" -lt 3 \]',
        "only scenes that leave the app for DocumentsUI need the service; "
        "arming ordinary legs adds a dozen adb round trips to every leg",
    ),
    (
        "enable accessibility",
        r"settings put secure enabled_accessibility_services \"\$a11y\"",
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
        r"adb -s \"\$serial\" shell am start",
        "the app must not run before the service that watches it is up",
    ),
]

# `am start -S` force-stops the package before starting it, taking the
# accessibility service down with it (docs/traps.md). It looks like the
# fix for the stale-task problem above, which is why it needs saying.
FORBIDDEN_START_FLAG = re.compile(r"am start\b[^\n]*\s-S\b")
FORBIDDEN_EMPTY_SETTING = re.compile(
    r"settings put secure enabled_accessibility_services \"\""
)
STAGE_REQUIRED = [
    'compose) expected=$((POOL + 1))',
    'jvm|go|python) expected=$POOL',
    'if [ "${#targets[@]}" -ne "$expected" ]; then',
    'if [ "${targets[$i]}" = "${targets[$j]}" ]; then',
    'for serial in "${targets[@]}"; do',
    'target_verdict=OK',
    'printf \'%s\\n\' "$target_verdict" >"$stage_dir/$serial.verdict"',
    'stage_pids+=($!)',
    'launched=${#stage_pids[@]}',
    'wait "${stage_pids[@]}" 2>/dev/null || true',
    'if [ -f "$stage_dir/$serial.verdict" ]; then',
    '[ "$verdict" = OK ] && passed=$((passed + 1))',
    'echo "stage-$label-$serial: $verdict"',
    'if [ "$launched" -ne "$expected" ] || [ "$observed" -ne "$expected" ]; then',
    'if [ "$passed" -ne "$expected" ]; then',
    'echo "stage-$label: OK ($passed/$expected targets)"',
]
IME_ORDER_MARKERS = [
    'if mkdir "$LEGS_DIR/.dev-$i"',
    'select_helper_ime "$serial"',
    'if [ "$ready" = 1 ] && run_apk_on "$serial"',
    'rmdir "$LEGS_DIR/.dev-$slot"',
    'echo "$verdict" >"$LEGS_DIR/$name.verdict"',
]


def no_restart_flag(label: str, text: str, quiet: bool = False) -> int:
    """`-S` on any `am start` in this text is a failure."""
    hit = FORBIDDEN_START_FLAG.search(text)
    if hit is None:
        return 0
    if quiet:
        return 1
    print(
        f"android-leg-order: {label} runs `am start -S` ({hit.group(0).strip()!r}). "
        f"-S force-stops the package first, and the harness accessibility "
        f"service lives in that process — it kills the service the bind check "
        f"just confirmed, and the activity comes up where it is not watching. "
        f"Force-stop the picker's package instead; that is the stale task.",
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
        f"android-leg-order: {label} uses `{hit.group(0)}` to clear the harness "
        f"service. Android prints `Bad arguments` and leaves the old component "
        f"enabled, so package replacement can resurrect it after force-stop. "
        f"Use `settings delete secure enabled_accessibility_services`.",
        file=sys.stderr,
    )
    return 1


def hygiene_problem(text: str) -> str | None:
    body = re.search(r"a11y_hygiene\(\) \{(.*?)\n\}", text, re.DOTALL)
    if body is None:
        return "a11y_hygiene is missing"
    route = re.search(
        r'IFS=: read -r -a components <<<"\$enabled"\s*'
        r'for component in "\$\{components\[@\]\}"; do\s*'
        r'case "\$component" in\s*'
        r'\*/dev\.kaya\.KayaHarnessAccessibility\)\s*'
        r'package="\$\{component%%/\*\}"\s*'
        r'a11y_disarm "\$serial" "\$package" "\$component" \|\| return 1\s*'
        r';;\s*esac\s*done',
        body.group(1),
    )
    if (
        "settings get secure enabled_accessibility_services" not in body.group(1)
        or route is None
    ):
        return "a11y_hygiene no longer reads and retires a stale harness service"
    invocations = re.findall(r"\ba11y_hygiene(?=\s+[\"$])", text)
    if len(invocations) != 1:
        return "a11y_hygiene must run exactly once, in the startup device sweep"
    call = re.search(
        r'for serial in "\$\{SERIALS\[@\]\}" "\$TABLET_SERIAL"; do\s*'
        r'a11y_hygiene "\$serial" \|\| exit 1\s*done',
        text,
    )
    run = text.find("run_apk_on() {")
    if call is None or run < 0 or call.start() < body.end() or call.start() > run:
        return "every device must complete a11y_hygiene before run_apk_on"
    return None


def guarded_disarm_problem(body: str) -> str | None:
    call = r'a11y_disarm "\$serial" "\$package" "\$a11y"'
    calls = list(re.finditer(call, body))
    pre = re.findall(
        r'if \[ "\$needs_a11y" = 1 \]; then\s*'
        + call
        + r' \|\| return 1\s*fi',
        body,
    )
    post = re.findall(
        r'if \[ "\$needs_a11y" = 1 \] && ! '
        + call
        + r'; then\s*failed=1\s*fi\s*'
        r'\[ "\$failed" = 0 \]\s*\n}',
        body,
    )
    if len(calls) != 2:
        return "run_apk_on must contain exactly two accessibility disarm calls"
    if len(pre) != 1:
        return "the picker pre-leg disarm must remain guarded"
    if len(post) != 1:
        return "the picker post-leg disarm must be the final action before verdict"
    return None


def shell_function(text: str, name: str) -> str | None:
    start = text.find(f"{name}() {{")
    if start < 0:
        return None
    end = text.find("\n}\n", start)
    if end < 0:
        return None
    return text[start : end + 3]


def suite_blocks(text: str) -> dict[str, str] | None:
    starts = {
        name: text.find(f'if [ "$SUITE" = {name} ] || [ "$SUITE" = all ]; then')
        for name in ("compose", "jvm", "go", "python")
    }
    if any(pos < 0 for pos in starts.values()):
        return None
    end = text.find('\nexit "$status"', starts["python"])
    if not (starts["compose"] < starts["jvm"] < starts["go"] < starts["python"] < end):
        return None
    return {
        "compose": text[starts["compose"] : starts["jvm"]],
        "jvm": text[starts["jvm"] : starts["go"]],
        "go": text[starts["go"] : starts["python"]],
        "python": text[starts["python"] : end],
    }


def staging_problem(text: str) -> str | None:
    body = shell_function(text, "stage_suite_apk")
    run_body = shell_function(text, "run_apk_on")
    if body is None:
        return "stage_suite_apk is missing or unreadable"
    if run_body is None:
        return "run_apk_on is missing or unreadable"
    if ": PASS" in body:
        return "APK staging must not print the scene-leg PASS marker"
    install = 'adb -s "$serial" install -r "$apk"'
    if text.count(install) != 1 or install not in body:
        return "the suite APK must be installed exactly once, inside stage_suite_apk"
    if " install -r " in run_body:
        return "run_apk_on still installs an APK per leg"
    adjacency = re.search(
        r'if a11y_disarm "\$serial" "\$package" "\$a11y" \\\s*'
        r'&& adb -s "\$serial" install -r "\$apk" >/dev/null; then',
        body,
    )
    if adjacency is None:
        return "each target must disarm its stale service immediately before install"
    missing = [
        item
        for item in STAGE_REQUIRED
        if body.count(item) != (2 if item == 'for serial in "${targets[@]}"; do' else 1)
    ]
    if missing:
        return f"stage_suite_apk lost its target/verdict refusal: {missing[0]}"
    blocks = suite_blocks(text)
    if blocks is None:
        return "the three Android suite blocks are missing or out of order"
    specs = {
        "compose": (
            "android/milestone2/build/outputs/apk/debug/milestone2-debug.apk",
            "dev.kaya.milestone2",
            '"${SERIALS[@]}" "$TABLET_SERIAL"',
        ),
        "jvm": (
            "android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk",
            "dev.kaya.milestone2kt",
            '"${SERIALS[@]}"',
        ),
        "go": (
            "android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk",
            "dev.kaya.milestone2go",
            '"${SERIALS[@]}"',
        ),
        "python": (
            "android/pyhost/build/outputs/apk/debug/pyhost-debug.apk",
            "dev.kaya.pyhost",
            '"${SERIALS[@]}"',
        ),
    }
    for name, block in blocks.items():
        apk, package, targets = specs[name]
        call_text = (
            f"stage_suite_apk {name} \\\n"
            f'        "$ROOT/{apk}" \\\n'
            f"        {package} {targets} || exit 1"
        )
        call_pos = block.find(call_text)
        if call_pos < 0:
            suffix = "phones plus tablet" if name == "compose" else "the phone pool"
            return f"{name} is not staged once on {suffix}"
        if len(re.findall(rf'\bstage_suite_apk {name}\b', block)) != 1:
            return f"{name} must have exactly one staging barrier"
        # The three original tiers open with the suite-named default leg
        # (KAYA_SELFTEST=1, milestone2's app); the python tier has no
        # default arm BY DESIGN — its dispatcher (tools/pyhost-main.py)
        # keys on scene names — so its anchor is its first scene leg.
        first_leg = "run_apk varied-python " if name == "python" else f"run_apk {name} "
        markers = [
            block.find('"$ROOT/tools/build-id.sh" --verify --component compose'),
            block.find("apk_icon_verify"),
            block.find("apk_assets_verify"),
            call_pos,
            block.find(first_leg),
        ]
        if any(pos < 0 for pos in markers) or markers != sorted(markers):
            return f"{name} staging must follow every artifact verification and precede its first leg"
    return None


def ime_problem(text: str) -> str | None:
    declared = re.search(r'^IME_SCENES="([^"]*)"$', text, re.MULTILINE)
    if declared is None:
        return "IME_SCENES is missing"
    actual = set(declared.group(1).split())
    expected = {
        path.stem
        for path in SCENES.glob("*.steps")
        if COMPOSING_VERB.search(path.read_text()) is not None
    }
    if actual != expected:
        return f"IME_SCENES disagrees with shared compose verbs (wanted={sorted(expected)}, got={sorted(actual)})"
    body = shell_function(text, "run_apk")
    if body is None:
        return "run_apk is missing or unreadable"
    call = re.findall(
        r'if \[ "\$needs_ime" = 1 \] && ! select_helper_ime "\$serial"; then\s*'
        r'ready=0\s*fi',
        body,
    )
    if len(call) != 1:
        return "slot-local IME preparation must fail through the normal leg verdict path"
    positions = [body.find(marker) for marker in IME_ORDER_MARKERS]
    if any(pos < 0 for pos in positions) or positions != sorted(positions):
        return "IME preparation must sit after slot claim, before launch, and preserve slot cleanup/verdict"
    invocations = re.findall(r'(?m)^(?!select_helper_ime\(\)).*select_helper_ime "\$serial".*$', text)
    if len(invocations) != 1:
        return "select_helper_ime must be invoked once from the slot-local worker only"
    blocks = suite_blocks(text)
    if blocks is None:
        return "the three Android suite blocks are missing or out of order"
    for name, block in blocks.items():
        drains = list(re.finditer(r"(?m)^    drain$", block))
        if len(drains) != 1:
            return f"{name} must have one final drain, found {len(drains)}"
        runs = list(re.finditer(r"(?m)^    run_apk(?:_tablet)? ", block))
        if not runs or drains[0].start() < runs[-1].start():
            return f"{name}'s only drain must follow its last submitted leg"
        # The python suite's roster is varied alone until the portfolio's
        # ledgered android entry closes (docs/deferred.md); no python
        # scene here needs the IME, so the ranges anchor is the three
        # original suites' rule.
        if name != "python" and f"run_apk ranges-{name} " not in block:
            return f"{name} no longer submits its ranges leg through run_apk"
    go = blocks["go"]
    if go.find("run_apk editor-go ") > go.find("\n    drain\n"):
        return "editor-go must join the Go queue before its final drain"
    return None


def main() -> int:
    if not RUNNER.exists():
        print(f"android-leg-order: {RUNNER} is missing", file=sys.stderr)
        return 1
    text = RUNNER.read_text()

    body = shell_function(text, "run_apk_on")
    if body is None:
        print(
            "android-leg-order: run_apk_on() not found — the runner's shape "
            "moved and this gate went vacuous",
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
    problem = ime_problem(text)
    if problem is not None:
        print(f"android-leg-order: {problem}", file=sys.stderr)
        return 1
    problem = guarded_disarm_problem(body)
    if problem is not None:
        print(f"android-leg-order: {problem}", file=sys.stderr)
        return 1

    declared_match = re.search(r'^A11Y_SCENES="([^"]*)"$', text, re.MULTILINE)
    if declared_match is None:
        print(
            "android-leg-order: A11Y_SCENES is missing — the runner no longer "
            "declares which scenes need DocumentsUI eyes",
            file=sys.stderr,
        )
        return 1
    declared_scenes = set(declared_match.group(1).split())
    picker_scenes = {
        path.stem
        for path in SCENES.glob("*.steps")
        if PICKER_VERB.search(path.read_text()) is not None
    }
    if declared_scenes != picker_scenes:
        missing = sorted(picker_scenes - declared_scenes)
        extra = sorted(declared_scenes - picker_scenes)
        print(
            "android-leg-order: A11Y_SCENES disagrees with the shared picker "
            f"verbs (missing={missing}, extra={extra}); a missing scene launches "
            "DocumentsUI without the service, while an extra one restores the "
            "all-leg setup cost",
            file=sys.stderr,
        )
        return 1

    found = []
    for label, pattern, why in STEPS:
        match = re.search(pattern, body)
        if match is None:
            print(
                f"android-leg-order: no `{label}` step in run_apk_on — either it "
                f"was removed or its spelling changed, and this gate can no "
                f"longer police the order it sits in",
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
            f"android-leg-order: `{label}` comes BEFORE `{prev}` in run_apk_on, "
            f"and it must come after: {why}.",
            file=sys.stderr,
        )
        status = 1

    status |= no_restart_flag("run_apk_on", body)
    status |= no_empty_setting("run-emulator", text)

    # The probe is policed for the flag but not for the order: its reset
    # is a loop over variants rather than run_apk_on's shape. Absent is
    # fine — it is a probe, and may be deleted.
    if PROBE.exists():
        status |= no_restart_flag(str(PROBE.relative_to(ROOT)), PROBE.read_text())

    # The gate guards itself: a shuffled body must be caught.
    shuffled = "run_apk_on() {\n" + "\n".join(
        [
            'adb -s "$serial" shell am force-stop "$package"',
            'if [ "$needs_a11y" = 1 ]; then\n'
            'a11y_disarm "$serial" "$package" "$a11y"\nfi',
        ]
    )
    positions = [
        re.search(pattern, shuffled) for _, pattern, _ in [STEPS[0], STEPS[1]]
    ]
    if positions[0] is None or positions[1] is None:
        print("android-leg-order: SELF-TEST FAIL (patterns did not match)", file=sys.stderr)
        return 1
    if positions[0].start() < positions[1].start():
        print("android-leg-order: SELF-TEST FAIL (bad order read as good)", file=sys.stderr)
        return 1

    # And the flag rule guards itself, both directions.
    if no_restart_flag("self-test", 'adb -s "$s" shell am start -S -W -n "$c"', True) == 0:
        print("android-leg-order: SELF-TEST FAIL (`am start -S` read as good)", file=sys.stderr)
        return 1
    if no_restart_flag("self-test", 'adb -s "$s" shell am start -W -n "$c"', True) != 0:
        print("android-leg-order: SELF-TEST FAIL (a clean `am start` refused)", file=sys.stderr)
        return 1
    if no_empty_setting(
        "self-test",
        'settings put secure enabled_accessibility_services ""',
        True,
    ) == 0:
        print("android-leg-order: SELF-TEST FAIL (empty setting read as a clear)", file=sys.stderr)
        return 1
    if no_empty_setting(
        "self-test",
        "settings delete secure enabled_accessibility_services",
        True,
    ) != 0:
        print("android-leg-order: SELF-TEST FAIL (settings delete refused)", file=sys.stderr)
        return 1
    if PICKER_VERB.search("expect label#0 \"ready\"\n") is not None:
        print("android-leg-order: SELF-TEST FAIL (ordinary scene read as picker)", file=sys.stderr)
        return 1
    if PICKER_VERB.search("file_save\n") is None:
        print("android-leg-order: SELF-TEST FAIL (picker scene read as ordinary)", file=sys.stderr)
        return 1

    per_leg_install, count = re.subn(
        r'(?m)^(run_apk_on\(\) \{\n)',
        r'\1    adb -s "$serial" install -r "$apk"\n',
        text,
        count=1,
    )
    print(f"android-leg-order: per-leg install self-test applied {count} substitution(s)")
    if count != 1 or staging_problem(per_leg_install) is None:
        print("android-leg-order: SELF-TEST FAIL (per-leg install read as staged)",
              file=sys.stderr)
        return 1

    no_stage_disarm, count = re.subn(
        r'a11y_disarm "\$serial" "\$package" "\$a11y" \\\n'
        r'\s*&& ',
        "",
        text,
        count=1,
    )
    print(f"android-leg-order: stage disarm self-test applied {count} substitution(s)")
    if count != 1 or staging_problem(no_stage_disarm) is None:
        print("android-leg-order: SELF-TEST FAIL (install without stage disarm read as good)",
              file=sys.stderr)
        return 1

    leg_marker_stage, count = re.subn(
        re.escape('echo "stage-$label: OK ($passed/$expected targets)"'),
        'echo "stage-$label: PASS ($passed/$expected targets)"',
        text,
        count=1,
    )
    print(f"android-leg-order: stage PASS-marker self-test applied {count} substitution(s)")
    if count != 1 or staging_problem(leg_marker_stage) is None:
        print("android-leg-order: SELF-TEST FAIL (APK staging read as a scene leg)",
              file=sys.stderr)
        return 1

    for index, marker in enumerate(STAGE_REQUIRED, 1):
        without_refusal, count = re.subn(re.escape(marker), "", text, count=1)
        print(
            f"android-leg-order: stage refusal self-test {index} applied "
            f"{count} substitution(s)"
        )
        if count != 1 or staging_problem(without_refusal) is None:
            print(
                f"android-leg-order: SELF-TEST FAIL (missing stage refusal {index} read as good)",
                file=sys.stderr,
            )
            return 1

    target_edits = [
        (
            'dev.kaya.milestone2 "${SERIALS[@]}" "$TABLET_SERIAL" || exit 1',
            'dev.kaya.milestone2 "${SERIALS[@]}" || exit 1',
            "compose tablet removal",
        ),
        (
            'dev.kaya.milestone2kt "${SERIALS[@]}" || exit 1',
            'dev.kaya.milestone2kt "${SERIALS[@]}" "$TABLET_SERIAL" || exit 1',
            "jvm tablet insertion",
        ),
        (
            'dev.kaya.milestone2go "${SERIALS[@]}" || exit 1',
            'dev.kaya.milestone2go "${SERIALS[@]}" "$TABLET_SERIAL" || exit 1',
            "go tablet insertion",
        ),
    ]
    for old, new, label in target_edits:
        wrong_targets, count = re.subn(re.escape(old), new, text, count=1)
        print(f"android-leg-order: {label} self-test applied {count} substitution(s)")
        if count != 1 or staging_problem(wrong_targets) is None:
            print(f"android-leg-order: SELF-TEST FAIL ({label} read as good)",
                  file=sys.stderr)
            return 1

    compose_stage = (
        '    stage_suite_apk compose \\\n'
        '        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \\\n'
        '        dev.kaya.milestone2 "${SERIALS[@]}" "$TABLET_SERIAL" || exit 1\n'
    )
    early_stage, removed = re.subn(re.escape(compose_stage), "", text, count=1)
    early_stage, inserted = re.subn(
        r'(?m)^    apk_assets_verify \\\n',
        lambda match: compose_stage + match.group(0),
        early_stage,
        count=1,
    )
    print(
        "android-leg-order: early stage self-test applied "
        f"{removed} removal(s), {inserted} insertion(s)"
    )
    if removed != 1 or inserted != 1 or staging_problem(early_stage) is None:
        print("android-leg-order: SELF-TEST FAIL (stage before artifact proof read as good)",
              file=sys.stderr)
        return 1

    duplicate_stage, count = re.subn(
        re.escape(compose_stage), compose_stage + compose_stage, text, count=1
    )
    print(f"android-leg-order: duplicate stage self-test applied {count} substitution(s)")
    if count != 1 or staging_problem(duplicate_stage) is None:
        print("android-leg-order: SELF-TEST FAIL (duplicate stage read as good)",
              file=sys.stderr)
        return 1

    wrong_ime_set, count = re.subn(
        r'(?m)^IME_SCENES="ranges"$', 'IME_SCENES="ordinary"', text, count=1
    )
    print(f"android-leg-order: IME scene census self-test applied {count} substitution(s)")
    if count != 1 or ime_problem(wrong_ime_set) is None:
        print("android-leg-order: SELF-TEST FAIL (wrong IME scene census read as good)",
              file=sys.stderr)
        return 1

    for index, marker in enumerate(IME_ORDER_MARKERS, 1):
        without_order, count = re.subn(re.escape(marker), "", text, count=1)
        print(
            f"android-leg-order: IME order self-test {index} applied "
            f"{count} substitution(s)"
        )
        if count != 1 or ime_problem(without_order) is None:
            print(
                f"android-leg-order: SELF-TEST FAIL (missing IME order step {index} read as good)",
                file=sys.stderr,
            )
            return 1

    bypass_cleanup, count = re.subn(
        r'(?m)^            ready=0$', '            exit 1', text, count=1
    )
    print(f"android-leg-order: IME cleanup bypass self-test applied {count} substitution(s)")
    if count != 1 or ime_problem(bypass_cleanup) is None:
        print("android-leg-order: SELF-TEST FAIL (IME failure bypassing cleanup read as good)",
              file=sys.stderr)
        return 1

    extra_ime_call, count = re.subn(
        r'(?m)^(    run_apk ranges-compose \\\n)',
        '    select_helper_ime "$serial" || exit 1\n\\1',
        text,
        count=1,
    )
    print(f"android-leg-order: suite IME call self-test applied {count} substitution(s)")
    if count != 1 or ime_problem(extra_ime_call) is None:
        print("android-leg-order: SELF-TEST FAIL (suite-wide IME call read as good)",
              file=sys.stderr)
        return 1

    extra_drain, count = re.subn(
        r'(?m)^(    run_apk ranges-compose \\\n)',
        '    drain\n\\1',
        text,
        count=1,
    )
    print(f"android-leg-order: ranges drain self-test applied {count} substitution(s)")
    if count != 1 or ime_problem(extra_drain) is None:
        print("android-leg-order: SELF-TEST FAIL (serialized ranges queue read as good)",
              file=sys.stderr)
        return 1

    late_range, count = re.subn(
        r'(?m)^(    run_apk ranges-jvm )',
        r'    run_apk_with_ime ranges-jvm ',
        text,
        count=1,
    )
    print(f"android-leg-order: ranges route self-test applied {count} substitution(s)")
    if count != 1 or ime_problem(late_range) is None:
        print("android-leg-order: SELF-TEST FAIL (ranges outside generic queue read as good)",
              file=sys.stderr)
        return 1

    early_final, count = re.subn(
        r'(?m)(^    run_apk ranges-compose \\\n(?:^        .*\n){3})^    drain\n',
        lambda match: "    drain\n" + match.group(1),
        text,
        count=1,
    )
    print(f"android-leg-order: early final drain self-test applied {count} substitution(s)")
    if count != 1 or ime_problem(early_final) is None:
        print("android-leg-order: SELF-TEST FAIL (drain before final leg read as good)",
              file=sys.stderr)
        return 1

    early_editor_drain, count = re.subn(
        r'(?m)(^    run_apk editor-go \\\n(?:^        .*\n){3})^    drain\n',
        lambda match: "    drain\n" + match.group(1),
        text,
        count=1,
    )
    print(f"android-leg-order: editor drain self-test applied {count} substitution(s)")
    if count != 1 or ime_problem(early_editor_drain) is None:
        print("android-leg-order: SELF-TEST FAIL (editor outside Go queue read as good)",
              file=sys.stderr)
        return 1

    without_hygiene, count = re.subn(
        r'(?m)^\s*a11y_hygiene "\$serial" \|\| exit 1\n', "", text, count=1
    )
    print(f"android-leg-order: hygiene self-test applied {count} substitution(s)")
    if count != 1 or hygiene_problem(without_hygiene) is None:
        print("android-leg-order: SELF-TEST FAIL (missing startup hygiene read as good)",
              file=sys.stderr)
        return 1

    unguarded, count = re.subn(
        r'if \[ "\$needs_a11y" = 1 \]; then\s*'
        r'(a11y_disarm "\$serial" "\$package" "\$a11y" \|\| return 1)\s*fi',
        r'\1', body, count=1
    )
    print(f"android-leg-order: ordinary-leg disarm self-test applied {count} substitution(s)")
    if count != 1 or guarded_disarm_problem(unguarded) is None:
        print("android-leg-order: SELF-TEST FAIL (ordinary-leg device query read as good)",
              file=sys.stderr)
        return 1

    post_pattern = (
        r'(?m)^    if \[ "\$needs_a11y" = 1 \] && ! '
        r'a11y_disarm "\$serial" "\$package" "\$a11y"; then\n'
        r'        failed=1\n    fi\n'
    )
    post_match = re.search(post_pattern, body)
    early_post, removed = re.subn(post_pattern, "", body, count=1)
    if post_match is None:
        inserted = 0
    else:
        early_post, inserted = re.subn(
            r'(?m)^(    adb -s "\$serial" shell am start[^\n]*\n)',
            lambda match: post_match.group(0) + match.group(1),
            early_post,
            count=1,
        )
    print(
        "android-leg-order: early post-disarm self-test applied "
        f"{removed} removal(s), {inserted} insertion(s)"
    )
    if removed != 1 or inserted != 1 or guarded_disarm_problem(early_post) is None:
        print("android-leg-order: SELF-TEST FAIL (early post-leg disarm read as good)",
              file=sys.stderr)
        return 1

    per_leg_hygiene, count = re.subn(
        r'(?m)^(run_apk_on\(\) \{\n)',
        r'\1    a11y_hygiene "$serial"\n',
        text,
        count=1,
    )
    print(f"android-leg-order: per-leg hygiene self-test applied {count} substitution(s)")
    if count != 1 or hygiene_problem(per_leg_hygiene) is None:
        print("android-leg-order: SELF-TEST FAIL (per-leg hygiene read as good)",
              file=sys.stderr)
        return 1

    misplaced_route, count = re.subn(
        r'(    for component in "\$\{components\[@\]\}"; do\n)'
        r'(        case "\$component" in\n)'
        r'(            \*/dev\.kaya\.KayaHarnessAccessibility\)\n)'
        r'(                package="\$\{component%%/\*\}"\n)'
        r'(                a11y_disarm "\$serial" "\$package" "\$component" '
        r'\|\| return 1\n)',
        r'\5\1\2\3\4',
        text,
        count=1,
    )
    print(f"android-leg-order: hygiene route self-test applied {count} substitution(s)")
    if count != 1 or hygiene_problem(misplaced_route) is None:
        print("android-leg-order: SELF-TEST FAIL (unmatched stale service read as routed)",
              file=sys.stderr)
        return 1
    return status


if __name__ == "__main__":
    sys.exit(main())
