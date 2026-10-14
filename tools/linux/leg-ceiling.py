#!/usr/bin/env python3
"""A linux leg under its ceiling, and its thread stacks when it outlives it:

    tools/linux/leg-ceiling.py <seconds> <command> [args...]
    tools/linux/leg-ceiling.py --self-test

Runs INSIDE the linux container, from tools/linux/run-suites.sh's run_one,
so it carries no dev-shell guard (persist-leg.py's rule). It is `timeout`
with one addition: before the kill, every process the leg started that is
still running prints its thread stacks (eu-stack) into the leg log. The
harness's own step ceiling covers a wedge once the script runs; a leg that
hangs before the harness starts, or in a launcher around it, reached this
ceiling with nothing said (docs/traps.md, the toast leg that never started).
"""

import os
import signal
import subprocess
import sys
import time

QUIET = ("dbus-daemon", "dbus-launch", "at-spi-bus-laun", "at-spi2-registr", "pipewire",
         "wireplumber", "pwsynth", "sh", "bash", "timeout", "Xvfb", "sway", "swaybg")
STACK_CAP = 8
TERM_GRACE = 10


def say(message):
    print(f"leg-ceiling: {message}", file=sys.stderr, flush=True)


def table():
    """pid -> (ppid, comm, threads) for every live process /proc lists now."""
    out = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat", encoding="utf-8", errors="replace") as f:
                stat = f.read()
        except OSError:
            continue
        comm = stat[stat.find("(") + 1:stat.rfind(")")]
        fields = stat[stat.rfind(")") + 2:].split()
        if fields[0] != "Z":
            out[int(name)] = (int(fields[1]), comm, int(fields[17]))
    return out


def descendants(root, procs):
    found, frontier = [], [root]
    while frontier:
        pid = frontier.pop()
        found.append(pid)
        frontier.extend(p for p, (ppid, _, _) in procs.items() if ppid == pid)
    return [p for p in found if p in procs]


def stacks(root):
    """The stacks, and the tree they were read from, which the kill below
    finishes once the leg's own process has had its grace."""
    procs = table()
    tree = descendants(root, procs)
    say(f"the leg's {len(tree)} process(es) still running: "
        + ", ".join(f"{p} {procs[p][1]} ({procs[p][2]} threads)" for p in tree))
    asked = [p for p in tree if procs[p][1] not in QUIET][:STACK_CAP]
    if not asked:
        say("none of them is the guest's (every one is a daemon or a shell); no stacks taken")
    for pid in asked:
        t0 = time.monotonic()
        try:
            env = {k: v for k, v in os.environ.items() if k != "DEBUGINFOD_URLS"}
            got = subprocess.run(["eu-stack", "-m", "-b", "-p", str(pid)], stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                                 errors="replace", timeout=30, env=env, check=False)
            text, how = got.stdout, f"exit {got.returncode}"
        except FileNotFoundError:
            text, how = "", "eu-stack is not on PATH (tools/linux/Dockerfile installs elfutils)"
        except subprocess.TimeoutExpired:
            text, how = "", "eu-stack did not answer within 30 s"
        say(f"thread stacks of {pid} {procs[pid][1]} ({how}, "
            f"{int((time.monotonic() - t0) * 1000)} ms):")
        sys.stderr.write(text)
        sys.stderr.flush()
    return {p: procs[p][1] for p in tree}


def run(seconds, argv):
    try:
        child = subprocess.Popen(argv)
    except OSError as error:
        say(f"could not start {argv[0]}: {error.strerror}")
        return 127
    try:
        return status(child.wait(timeout=seconds))
    except subprocess.TimeoutExpired:
        pass
    say(f"the leg ran {seconds} s without exiting; the harness's own step ceiling did not end "
        f"it, so it hung outside a step (before the script started, or in a launcher)")
    tree = stacks(child.pid)
    child.send_signal(signal.SIGTERM)
    try:
        child.wait(timeout=TERM_GRACE)
    except subprocess.TimeoutExpired:
        say(f"{argv[0]} outlived SIGTERM by {TERM_GRACE} s; killed")
        child.kill()
        child.wait()
    left = [p for p, comm in tree.items() if table().get(p, (0, None, 0))[1] == comm]
    for pid in left:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    if left:
        say(f"{len(left)} process(es) of the leg outlived it and were killed: "
            + ", ".join(f"{p} {tree[p]}" for p in left))
    return 124


def status(code):
    return 128 - code if code < 0 else code


def self_test():
    failed = []
    t0 = time.monotonic()
    got = subprocess.run([sys.executable, __file__, "1", "sh", "-c", "sleep 60 & sleep 60"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         encoding="utf-8", errors="replace", check=False)
    took = time.monotonic() - t0
    for want in ("leg-ceiling: the leg ran 1 s without exiting",
                 "process(es) still running:", "sleep", "thread stacks of"):
        if want not in got.stderr:
            failed.append(f"an expired leg did not print {want!r}; it printed: {got.stderr[-600:]!r}")
    if got.returncode != 124:
        failed.append(f"an expired leg exited {got.returncode}, wanted timeout's 124")
    if took > 60:
        failed.append(f"an expired leg took {took:.0f} s to end")
    if "outlived it and were killed" not in got.stderr:
        failed.append("an expired leg's orphaned child was not killed")
    time.sleep(0.2)
    stray = [p for p, (_, comm, _) in table().items() if comm == "sleep"]
    if stray:
        failed.append(f"{len(stray)} sleep process(es) outlived the expired leg")
    passed = subprocess.run([sys.executable, __file__, "30", "sh", "-c", "exit 3"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            encoding="utf-8", errors="replace", check=False)
    if passed.returncode != 3 or passed.stderr:
        failed.append(f"a leg that exited 3 came back {passed.returncode} with {passed.stderr!r}")
    for line in failed:
        say(f"self-test FAILED: {line}")
    say(f"self-test: 2 legs, {len(failed)} failed (the expired one ended after {took:.1f} s)")
    return 1 if failed else 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if len(sys.argv) < 3 or not sys.argv[1].isdigit():
        say("usage: leg-ceiling.py <seconds> <command> [args...] | --self-test")
        return 2
    return run(int(sys.argv[1]), sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
