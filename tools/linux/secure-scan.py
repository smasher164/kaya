#!/usr/bin/env python3
"""The secure scan (tools/lib/secure_scan.py) over one linux leg's transcripts,
run where run-suites.sh decides the leg's verdict (docs/secure-entry-plan.md P6).

    tools/linux/secure-scan.py <leg-log> <verb-trace> -- <the leg's command>

The script is the leg's KAYA_SELFTEST_SCRIPT when its command sets one, and
tools/scenes/<KAYA_SELFTEST>.steps otherwise. Each refusal is printed and the
exit is 1; a leg with no type_secret step answers nothing.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools/lib"))
import secure_scan  # noqa: E402


def script_of(command):
    scene = None
    for arg in command:
        if arg.startswith("KAYA_SELFTEST_SCRIPT="):
            return arg.split("=", 1)[1]
        if arg.startswith("KAYA_SELFTEST="):
            scene = arg.split("=", 1)[1]
    if not scene:
        return ""
    steps = ROOT / "tools/scenes" / f"{scene}.steps"
    return steps.read_text(encoding="utf-8") if steps.is_file() else ""


log, trace, sep, *command = sys.argv[1:]
if sep != "--":
    sys.exit("secure-scan: usage: secure-scan.py <leg-log> <verb-trace> -- <command>")
transcripts = {}
for name, path in (("leg log", log), ("verb trace", trace)):
    if pathlib.Path(path).is_file():
        transcripts[name] = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
refused = secure_scan.refusals(script_of(command), transcripts)
for line in refused:
    print(line)
if refused:
    sys.exit(1)
