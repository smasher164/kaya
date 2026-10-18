"""docs/traps.md, "The tap that outlasted its wait": an Android shade hand's
every try is reported to the app, and the verb waits on those reports rather
than on a fixed budget of its own.

No scene can fail this on a quiet host: the hand is fast there, so a fixed
20 s wait passes, and the red comes only when host load stretches the
runner's shade rounds past it (chat-go, matrix 20261018T094114Z-083511, a
21.6 s tap whose activation arrived two seconds after the app had given up).
So the runner's report call, the file both sides name, the app's wait and its
ceiling are held by text, the report line and the failure path's step reading
are run, and each link's cut is watched."""

import ast
import re

RUNNER = "tools/android/run-emulator.py"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

# The hands' sentences as the red's leg log printed them, and what one try
# of each must tell the app.
SENTENCES = [
    (1, "tapped 'Sam''s row at 180,392 on dump 2",
     "1/3 acted tapped 'Sam''s row at 180,392 on dump 2\n"),
    (1, "typed 'They did, thanks' under 'Alex' and pressed its send button at +11764ms",
     "1/3 acted typed 'They did, thanks' under 'Alex' and pressed its send button at "
     "+11764ms\n"),
    (3, "no row reading 'Sam' in four shade dumps",
     "3/3 missed no row reading 'Sam' in four shade dumps\n"),
    (2, "the shade never opened with focus (round 1 expanded:\nunfocusable in 1588ms)",
     "2/3 missed the shade never opened with focus (round 1 expanded: unfocusable in "
     "1588ms)\n"),
]

BUFFERS = (
    "10-18 03:24:10.213 1 2 I kaya    : KAYA_HARNESS: step-failed notification_activate 7002: "
    "first\n"
    "10-18 03:24:11.000 1 2 I kaya    : KAYA_DIAG keyed target label@state[u3] unresolved\n"
    "10-18 03:24:25.237 1 2 I kaya    : KAYA_HARNESS: step-failed label@text[p1] second\n")


def py_source(text, *names):
    tree = ast.parse(text)
    found = {}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in names:
            found[node.name] = ast.get_source_segment(text, node)
        for t in getattr(node, "targets", []):
            if isinstance(t, ast.Name) and t.id in names:
                found[t.id] = ast.get_source_segment(text, node)
    return found


