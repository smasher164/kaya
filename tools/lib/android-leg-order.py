"""The per-leg Android setup has an ORDER, and every step's place is load-
bearing. This asserts it.

Each constraint, and what it cost, is in docs/traps.md; the STEPS table
below carries the reason for every pair, in the words the failure prints.
None of it is visible at the call site — each line is a plausible adb
command in a plausible place, and the failure surfaces much later as "the
picker never appeared".

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

# (label, pattern, why it must follow the step before it)
STEPS = [
    ("install", r"adb -s \"\$serial\" install -r", "the app has to exist first"),
    (
        "force-stop",
        r"adb -s \"\$serial\" shell am force-stop \"\$\{component%%/\*\}\"",
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
        "enable accessibility",
        r"settings put secure enabled_accessibility_services",
        "force-stop kills the service (the validation app declares it) and "
        "logcat -c erases its connection message — enabling before either "
        "leaves it dead and undetectable",
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


def main() -> int:
    if not RUNNER.exists():
        print(f"android-leg-order: {RUNNER} is missing", file=sys.stderr)
        return 1
    text = RUNNER.read_text()

    start = text.find("run_apk_on() {")
    if start < 0:
        print(
            "android-leg-order: run_apk_on() not found — the runner's shape "
            "moved and this gate went vacuous",
            file=sys.stderr,
        )
        return 1
    body = text[start:]

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

    # The probe is policed for the flag but not for the order: its reset
    # is a loop over variants rather than run_apk_on's shape. Absent is
    # fine — it is a probe, and may be deleted.
    if PROBE.exists():
        status |= no_restart_flag(str(PROBE.relative_to(ROOT)), PROBE.read_text())

    # The gate guards itself: a shuffled body must be caught.
    shuffled = "run_apk_on() {\n" + "\n".join(
        [
            'settings put secure enabled_accessibility_services "$a11y"',
            'adb -s "$serial" install -r "$apk"',
        ]
    )
    positions = [
        re.search(pattern, shuffled) for _, pattern, _ in [STEPS[0], STEPS[4]]
    ]
    if positions[0] is None or positions[1] is None:
        print("android-leg-order: SELF-TEST FAIL (patterns did not match)", file=sys.stderr)
        return 1
    if positions[1].start() > positions[0].start():
        print("android-leg-order: SELF-TEST FAIL (bad order read as good)", file=sys.stderr)
        return 1

    # And the flag rule guards itself, both directions.
    if no_restart_flag("self-test", 'adb -s "$s" shell am start -S -W -n "$c"', True) == 0:
        print("android-leg-order: SELF-TEST FAIL (`am start -S` read as good)", file=sys.stderr)
        return 1
    if no_restart_flag("self-test", 'adb -s "$s" shell am start -W -n "$c"', True) != 0:
        print("android-leg-order: SELF-TEST FAIL (a clean `am start` refused)", file=sys.stderr)
        return 1
    return status


if __name__ == "__main__":
    sys.exit(main())
