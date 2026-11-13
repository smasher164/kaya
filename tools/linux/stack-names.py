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
import shutil
import sys
import tempfile
import time

FRAME = re.compile(r"^#(\d+)\s+0x[0-9a-f]+\s+(?:(\S+)\s+)?-\s+(\S+)\s*$")
WHERE = re.compile(r"^\s+\[([0-9a-f]+)\]@0x[0-9a-f]+\+(0x[0-9a-f]+)\s*$")
SNAPSHOT = re.compile(r"snapshot\.debian\.org/archive/debian/(\d{8}T\d{6}Z)")
SOURCES = "/etc/apt/sources.list.d/debian.sources"
HEAD = re.compile(r"^(?:KAYA_HARNESS: thread stacks|leg-ceiling: thread stacks|TID \d+:)")
BUDGET = 120
DEBUGINFOD = "https://debuginfod.debian.net"


def unnamed(lines):
    """[(heading, frame number, module, offset, build id)] for each frame with no name."""
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
            out.append((heading, int(m.group(1)), m.group(3), w.group(2), w.group(1)))
    return out


def names(module, offsets, deadline, debug=None):
    """eu-addr2line over one module's offsets: {offset: 'function at file:line'};
    `debug` is a separate debug file to read instead of asking debuginfod."""
    left = deadline - time.monotonic()
    if left <= 0:
        return {}, "the 120 s budget was spent before this module"
    env = dict(os.environ)
    env.setdefault("DEBUGINFOD_URLS", DEBUGINFOD)
    env.setdefault("DEBUGINFOD_TIMEOUT", "30")
    try:
        got = subprocess.run(["eu-addr2line", "-f", "-i", "-e", debug or module, *offsets],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             encoding="utf-8", errors="replace", timeout=left, env=env, check=False)
    except FileNotFoundError:
        return {}, "eu-addr2line is not on PATH (elfutils)"
    except subprocess.TimeoutExpired:
        return {}, f"eu-addr2line did not answer within {int(left)} s"
    return pair(offsets, got.stdout), (got.stderr.strip()[-200:] or None)


def each(module, offsets, deadline, debug=None):
    """names() over all offsets at once, then one at a time if the pairing disagreed."""
    got, problem = names(module, offsets, deadline, debug)
    if len(got) != len(offsets):
        got = {}
        for offset in offsets:
            one, problem = names(module, [offset], deadline, debug)
            got.update(one)
    return got, problem


def _out(argv, deadline):
    left = deadline - time.monotonic()
    if left <= 0:
        return None, "the 120 s budget was spent"
    try:
        got = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             encoding="utf-8", errors="replace", timeout=left, check=False)
    except FileNotFoundError:
        return None, f"{argv[0]} is not on PATH"
    except subprocess.TimeoutExpired:
        return None, f"{argv[0]} did not answer within {int(left)} s"
    if got.returncode:
        return None, f"{' '.join(argv[:2])} exited {got.returncode}: {got.stderr.strip()[-160:]}"
    return got.stdout, None


def dbgsym_url(package, version, arch, source, snapshot):
    """The Debian debug archive's -dbgsym .deb for one installed package."""
    pool = source[:4] if source.startswith("lib") else source[:1]
    bare = version.split(":", 1)[-1].replace("+", "%2B")
    return (f"http://snapshot.debian.org/archive/debian-debug/{snapshot}/pool/main/"
            f"{pool}/{source}/{package}-dbgsym_{bare}_{arch}.deb")