def kt_block(text, head):
    """The braced body that follows `head`, or ""."""
    at = text.find(head)
    if at < 0:
        return ""
    start = text.find("{", at + len(head))
    depth = 0
    for i in range(start, len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[start:i + 1]
    return ""


def kt_const(text, name):
    m = re.search(rf"const val {name} = ([\d_]+)L", text)
    return int(m.group(1).replace("_", "")) if m else None


def runner_findings(runner):
    out = []
    loop = py_source(runner, "run_apk_on").get("run_apk_on", "")
    for hand in ("told = tap_notification(serial, title, log)\n",
                 "told = reply_notification(serial, title, text, log)\n"):
        at = loop.find(hand)
        tail = loop[at + len(hand):].split("\n")[:2] if at >= 0 else []
        if not any("report_shade_hand(serial, package, seq, tries + 1, told)" in ln
                   for ln in tail):
            out.append(f"{RUNNER}: `{hand.strip()}` is not followed by its "
                       f"report_shade_hand call, so the app waits on a budget of its own")
    if "print(failed_steps_said(name, out, full_buffers), file=log)" not in loop:
        out.append(f"{RUNNER}: the failure path never prints failed_steps_said, so a leg with "
                   f"no verdict carries no failed step's sentence")
    defs = py_source(runner, "NOTIFY_TAP_TRIES", "shade_hand_acted", "shade_report_line",
                     "report_shade_hand", "failed_steps_said")
    if "cat > files/kaya-shade-{seq}.txt" not in defs.get("report_shade_hand", ""):
        out.append(f"{RUNNER}: report_shade_hand does not write files/kaya-shade-<seq>.txt")
    scope = {}
    try:
        exec("\n\n".join(defs[k] for k in ("NOTIFY_TAP_TRIES", "shade_hand_acted",
                                            "shade_report_line", "failed_steps_said")), scope)
    except (KeyError, SyntaxError, NameError) as why:
        return out + [f"{RUNNER}: the shade report's functions could not be read ({why!r})"]
    for attempt, told, want in SENTENCES:
        got = scope["shade_report_line"](attempt, told)
        if got != want:
            out.append(f"{RUNNER}: shade_report_line misreports try {attempt} of {told!r}: "
                       f"{got!r}, wanted {want!r}")
    said = scope["failed_steps_said"]("chat-go", "", BUFFERS)
    lines = said.splitlines()
    if (not lines or "no KAYA_SELFTEST verdict" not in lines[0]
            or [ln.rsplit(" ", 1)[-1] for ln in lines[1:]] != ["first", "second"]):
        out.append(f"{RUNNER}: failed_steps_said does not list the app's failed steps first "
                   f"first under a missing verdict: {said!r}")
    ack = re.search(r're\.findall\(r"(KAYA_ACK: notify_tap \(\\d\+\))", dump\)', loop)
    if not ack or not re.findall(ack.group(1), "KAYA_ACK: notify_tap 2 gave up"):
        out.append(f"{RUNNER}: the runner's notify_tap ack does not read the app's "
                   f"`gave up` ack, so it taps on over the next steps")
    return out


def compose_findings(kt):
    out = []
    wait = kt_block(kt, "private fun kayaAwaitShadeHand(")
    if not wait:
        return [f"{COMPOSE}: no kayaAwaitShadeHand"]
    if '"kaya-shade-$seq.txt"' not in wait:
        out.append(f"{COMPOSE}: kayaAwaitShadeHand does not read kaya-shade-<seq>.txt, the "
                   f"file the runner writes")
    if not 0 <= wait.find("file.delete()") < wait.find('Log.i("kaya", request)'):
        out.append(f"{COMPOSE}: kayaAwaitShadeHand prints its request before deleting a stale "
                   f"report, so another leg's last try can end this wait")
    if 'if (head.getOrNull(1) != "acted")' not in wait or "attempt >= of" not in wait:
        out.append(f"{COMPOSE}: kayaAwaitShadeHand does not end on a final try that did not "
                   f"act")
    if "SHADE_DELIVERY_MS * 1_000_000" not in wait:
        out.append(f"{COMPOSE}: kayaAwaitShadeHand does not wait SHADE_DELIVERY_MS after the "
                   f"final try acted")
    ceiling, step = kt_const(kt, "SHADE_HAND_CEILING_MS"), kt_const(kt, "STEP_CEILING_MS")
    if ceiling is None or step is None or not ceiling < step:
        out.append(f"{COMPOSE}: SHADE_HAND_CEILING_MS ({ceiling}) must sit under "
                   f"STEP_CEILING_MS ({step}), or the step's ceiling speaks first")
    for fn, ack in (("kayaAwaitNotificationActivation", "KAYA_ACK: notify_tap $seq gave up"),
                    ("kayaAwaitNotificationReply", "KAYA_ACK: notify_reply $seq gave up")):
        body = kt_block(kt, f"private fun {fn}(")
        if "kayaAwaitShadeHand(activity, seq, request)" not in body or "nanoTime" in body:
            out.append(f"{COMPOSE}: {fn} does not wait through kayaAwaitShadeHand alone")
        if f'Log.i("kaya", "{ack}")' not in kt:
            out.append(f"{COMPOSE}: no `{ack}` after {fn} gives up, so the runner taps on")
    return out


SHIPPED_WAIT = """private fun kayaAwaitNotificationActivation(before: Int): String? {
        val deadline = System.nanoTime() + 20_000L * 1_000_000
        while (System.nanoTime() < deadline) {
            if (kayaNotificationActivations != before) return null
            Thread.sleep(RETRY_PERIOD_MS)
        }
        return "no activation reached this process in 20000ms"
    }
"""


def run(g):
    runner, kt = g.read(RUNNER), g.read(COMPOSE)
    for line in runner_findings(runner) + compose_findings(kt):
        g.finding(line)
    g.counted("shade hand: measured hand sentences reported", [s for _, s, _ in SENTENCES],
              floor=4)
    runner_cuts = [
        ("the tap's report cut",
         r"(told = tap_notification\(serial, title, log\)\n.*\n)"
         r"            reported = report_shade_hand\(serial, package, seq, tries \+ 1, told\)\n",
         r'\1            reported = ""\n', "tap_notification(serial, title, log)` is not followed"),
        ("the reply's report cut",
         r"(told = reply_notification\(serial, title, text, log\)\n.*\n)"
         r"            reported = report_shade_hand\(serial, package, seq, tries \+ 1, told\)\n",
         r'\1            reported = ""\n', "reply_notification(serial, title, text, log)` is not followed"),
        ("every try called acted", r'return told\.startswith\(\("tapped ", "typed "\)\)',
         "return True", "misreports try 3"),
        ("the report file renamed", r"cat > files/kaya-shade-\{seq\}\.txt",
         "cat > files/kaya-tap-{seq}.txt",
         "does not write files/kaya-shade-<seq>.txt"),
        ("the failed steps unprinted",
         r"        print\(failed_steps_said\(name, out, full_buffers\), file=log\)\n", "",
         "never prints failed_steps_said"),
        ("the failed steps read off the trace tail",
         r'if "KAYA_HARNESS: step-failed" in ln\]', "][-2:]", "first first under a missing"),
        ("the ack read only bare", r'KAYA_ACK: notify_tap \(\\d\+\)", dump\)',
         r'KAYA_ACK: notify_tap (\\d+)$", dump)', "does not read the app's `gave up` ack"),
    ]
    for label, pattern, repl, want in runner_cuts:
        broken = g.doctor(f"shade hand: {label}", runner, pattern, repl)
        g.negative(f"shade hand: {label}", lambda b=broken: runner_findings(b), want=want)
    kt_cuts = [
        ("the shipped fixed 20 s wait",
         r"private fun kayaAwaitNotificationActivation\([\s\S]*?\n    }\n", SHIPPED_WAIT,
         "kayaAwaitNotificationActivation does not wait through kayaAwaitShadeHand"),
        ("the report file renamed", r'"kaya-shade-\$seq\.txt"', '"kaya-tap-$seq.txt"',
         "does not read kaya-shade-<seq>.txt"),
        ("the stale report kept", r"(\n        )file\.delete\(\)\n(        Log\.i)",
         r"\1\2", "before deleting a stale report"),
        ("the missed final try waited out", r'if \(head\.getOrNull\(1\) != "acted"\)',
         "if (false)", "a final try that did not act"),
        ("the ceiling at the step's", r"const val SHADE_HAND_CEILING_MS = 50_000L",
         "const val SHADE_HAND_CEILING_MS = 60_000L", "must sit under STEP_CEILING_MS"),
        ("the tap's gave-up ack cut",
         r'\n *Log\.i\("kaya", "KAYA_ACK: notify_tap \$seq gave up"\)', "",
         "no `KAYA_ACK: notify_tap $seq gave up`"),
    ]
    for label, pattern, repl, want in kt_cuts:
        broken = g.doctor(f"shade hand: {label}", kt, pattern, repl)
        g.negative(f"shade hand: {label}", lambda b=broken: compose_findings(b), want=want)
