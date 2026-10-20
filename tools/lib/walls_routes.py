"""tools/check-gates.py's walls clauses (tools/lib/walls.py; docs/traps.md, the
matrix that slept 22 hours on battery): every gate, lane, leg worker and ssh
call is bounded where it is launched, and each wall is RUN against a hung
stand-in, since a wall nobody has seen fire is a sentence nobody has read."""

import ast
import pathlib
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback

import walls
from kaya_gate import ROOT

GATES = "tools/gates.py"
MATRIX = "tools/validate-all.py"
WIN = "tools/deploy-win.py"

# The gross maxima of the 26 matrices kept in the session scratchpad on
# 2026-10-20 (`<lane>: exited after Ns`), and the slowest gate in any kept
# sweep (check-verbs); a wall must clear each by 20%.
MEASURED = {"mac": 1580, "linux": 1817, "windows": 2413, "ios": 1994,
            "android": 1581, "gates": 902, "android-quiet": 422, "linux-quiet": 48}
SLOWEST_GATE_S = 411

NEEDLES = [
    (GATES, "run_one", "walls.run_bounded(argv, wall, cwd=ROOT)",
     "the sweep runs each gate through the wall"),
    (GATES, "main", "walls.forward_signals()",
     "the sweep passes a ^C on to the gates' own groups"),
    (MATRIX, "run_lane", "start_new_session=True",
     "each parallel lane gets a process group the wall can kill"),
    (MATRIX, "run_lane", "rc, why = lane_watch(name, proc, t0)",
     "each parallel lane is waited for through its wall"),
    (MATRIX, "lane_watch", "left = walls.kill_group(proc.pid, proc)",
     "a walled lane's whole group is killed"),
    (MATRIX, "lane_watch", "if walls.verdict_line(name, text):",
     "a lane's own verdict starts its exit grace"),
    (MATRIX, "lane_watch", "if now - t0 > wall:",
     "a lane past its wall is killed"),
    (MATRIX, None, "_slept = SLEEP.slept()",
     "a host sleep inside the matrix is named before the verdict"),
    (WIN, "run_ssh", "timeout=wall", "every remote command is bounded"),
    (WIN, "run_ssh_out", "timeout=wall", "every captured remote command is bounded"),
    (WIN, "run_one_suite", "timeout=WAIT_EXIT_GUEST_S + 60",
     "the leg's resident waiter is bounded on the host"),
    (WIN, "run_suite", 'name=f"leg {name}", daemon=True',
     "a leg worker cannot hold the interpreter's exit"),
    (WIN, "run_suite", '_join_legs(f"before the exclusive leg {name}")',
     "the exclusive funnel joins the pool through the bound"),
    (WIN, "drain_suites", "stuck = _join_legs(\"at the block's end\")",
     "a block's end joins its legs through the bound"),
]


def function_source(text, name):
    tree = ast.parse(text)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return ast.get_source_segment(text, node)
    return None


def needle_problems(texts):
    problems = []
    for rel, func, needle, what in NEEDLES:
        body = texts[rel] if func is None else function_source(texts[rel], func)
        if body is None:
            problems.append(f"{rel}: `def {func}` is gone, so nothing says {what}")
        elif needle not in body:
            problems.append(f"{rel}: {func or 'the module'} no longer carries `{needle}` — "
                            f"{what} (tools/lib/walls.py)")
    joins = function_source(texts[WIN], "_join_legs") or ""
    if "LEG_WALL_S" not in joins or ".join(1)" not in joins:
        problems.append(f"{WIN}: _join_legs no longer bounds its join by LEG_WALL_S")
    return problems


def limit_problems(budgets, gate_wall=walls.gate_wall, lane_wall=walls.lane_wall):
    problems = []
    for lane, seen in MEASURED.items():
        wall = lane_wall(budgets.get(lane, 0))
        if wall < 1.2 * seen:
            problems.append(f"the {lane} wall is {wall}s, under 1.2x the {seen}s that lane "
                            f"has measured — it would kill a normal matrix")
    if gate_wall(0) < 1.2 * SLOWEST_GATE_S:
        problems.append(f"the gate wall's floor is {gate_wall(0)}s, under 1.2x the "
                        f"{SLOWEST_GATE_S}s the slowest gate has measured")
    return problems


def budgets_of(text):
    tree = ast.parse(text)
    for node in tree.body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and getattr(node.targets[0], "id", None) == "BUDGETS"):
            return ast.literal_eval(node.value)
    return {}


def cut(text, name, extra):
    """`def name` out of a runner, compiled alone over `extra`'s names."""
    space = dict(extra)
    exec(compile(function_source(text, name), f"<{name}>", "exec"), space)  # noqa: S102
    return space[name]


def alive(pid):
    got = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], stdout=subprocess.PIPE,
                         text=True, check=False).stdout.strip()
    return bool(got) and not got.startswith("Z")


def stand_in(code):
    """A lane stand-in in a group of its own that writes its child's pid."""
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="kaya-walls-"))
    log = tmp / "lane.log"
    pidfile = tmp / "child"
    script = ("import subprocess, sys, time, signal\n"
              f"c = subprocess.Popen(['sleep', '600'])\nopen({str(pidfile)!r}, 'w').write(str(c.pid))\n"
              + code)
    with open(log, "w", encoding="utf-8") as lf:
        proc = subprocess.Popen([sys.executable, "-c", script], stdout=lf, stderr=lf,
                                start_new_session=True)
    end = time.monotonic() + 10
    while not pidfile.is_file() and time.monotonic() < end:
        time.sleep(0.05)
    return proc, log, int(pidfile.read_text(encoding="utf-8") or 0)


