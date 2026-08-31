#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# CLAUDE.md and AGENTS.md are true mirrors; only line 3 (the mirror
# comment) may differ.


def compare(a_name, a_text, b_name, b_text):
    """(ok, lines-to-print). Line 3 (index 2) differs by design."""
    a = a_text.splitlines()
    b = b_text.splitlines()
    if len(a) > 2:
        a[2] = ""
    if len(b) > 2:
        b[2] = ""
    if a == b:
        return True, []
    for i, (x, y) in enumerate(zip(a, b), 1):
        if x != y:
            return False, [f"first divergence at line {i}:",
                           f"  {a_name}: {x}",
                           f"  {b_name}: {y}"]
    return False, [f"line counts differ: {len(a)} vs {len(b)}"]


# Self-test: divergence beyond line 3 flagged, a line-3-only diff not.
SAME = "title\n\n<!-- mirror A -->\nsame\n"
MIRROR = "title\n\n<!-- mirror B -->\nsame\n"
DRIFTED = "title\n\n<!-- mirror B -->\ndrifted\n"
ok, _ = compare("a.md", SAME, "b.md", MIRROR)
if not ok:
    print("check-mirror: self-test failed (mirror-comment diff flagged)")
    sys.exit(1)
ok, _ = compare("a.md", SAME, "c.md", DRIFTED)
if ok:
    print("check-mirror: self-test failed (real drift not flagged)")
    sys.exit(1)

ok, lines = compare(
    "CLAUDE.md", (ROOT / "CLAUDE.md").read_text(encoding="utf-8"),
    "AGENTS.md", (ROOT / "AGENTS.md").read_text(encoding="utf-8"))
if ok:
    print("check-mirror: OK")
else:
    for line in lines:
        print(line)
    print("check-mirror: CLAUDE.md and AGENTS.md have drifted — "
          "edit both together")
    sys.exit(1)
