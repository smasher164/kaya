#!/usr/bin/env python3
"""Names the frames a red leg's thread stacks left unnamed:

    tools/linux/stack-names.py <leg log>
    tools/linux/stack-names.py --self-test

Runs INSIDE the linux container, from tools/linux/run-suites.sh's drain, so
it carries no dev-shell guard (persist-leg.py's rule). eu-stack names only
exported symbols, and the frame that decides a deadlock is usually a static
function: the capture leg's wedge waited in gstdevicemonitor.c's
bus_sync_message, printed as `?` (docs/traps.md, the capture that wedged on
a freed monitor). Every stack the harness and tools/linux/leg-ceiling.py
take carries each frame's build id and offset (`eu-stack -b`), so the
distribution's debuginfod names it afterwards, outside any ceiling.
"""

import os
import re
import subprocess
import sys
import time

FRAME = re.compile(r"^#(\d+)\s+0x[0-9a-f]+\s+(?:(\S+)\s+)?-\s+(\S+)\s*$")
WHERE = re.compile(r"^\s+\[([0-9a-f]+)\]@0x[0-9a-f]+\+(0x[0-9a-f]+)\s*$")
HEAD = re.compile(r"^(?:KAYA_HARNESS: thread stacks|leg-ceiling: thread stacks|TID \d+:)")
BUDGET = 120
DEBUGINFOD = "https://debuginfod.debian.net"


def unnamed(lines):
    """[(heading, frame number, module, offset)] for each frame with no name."""
    out, heading = [], ""
    for i, line in enumerate(lines):
        if HEAD.match(line):
            heading = line.strip()
            continue
        m = FRAME.match(line)
        if not m or m.group(2) or i + 1 >= len(lines):
            continue
        w = WHERE.match(lines[i + 1])
        if w:
            out.append((heading, int(m.group(1)), m.group(3), w.group(2)))
    return out


def names(module, offsets, deadline):
    """eu-addr2line over one module's offsets: {offset: 'function at file:line'}."""
    left = deadline - time.monotonic()
    if left <= 0:
        return {}, "the 120 s budget was spent before this module"
    env = dict(os.environ)
    env.setdefault("DEBUGINFOD_URLS", DEBUGINFOD)
    env.setdefault("DEBUGINFOD_TIMEOUT", "30")
    try:
        got = subprocess.run(["eu-addr2line", "-f", "-i", "-e", module, *offsets],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             encoding="utf-8", errors="replace", timeout=left, env=env, check=False)
    except FileNotFoundError:
        return {}, "eu-addr2line is not on PATH (elfutils)"
    except subprocess.TimeoutExpired:
        return {}, f"eu-addr2line did not answer within {int(left)} s"
    return pair(offsets, got.stdout), (got.stderr.strip()[-200:] or None)


def pair(offsets, text):
    """eu-addr2line -f -i prints a function line and a place line per frame,
    its inlined callers first; a function line without ' inlined at ' ends
    one offset's chain. A count that disagrees pairs nothing."""
    lines = [line for line in text.splitlines() if line.strip()]
    chunks, cur = [], []
    for k in range(0, len(lines) - 1, 2):
        fn, place = lines[k], lines[k + 1]
        cur.append(f"{fn} at {place}")
        if " inlined at " not in fn:
            chunks.append("; ".join(cur))
            cur = []
    if len(chunks) != len(offsets):
        return {}
    return dict(zip(offsets, chunks))


def report(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    frames = unnamed(lines)
    if not frames:
        print(f"stack-names: {path} carries no unnamed frame with a build id and offset "
              f"(no stack was taken with `eu-stack -b`, or every frame was named)")
        return 0
    deadline = time.monotonic() + BUDGET
    by_module = {}
    for _, _, module, offset in frames:
        by_module.setdefault(module, [])
        if offset not in by_module[module]:
            by_module[module].append(offset)
    named = {}
    for module, offsets in by_module.items():
        got, problem = names(module, offsets, deadline)
        if len(got) != len(offsets):
            got = {}
            for offset in offsets:
                one, problem = names(module, [offset], deadline)
                got.update(one)
        for offset in offsets:
            said = got.get(offset)
            if not said or said.startswith("?? at"):
                said = f"unnamed ({problem or 'debuginfod has no debug info for this build id'})"
            named[(module, offset)] = said
    print(f"stack-names: {len(frames)} unnamed frame(s) in {len(by_module)} module(s), named through "
          f"{os.environ.get('DEBUGINFOD_URLS', DEBUGINFOD)} from each frame's build id and offset")
    heading = None
    for head, number, module, offset in frames:
        if head != heading:
            print(head)
            heading = head
        print(f"  #{number} {os.path.basename(module)}+{offset}: {named[(module, offset)]}")
    return 0


SAMPLE = """KAYA_HARNESS: thread stacks at the ceiling (eu-stack, exit exit status: 0, 1317 ms):
TID 7:
#0  0x0000ffffb69e5f20 - /usr/lib/aarch64-linux-gnu/libc.so.6
    [2bf198c9840b48052b085382d7ee353a2cb872a1]@0xffffb6960000+0x85f20
#1  0x0000ffffb6a21b5c clock_nanosleep - /usr/lib/aarch64-linux-gnu/libc.so.6
    [2bf198c9840b48052b085382d7ee353a2cb872a1]@0xffffb6960000+0xc1b5b
#2  0x0000ffff8dbe58b0 - /usr/lib/x.so
"""


def self_test():
    failed = []
    got = unnamed(SAMPLE.splitlines())
    want = [("TID 7:", 0, "/usr/lib/aarch64-linux-gnu/libc.so.6", "0x85f20")]
    if got != want:
        failed.append(f"the reader found {got}, wanted {want} (a named frame and a frame with "
                      f"no build id are not asked about)")
    text = ("inner inlined at a.c:3:1 in outer\na.h:9:2\nouter\na.c:3:1\nlone\nb.c:1:1\n")
    paired = pair(["0x1", "0x2"], text)
    if paired != {"0x1": "inner inlined at a.c:3:1 in outer at a.h:9:2; outer at a.c:3:1",
                  "0x2": "lone at b.c:1:1"}:
        failed.append(f"the inline pairing read {paired}")
    if pair(["0x1", "0x2", "0x3"], text) != {}:
        failed.append("a count that disagrees was paired anyway")
    for line in failed:
        print(f"stack-names: self-test FAILED: {line}", file=sys.stderr)
    print(f"stack-names: self-test: 3 checks, {len(failed)} failed", file=sys.stderr)
    return 1 if failed else 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if len(sys.argv) != 2:
        print("usage: stack-names.py <leg log> | --self-test", file=sys.stderr)
        return 2
    return report(sys.argv[1])


if __name__ == "__main__":
    sys.exit(main())