def dbgsym(module, build_id, deadline, scratch, fetched):
    """(the debug file for build_id from the owning package's -dbgsym, or None, why).
    docs/traps.md, the HLS stop that waited for a download thread forever."""
    if deadline <= time.monotonic():
        return None, "the 120 s budget was spent before its -dbgsym was looked for"
    owner, why = _out(["dpkg", "-S", os.path.realpath(module)], deadline)
    if owner is None:
        return None, f"dpkg -S found no owner ({why})"
    package = owner.split(":", 1)[0].strip()
    meta, why = _out(["dpkg-query", "-W", "-f", "${Version} ${Architecture} ${source:Package}",
                      package], deadline)
    if meta is None:
        return None, f"dpkg-query could not read {package} ({why})"
    version, arch, source = meta.split()
    try:
        with open(SOURCES, encoding="utf-8") as f:
            snap = SNAPSHOT.search(f.read())
    except OSError as e:
        snap, problem = None, str(e)
    else:
        problem = "it names no snapshot.debian.org date"
    if not snap:
        return None, f"{SOURCES} could not date the archive ({problem})"
    url = dbgsym_url(package, version, arch, source, snap.group(1))
    root = os.path.join(scratch, package)
    if url not in fetched:
        deb = root + ".deb"
        _, why = _out(["curl", "-sfL", "-o", deb, url], deadline)
        if why is None:
            _, why = _out(["dpkg", "-x", deb, root], deadline)
        fetched[url] = why
    if fetched[url]:
        return None, f"{url} could not be read ({fetched[url]})"
    path = os.path.join(root, "usr/lib/debug/.build-id", build_id[:2], build_id[2:] + ".debug")
    if not os.path.exists(path):
        return None, f"{url} carries no debug file for build id {build_id}"
    return path, None


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
    if len(offsets) == 1 and chunks:
        return {offsets[0]: "; ".join(chunks)}
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
    by_module, ids = {}, {}
    for _, _, module, offset, build_id in frames:
        by_module.setdefault(module, [])
        ids[module] = build_id
        if offset not in by_module[module]:
            by_module[module].append(offset)
    named, fetched = {}, {}
    scratch = tempfile.mkdtemp(prefix="stack-names-")
    for module, offsets in by_module.items():
        got, problem = each(module, offsets, deadline)
        if not any(not v.startswith("?? at") for v in got.values()):
            debug, why = dbgsym(module, ids[module], deadline, scratch, fetched)
            if debug:
                got, problem = each(module, offsets, deadline, debug)
                problem = problem or "the -dbgsym debug file names nothing at this offset"
            else:
                problem = f"debuginfod has no debug info for this build id, and {why}"
        for offset in offsets:
            said = got.get(offset)
            if not said or said.startswith("?? at"):
                said = f"unnamed ({problem or 'debuginfod has no debug info for this build id'})"
            named[(module, offset)] = said
    print(f"stack-names: {len(frames)} unnamed frame(s) in {len(by_module)} module(s), named through "
          f"{os.environ.get('DEBUGINFOD_URLS', DEBUGINFOD)} from each frame's build id and offset")
    heading = None
    for head, number, module, offset, _ in frames:
        if head != heading:
            print(head)
            heading = head
        print(f"  #{number} {os.path.basename(module)}+{offset}: {named[(module, offset)]}")
    shutil.rmtree(scratch, ignore_errors=True)
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
    want = [("TID 7:", 0, "/usr/lib/aarch64-linux-gnu/libc.so.6", "0x85f20",
             "2bf198c9840b48052b085382d7ee353a2cb872a1")]
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
    if pair(["0x9"], "inner inlined at a.c:3:1 in mid\na.h:9:2\nmid\na.c:3:1\nouter\nb.c:1:1\n") \
            != {"0x9": "inner inlined at a.c:3:1 in mid at a.h:9:2; mid at a.c:3:1; outer at b.c:1:1"}:
        failed.append("one offset's inline chain past its first caller was not kept whole")
    url = dbgsym_url("libglib2.0-0t64", "1:2.90.0-1+b1", "arm64", "glib2.0", "20261005T000000Z")
    if url != ("http://snapshot.debian.org/archive/debian-debug/20261005T000000Z/pool/main/g/"
               "glib2.0/libglib2.0-0t64-dbgsym_2.90.0-1%2Bb1_arm64.deb"):
        failed.append(f"the dbgsym url read {url}")
    if "/pool/main/libs/libsoup3/" not in dbgsym_url("libsoup-3.0-0", "3.6.6-1", "arm64",
                                                       "libsoup3", "x"):
        failed.append("a lib* source was not pooled under its four-letter prefix")
    for line in failed:
        print(f"stack-names: self-test FAILED: {line}", file=sys.stderr)
    print(f"stack-names: self-test: 6 checks, {len(failed)} failed", file=sys.stderr)
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