def lane_negatives(texts, fail, say):
    watch = cut(texts[MATRIX], "lane_watch",
                {"walls": walls, "time": time, "subprocess": subprocess, "BUDGETS": {},
                 "LANES_DIR": pathlib.Path("/nonexistent")})
    cases = [
        ("W1 a lane hung with no verdict", "print('stand-in: working', flush=True)\ntime.sleep(600)\n",
         {"wall": 2}, "past its 2s wall"),
        ("W2 a lane that printed its verdict and stayed",
         "print('deploy-win: ALL PASS', flush=True)\ntime.sleep(600)\n", {"grace": 2},
         "printed its verdict"),
        ("W3 a lane deaf to SIGINT and SIGTERM",
         "signal.signal(signal.SIGINT, signal.SIG_IGN)\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
         "print('stand-in: deaf', flush=True)\ntime.sleep(600)\n", {"wall": 2}, "past its 2s wall"),
        ("W4 a lane that exits after its verdict (the control)",
         "c.kill()\nprint('deploy-win: ALL PASS', flush=True)\n", {"grace": 2}, None),
    ]
    for label, code, kw, want in cases:
        proc, log, child = stand_in(code)
        t0 = time.monotonic()
        said = []
        real_print = print

        def capture(*a, **k):
            said.append(" ".join(str(x) for x in a))
        watch.__globals__["print"] = capture
        try:
            rc, why = watch("windows", proc, t0, log=log, tick=0.2, **kw)
        finally:
            watch.__globals__["print"] = real_print
        took = time.monotonic() - t0
        left = [p for p in (proc.pid, child) if alive(p)]
        text = " ".join(said)
        say(f"walls: {label}: rc={rc} in {took:.1f}s, alive after: {left}; "
            f"{(text or 'no WALL sentence')[:240]}")
        if want is None:
            if why is not None or rc != 0:
                fail(f"walls: {label} was walled ({why}) — the wall fires on a lane that left")
            if alive(child):
                subprocess.run(["kill", "-9", str(child)], check=False)
        elif why is None or want not in why or left or took > 60 or "WALL — the lane" not in text:
            fail(f"walls: {label} was not killed with its child inside 60s and named "
                 f"(why={why!r}, alive={left})")
        for p in left:
            subprocess.run(["kill", "-9", str(p)], check=False)


def leg_negatives(texts, fail, say):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="kaya-walls-legs-"))
    (tmp / "hung.log").write_text("hung: last word before the hang\n", encoding="utf-8")
    stop = threading.Event()

    def hung_in_a_call():
        stop.wait(600)

    def quick():
        time.sleep(0.3)

    for label, legs, claimed_ago, want in [
        ("D1 a leg worker hung past its wall", [("hung", hung_in_a_call)], 5, ["hung"]),
        ("D2 a leg that never took a slot and nothing moves", [("queued", hung_in_a_call)], None, ["queued"]),
        ("D3 legs that finish (the control)", [("a", quick), ("b", quick)], 0, []),
    ]:
        threads = []
        claimed = {}
        for n, fn in legs:
            t = threading.Thread(target=fn, name=f"leg {n}", daemon=True)
            t.start()
            threads.append((n, t))
            if claimed_ago is not None:
                claimed[n] = time.monotonic() - claimed_ago
        space = {"_leg_threads": threads, "_leg_claimed": claimed, "LEG_WALL_S": 1,
                 "LEGS_DIR": tmp, "walls": walls, "time": time, "sys": sys,
                 "traceback": traceback, "status": 0, "__file__": __file__}
        said = []
        space["print"] = lambda *a, **k: said.append(" ".join(str(x) for x in a))
        join = cut(texts[WIN], "_join_legs", space)
        t0 = time.monotonic()
        got = join("at the block's end")
        took = time.monotonic() - t0
        text = " ".join(said)
        say(f"walls: {label}: stuck {got} in {took:.1f}s; {(text or 'nothing said')[:260]}")
        if got != want or took > 15 or (want and (join.__globals__["status"] != 1
                                                   or "hung_in_a_call" not in text
                                                   or "WALL — the leg" not in text)):
            fail(f"walls: {label} came back {got} in {took:.1f}s (wanted {want}, the thread's "
                 f"frame named and the lane failed)")
    stop.set()


def run(fail, say):
    texts = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in (GATES, MATRIX, WIN)}
    for p in needle_problems(texts):
        fail("walls: " + p)
    budgets = budgets_of(texts[MATRIX])
    if not budgets:
        fail(f"walls: {MATRIX} names no BUDGETS the lane walls could be read from")
    for p in limit_problems(budgets):
        fail("walls: " + p)
    cuts = 0
    for rel, func, needle, what in NEEDLES:
        renamed = (needle.replace(" ", "  ", 1) if " " in needle
                   else needle.replace("=", "= ", 1) if "=" in needle
                   else needle.replace("()", "( )", 1))
        body = texts[rel] if func is None else function_source(texts[rel], func)
        doctored = texts[rel].replace(body, body.replace(needle, renamed, 1), 1)
        changed = doctored != texts[rel]
        cuts += changed
        if not changed or not needle_problems({**texts, rel: doctored}):
            fail(f"walls: the cut of `{needle}` from {rel} {'applied nothing' if not changed else 'passed'}")
    if limit_problems(budgets, lane_wall=lambda b: b) == [] or \
            limit_problems(budgets, gate_wall=lambda w: 300) == []:
        fail("walls: a lane wall at its bare ceiling, or a 300s gate wall, passed the limits clause")
    else:
        cuts += 2
    say(f"walls: {len(NEEDLES)} call sites held, {cuts} cut(s) watched red")
    lane_negatives(texts, fail, say)
    leg_negatives(texts, fail, say)
    signal.signal(signal.SIGINT, signal.default_int_handler)
