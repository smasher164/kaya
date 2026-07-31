"""The per-leg Android setup has an ORDER, and every step's place is load-
bearing. This asserts it.

Each constraint below was paid for. `am force-stop` kills every component
of the package — including the harness accessibility service, because the
validation app is what declares it — so enabling the service before the
force-stop silently kills it. `logcat -c` wipes everything logged so far,
including the service's own connection message, so enabling before the
clear erases the one piece of evidence that it came up. Between them
those two produced a service that was configured, dead, and undetectable,
which reads exactly like a service that never started.

None of that is visible at the call site. Each line is a plausible adb
command in a plausible place, the lane stays green because the legs that
do not need the service do not care, and the failure surfaces much later
as "the picker never appeared". So the ordering is stated here, with its
reasons, instead of living in a comment somebody moves a line past.

Text, not execution: this reads the shell rather than running it, so it
cannot see an order produced dynamically. That is the honest limit, and
it still catches the thing that actually happened — a line moved to a
reasonable-looking wrong place.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNNER = ROOT / "tools" / "android" / "run-emulator.sh"

# (label, pattern, why it must follow the step before it)
STEPS = [
    ("install", r"adb -s \"\$serial\" install -r", "the app has to exist first"),
    (
        "force-stop",
        r"adb -s \"\$serial\" shell am force-stop \"\$\{component%%/\*\}\"",
        "a leftover process from the previous leg would answer for this one",
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

    # The gate guards itself: a shuffled body must be caught.
    shuffled = "run_apk_on() {\n" + "\n".join(
        [
            'settings put secure enabled_accessibility_services "$a11y"',
            'adb -s "$serial" install -r "$apk"',
        ]
    )
    positions = [
        re.search(pattern, shuffled) for _, pattern, _ in STEPS[:1] + [STEPS[3]]
    ]
    if positions[0] is None or positions[1] is None:
        print("android-leg-order: SELF-TEST FAIL (patterns did not match)", file=sys.stderr)
        return 1
    if positions[1].start() > positions[0].start():
        print("android-leg-order: SELF-TEST FAIL (bad order read as good)", file=sys.stderr)
        return 1
    return status


if __name__ == "__main__":
    sys.exit(main())
