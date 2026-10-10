#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# THE MATRIX-WIDE EXCLUSIVE TOKEN IS WIRED WHERE IT CANNOT BE FORGOTTEN
# (tools/lib/exclusive.py). Every runner admits a leg through ONE funnel and
# that funnel must ask the token first, and hold it around the lane's own
# exclusive legs; a runner that stopped asking would run its input-driving
# legs under the other four lanes again and no lane could see it — the
# leg would merely flake, which is the state this pass came from. Beside
# it: every EXCLUSIVE name is a leg its lane actually runs (a name nothing
# wires is the "hand-queued and absent" defect of check-staging, one file
# over), the python and shell spellings say ONE set of sentences (two
# spellings of one sentence is how expect_ax's divergence lived for
# months), validate-all hands the directory to every lane and the
# container is told its path, and the sweep yields.
#
# AND THE MAC FUNNEL WAITS FOR AN IDLE HOST (clause 7, 2026-09-18): the
# token holds the other four lanes off, and nothing held off the HUMAN at
# the keyboard — matrix #38's save-java-swiftui died with every press
# swallowed while a browser was frontmost, and AX reported success for all
# three (docs/deferred.md, the swallowed-press entry). The wait sits BEFORE
# the hold, the clock read once more inside it without sleeping, and a wait
# under a held token is refused by the wait itself (docs/traps.md, the idle
# waits held the token); its three numbers are literals that fit the
# mac ceiling, its sentences say what they measured and that the leg runs
# anyway, its self-test door has exactly one reader, and a red mac leg's
# verdict line names the frontmost app AT THE MOMENT OF THE RED.

import contextlib
import importlib.util
import re
import tempfile

gate = Gate("check-exclusive")

LANES = [
    # (lane, runner, funnel function, roster module or shell)
    ("mac", "tools/validate-mac.py", "queue_leg", "tools/lib/lanes/mac.py"),
    ("windows", "tools/deploy-win.py", "run_suite", "tools/lib/lanes/win.py"),
    ("ios", "tools/ios/run-sim.py", "queue_leg", "tools/lib/lanes/ios.py"),
    ("android", "tools/android/run-emulator.py", "queue_leg", "tools/lib/lanes/android.py"),
]
LINUX = "tools/linux/run-suites.sh"
EXCLUSIVE_PY = "tools/lib/exclusive.py"
EXCLUSIVE_SH = "tools/linux/exclusive.sh"


def py_function(text, name):
    """A top-level def's body: from its line to the next top-level def."""
    m = re.search(r"^def " + re.escape(name) + r"\(", text, re.M)
    if not m:
        return ""
    rest = text[m.end():]
    nxt = re.search(r"^(?:def |class |[A-Za-z_]\w* = )", rest, re.M)
    return rest[: nxt.start()] if nxt else rest


def sh_function(text, name):
    at = text.find(f"\n{name}() {{")
    if at < 0:
        return ""
    start = text.find("{", at)
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def load_lane(rel):
    spec = importlib.util.spec_from_file_location("kaya_lane_exclusive", rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def roster(lane, mod):
    """Every leg name a lane can run, spelled as the lane spells it."""
    if lane == "android":
        return {leg for legs in mod.LEGS.values() for leg in legs}
    if lane == "windows":
        return {leg for block in mod.ORDER for leg in block}
    if lane == "mac":
        out = set()
        for entry in mod.ORDER:
            if entry[0] in ("drain", "panel_mode", "panel_check", "dark_leg"):
                continue
            scene, langs = entry
            out |= {mod.leg_name(scene, lang) for lang in langs}
        return out
    if lane == "ios":
        out = set()
        for e in mod.SWIFT_ENTRIES:
            out.add(f"{e.split(':')[0]}-swift")
        out |= {f"{s}-go" for s in mod.GO_SCENES}
        out |= {f"{s}-python" for s in mod.PYTHON_SCENES}
        out |= {f"{s}-swiftui" for s in mod.RUST_SCENES}
        return out
    return set()


def flatten_py(sentence):
    s = re.sub(r"\{[a-z_]+\}s\b", "<v>s", sentence)
    return re.sub(r"\{[a-z_]+\}", "<v>", s)


def flatten_sh(sentence):
    s = sentence
    s = re.sub(r"\$\(\([^)]*\)\)\.0s", "<v>s", s)
    s = re.sub(r"\$\{[A-Za-z_]+\}\.0s", "<v>s", s)
    s = re.sub(r"\$\{[A-Za-z_]+\}s\b", "<v>s", s)
    s = re.sub(r"\$[A-Za-z_][A-Za-z0-9_]*s\b(?=\s|;|,|$)", "<v>s", s)
    s = re.sub(r"\$\(\([^)]*\)\)", "<v>", s)
    s = re.sub(r"\$\{[^}]+\}", "<v>", s)
    s = re.sub(r"\$[A-Za-z_][A-Za-z0-9_]*", "<v>", s)
    s = re.sub(r"\$[0-9]+", "<v>", s)
    return s


# The sentences both spellings must say; the python module names them.
SHARED = ("waiting", "waited", "expired", "hold_waits", "held", "held_late",
          "hold_expired", "released", "broke", "summary")


MAC_RUNNER = "tools/validate-mac.py"
MAC_LANE = "tools/lib/lanes/mac.py"
# The idle wait's own sentence keys, and the phrase each must still carry —
# a sentence that stopped saying what it measured is believed anyway
# (CLAUDE.md invariant 3).
IDLE_SAYS = {
    "waiting": ("HIDIdleTime {idle}s", "wants {want}s", "(waited {waited}s of {bound}s)"),
    "cleared": ("HIDIdleTime {idle}s",),
    "expired": ("HIDIdleTime {idle}s", "running it anyway"),
    "spent": ("idle-wait budget", "HIDIdleTime {idle}s"),
    "unreadable": ("cannot read HIDIdleTime", "running without the idle wait"),
    "summary": ("idle waits", "budget", "display legs waited", "deferred"),
    "returned": ("in use again", "HIDIdleTime {idle}", "released it"),
    "returned-anyway": ("in use again", "running it anyway"),
    "returned-held": ("in use again", "NOT RUN"),
    "deferred": ("HIDIdleTime {idle}", "deferred to the lane's end"),
    "under-token": ("holds the matrix-wide token", "before exclusive.hold()"),
}
# Which function must print each key; the rest are idle_wait's.
IDLE_SAYS_IN = {"summary": "idle_summary", "returned": "idle_admit",
                "returned-anyway": "idle_admit", "returned-held": "idle_admit",
                "deferred": "_defer", "under-token": "_not_under_token"}


def literal(text, name):
    """A module-level `NAME = <number>` as a float, or None."""
    m = re.search(r"^" + re.escape(name) + r" = (\d+(?:\.\d+)?)$", text, re.M)
    return float(m.group(1)) if m else None


def mac_idle(texts, mod, tools):
    """Clause 7: the mac funnel waits for an idle host, inside the hold."""
    out = []
    runner, lane_text = texts[MAC_RUNNER], texts[MAC_LANE]
    body = py_function(runner, "queue_leg")
    deferred = py_function(runner, "run_deferred")
    admit_body = py_function(runner, "_admit")
    if not re.search(r'lane\.idle_admit\(name, lambda: exclusive\.hold\("mac", name\),'
                     r'\s*lambda: _leg_worker\(name, argv, env, scene\)\)', admit_body):
        out.append(f"{MAC_RUNNER}: _admit does not hand lane.idle_admit the token's hold and "
                   f"the leg as two callables — the order of the wait and the token is "
                   f"idle_admit's alone, and a wait inside the token makes every lane wait "
                   f"on the human (docs/traps.md, the idle waits held the token)")
    for fn, text in (("queue_leg", body), ("run_deferred", deferred)):
        if "_admit(name, argv, env, scene)" not in text:
            out.append(f"{MAC_RUNNER}: {fn} never admits through _admit(name, argv, env, "
                       f"scene) — an input-driving leg is admitted without asking whether a "
                       f"human is at the host (matrix #38's swallowed-press red, "
                       f"docs/deferred.md)")
    for fn, text in (("queue_leg", body), ("run_deferred", deferred), ("_admit", admit_body)):
        for direct in ("lane.idle_wait(", "lane.display_wait(", "exclusive.hold(\"mac\", name):"):
            if direct in text:
                out.append(f"{MAC_RUNNER}: {fn} calls {direct.rstrip(':')} itself — the "
                           f"order of the idle wait and the token is lane.idle_admit's, "
                           f"and a wait inside the token makes every lane wait on the human "
                           f"(docs/traps.md, the idle waits held the token)")
    if not re.search(r"\ndrain\(\)\nrun_deferred\(\)\n", runner):
        out.append(f"{MAC_RUNNER}: run_deferred() does not follow the lane's last drain() — "
                   f"a display leg a busy host deferred is never run or reported")
    if "lane.display_deadline()" not in deferred:
        out.append(f"{MAC_RUNNER}: run_deferred never starts lane.display_deadline() — "
                   f"each deferred leg would wait its own "
                   f"{getattr(mod, 'DISPLAY_BOUND_S', 0):.0f}s")
    if "lane.idle_summary()" not in runner:
        out.append(f"{MAC_RUNNER}: never prints lane.idle_summary() — what waiting for a "
                   f"quiet host cost this lane would stand nowhere")
    # THE THREE NUMBERS ARE LITERALS THAT FIT THE CEILING.
    want = literal(lane_text, "IDLE_S")
    bound = literal(lane_text, "IDLE_BOUND_S")
    budget = literal(lane_text, "IDLE_BUDGET_S")
    mm = re.search(r'^\s*"mac": (\d+),', texts["tools/validate-all.py"], re.M)
    ceiling = int(mm.group(1)) if mm else 0
    if want is None or bound is None or budget is None:
        out.append(f"{MAC_LANE}: IDLE_S / IDLE_BOUND_S / IDLE_BUDGET_S are not all "
                   f"module-level number literals — a bound read from somewhere else is "
                   f"a bound nobody can check against the lane's ceiling")
    elif not ceiling:
        out.append("tools/validate-all.py: BUDGETS names no mac ceiling to size the "
                   "idle wait against")
    else:
        if want >= bound:
            out.append(f"{MAC_LANE}: IDLE_S {want:.0f}s is not under IDLE_BOUND_S "
                       f"{bound:.0f}s — a bound shorter than the threshold can never "
                       f"clear, so every wait is the whole bound")
        if bound > budget:
            out.append(f"{MAC_LANE}: IDLE_BOUND_S {bound:.0f}s is over IDLE_BUDGET_S "
                       f"{budget:.0f}s — one leg would outspend the lane")
        if budget * 2 > ceiling:
            out.append(f"{MAC_LANE}: IDLE_BUDGET_S {budget:.0f}s is over half the mac "
                       f"lane's {ceiling}s ceiling — a lane may not spend that much of "
                       f"its wall waiting for a human, even with the waits netted out "
                       f"of the ceiling")
    # THE SENTENCES SAY WHAT THEY MEASURED.
    for key, phrases in IDLE_SAYS.items():
        fn = IDLE_SAYS_IN.get(key, "idle_wait")
        if f'IDLE_SENTENCES["{key}"]' not in py_function(lane_text, fn):
            out.append(f"{MAC_LANE}: {fn} never prints IDLE_SENTENCES[{key!r}] — a branch "
                       f"that says nothing is a state nobody can read")
        text = getattr(mod, "IDLE_SENTENCES", {}).get(key, "")
        for phrase in phrases:
            if phrase not in text:
                out.append(f"{MAC_LANE}: IDLE_SENTENCES[{key!r}] no longer says "
                           f"{phrase!r} — {text!r}")
    # THE SELF-TEST DOOR HAS EXACTLY ONE READER.
    door = getattr(mod, "IDLE_DOOR", "")
    if not door:
        out.append(f"{MAC_LANE}: no IDLE_DOOR — the wait's self-test door is unnamed")
    else:
        # The door's whole span: its own line, _hid_idle_ns() and idle_wait().
        # Neither the value nor the name may be spelled outside it.
        at = lane_text.find("IDLE_DOOR = ")
        end = lane_text.find("\ndef idle_summary(")
        off = 0
        for line_no, line in enumerate(lane_text.splitlines(), 1):
            inside = at >= 0 and end > at and at <= off < end
            if not inside and (door in line or "IDLE_DOOR" in line):
                out.append(f"{MAC_LANE}:{line_no}: names the idle wait's self-test door "
                           f"outside it — one reader, or a doctored run reads as a real "
                           f"one")
            off += len(line) + 1
        for rel, text in sorted(tools.items()):
            if rel == MAC_LANE or door not in text:
                continue
            out.append(f"{rel}: reads {door}, the mac idle wait's self-test door — a "
                       f"door with a second reader is no longer a door, and a doctored "
                       f"run would read as a real one")
    # A RED MAC LEG NAMES THE FRONTMOST APP, AT THE MOMENT OF THE RED.
    if "flightrec_lane.mac_frontmost(ROOT)" not in py_function(runner, "_leg_worker"):
        out.append(f"{MAC_RUNNER}: _leg_worker does not read "
                   f"flightrec_lane.mac_frontmost(ROOT) on a red — read at drain time "
                   f"instead, the pool has finished and the foreground has moved on")
    if '.front"' not in py_function(runner, "drain"):
        out.append(f"{MAC_RUNNER}: drain() does not put the frontmost reading on the "
                   f"leg's verdict line — the read would be one bundle away again "
                   f"(docs/deferred.md, the swallowed-press entry)")
    if "def mac_frontmost(" not in texts["tools/lib/flightrec_lane.py"]:
        out.append("tools/lib/flightrec_lane.py: no module-level mac_frontmost() — the "
                   "bundle's window census and the verdict line would read the window "
                   "list two ways")
    # A LEG THAT TAKES THE HOST'S DISPLAY IS EXCLUSIVE: entering fullscreen
    # switches the maintainer's screen to the guest's own Space and activates
    # the guest (docs/fullscreen-plan.md §4.1). Read out of the scene scripts,
    # never a hand list: any leg whose script reads a window fullscreen.
    for name, scene, _lang in mod.legs():
        script = mod.scene_script(ROOT, scene)
        takes = [line for line in script.splitlines()
                 if re.match(r"(expect_fullscreen|user_fullscreen)\b.*\bon\s*$", line.strip())]
        if takes and name not in mod.EXCLUSIVE:
            out.append(f"{MAC_LANE}: {name!r} is not EXCLUSIVE, yet its scene takes a window "
                       f"fullscreen ({takes[0].strip()!r}), which switches the host's display "
                       f"to a new Space and activates the guest (docs/fullscreen-plan.md "
                       f"§4.1)")
    # AND NEVER WHILE THE MAINTAINER IS ACTIVE (his ruling of 2026-09-28): the
    # same legs are DISPLAY_LEGS, whose wait refuses on expiry, the funnel and
    # the hand run each honour the refusal, and the refusal is run, not read.
    for name, scene, _lang in mod.legs():
        script = mod.scene_script(ROOT, scene)
        if any(re.match(r"(expect_fullscreen|user_fullscreen)\b.*\bon\s*$", line.strip())
               for line in script.splitlines()) \
                and name not in getattr(mod, "DISPLAY_LEGS", set()):
            out.append(f"{MAC_LANE}: {name!r} is not a DISPLAY_LEGS leg, so an expired idle "
                       f"wait runs it anyway and moves a present maintainer's display")
    if not (re.search(r'if outcome == "not-run":\n\s+_not_run\(name, said\)', body)
            and re.search(r'if outcome != "ran":\n\s+_not_run\(name, said\)', deferred)):
        out.append(f"{MAC_RUNNER}: queue_leg does not report a leg the idle wait refused "
                   f"as NOT RUN — it runs it, or loses it without a verdict")
    hand = texts["tools/run-leg.py"]
    if not re.search(r"refused = lane\.display_wait\(name\)\n\s+if refused:\n"
                     r"[\s\S]{0,120}?sys\.exit\(3\)", hand):
        out.append("tools/run-leg.py: a hand run of a DISPLAY_SCENES leg does not wait for "
                   "an idle host and stop when refused")
    out += display_refusal(mod)
    out += idle_under_token(mod)
    if "_mac.hid_idle_seconds()" not in texts["tools/validate-all.py"]:
        out.append("tools/validate-all.py: the launch line carries no HIDIdleTime — load "
                   "says how busy the machine is, never whether a human is at it")
    out += idle_netted(texts["tools/validate-all.py"], mod)
    return out


def idle_netted(va, mod):
    """The idle waits are netted out of the ceiling and printed beside the
    token's (docs/traps.md, the idle waits counted against the ceiling); the
    reader is run over its own summary sentence."""
    out = []
    if not re.search(r"idle = _mac\.idle_waited_seconds\(log_text\)\n"
                     r"\s+net = secs - waited - idle\n", va):
        out.append("tools/validate-all.py: the net read against a lane's ceiling does not "
                   "subtract _mac.idle_waited_seconds(log_text) — a matrix run while the "
                   "maintainer is at the host reads his minutes as the lane's work")
    if "{idle}s waiting for an idle host; {net}s net" not in va:
        out.append("tools/validate-all.py: never prints the idle-host seconds beside the "
                   "token's on the net line — a net nobody can recompute is believed anyway")
    reader = getattr(mod, "idle_waited_seconds", None)
    if reader is None:
        return out + [f"{MAC_LANE}: no idle_waited_seconds() — validate-all has nothing to "
                      f"read the idle waits back with"]
    line = mod.IDLE_SENTENCES["summary"].format(legs=4, secs=240, budget=240, display=120,
                                                deferred=9)
    for text, want in ((f"exclusive: mac held 1 legs for 5s\n{line}\nmac: PASS\n", 360),
                       ("mac: PASS\n", 0)):
        got = reader(text)
        if got != want:
            out.append(f"{MAC_LANE}: idle_waited_seconds read {got}s off {text!r}, wanted "
                       f"{want}s (the summary's own seconds plus its display seconds)")
    return out


def display_refusal(mod):
    """display_wait run against a doubled clock: a busy host is refused with
    a sentence, an idle one admitted, and an unreadable clock refused."""
    import types
    legs = sorted(getattr(mod, "DISPLAY_LEGS", ()))
    if not legs:
        return [f"{MAC_LANE}: DISPLAY_LEGS is empty, so no leg is held off a busy host"]
    out = []
    saved = (mod._hid_idle_ns, mod.time)
    try:
        for idle_s, want in ((5, "NOT RUN"), (10_000, None), (None, "NOT RUN")):
            now = [0.0]
            mod.time = types.SimpleNamespace(
                monotonic=lambda: now[0],
                sleep=lambda secs: now.__setitem__(0, now[0] + secs))
            mod._hid_idle_ns = ((lambda: (None, "doubled")) if idle_s is None
                                else (lambda v=idle_s: (int(v * 1e9), None)))
            said = []
            got = mod.idle_wait(legs[0], say=said.append)
            if want is None and got is not None:
                out.append(f"{MAC_LANE}: an idle host ({idle_s}s) refused "
                           f"{legs[0]!r}: {got!r}")
            if want is not None and (got is None or want not in got):
                out.append(f"{MAC_LANE}: HIDIdleTime {idle_s} ran the display leg "
                           f"{legs[0]!r} on a host nothing says is idle ({got!r})")
    finally:
        mod._hid_idle_ns, mod.time = saved
    return out


def idle_under_token(mod):
    """The rule the 2026-10-07 matrix broke, RUN: a wait under a held token
    refuses, and idle_admit never sleeps while its hold is open, defers a
    busy display leg in its queue position, re-waits outside the token when
    the human returns, and shares one bound across the lane's end."""
    import types
    out = []
    panel = sorted(getattr(mod, "EXCLUSIVE", set()) - getattr(mod, "DISPLAY_LEGS", set()))
    display = sorted(getattr(mod, "DISPLAY_LEGS", ()))
    if not panel or len(display) < 2 or not hasattr(mod, "idle_admit"):
        return [f"{MAC_LANE}: no idle_admit, or too few EXCLUSIVE and DISPLAY_LEGS legs "
                f"to run the token's idle rule against"]
    import exclusive
    saved = (mod._hid_idle_ns, mod.time, dict(mod._idle))
    quiet = exclusive._say
    exclusive._say = lambda _s: None
    # A busy host on a doubled clock: a cut wall must report, never sleep for real.
    wall = [0.0]
    mod.time = types.SimpleNamespace(monotonic=lambda: wall[0],
                                     sleep=lambda secs: wall.__setitem__(0, wall[0] + secs))
    mod._hid_idle_ns = lambda: (0, None)
    with tempfile.TemporaryDirectory(prefix="check-exclusive-") as td:
        for fn, leg in (("idle_wait", panel[0]), ("display_wait", display[0])):
            try:
                with exclusive.hold("check-exclusive", leg, exclusive_dir_=pathlib.Path(td)):
                    getattr(mod, fn)(leg, say=lambda _s: None)
                out.append(f"{MAC_LANE}: {fn} waited for the human while this process "
                           f"held the matrix-wide token — every other lane waits with it "
                           f"(docs/traps.md, the idle waits held the token)")
            except RuntimeError as e:
                if "holds the matrix-wide token" not in str(e):
                    out.append(f"{MAC_LANE}: {fn} under a held token raised {e!r}, not "
                               f"the under-token sentence")
    state = {"held": False, "holds": 0, "slept_held": 0, "slept": 0, "ran": 0}
    now = [0.0]

    def sleep(secs):
        state["slept"] += 1
        state["slept_held"] += state["held"]
        now[0] += secs

    @contextlib.contextmanager
    def hold():
        state["held"] = True
        state["holds"] += 1
        try:
            yield 0.0
        finally:
            state["held"] = False

    def run_case(leg, idles, deadline=None):
        state.update(held=False, holds=0, slept_held=0, slept=0, ran=0)
        seq = list(idles)
        mod._idle.update(saved[2], spent=0.0, legs=0, deadline=deadline)
        mod._hid_idle_ns = lambda: ((int(seq.pop(0) * 1e9) if len(seq) > 1
                                     else int(seq[0] * 1e9)), None)
        said = []
        try:
            got = mod.idle_admit(leg, hold, lambda: state.__setitem__("ran", state["ran"] + 1),
                                 say=said.append)
        except RuntimeError as e:
            got = ("raised", str(e))
        return got, said, dict(state)

    mod.time = types.SimpleNamespace(monotonic=lambda: now[0], sleep=sleep)
    try:
        cases = (
            ("a panel leg on a busy host that clears", panel[0], [3, 3, 60, 60], None,
             "ran", 1),
            ("a panel leg whose human returns inside the token", panel[0], [60, 2, 60, 60], None,
             "ran", 2),
            ("a display leg on a busy host in its queue position", display[0], [5], None,
             "deferred", 0),
            ("a display leg at the lane's end on a host that stays busy", display[0], [5],
             "start", "not-run", 0),
            ("a second display leg after the shared bound", display[1], [5], "spent",
             "not-run", 0),
            ("a display leg at the lane's end on an idle host", display[0], [10_000], "start",
             "ran", 1),
        )
        for label, leg, idles, deadline, want, holds in cases:
            at = (None if deadline is None else
                  now[0] + mod.DISPLAY_BOUND_S if deadline == "start" else now[0] - 1)
            t0 = now[0]
            got, said, st = run_case(leg, idles, at)
            waited = now[0] - t0
            if got[0] != want:
                out.append(f"{MAC_LANE}: idle_admit, {label}: answered {got!r}, wanted "
                           f"{want!r} ({said})")
            if st["slept_held"]:
                out.append(f"{MAC_LANE}: idle_admit, {label}: slept {st['slept_held']} "
                           f"time(s) while holding the token — every other lane waits on the "
                           f"human with it (docs/traps.md, the idle waits held the token)")
            if st["holds"] != holds:
                out.append(f"{MAC_LANE}: idle_admit, {label}: took the token {st['holds']} "
                           f"time(s), wanted {holds}")
            if want == "deferred" and st["slept"]:
                out.append(f"{MAC_LANE}: idle_admit, {label}: waited {waited:.0f}s in its "
                           f"queue position instead of deferring to the lane's end")
            if deadline == "spent" and waited > mod.IDLE_POLL_S:
                out.append(f"{MAC_LANE}: idle_admit, {label}: waited {waited:.0f}s after "
                           f"the lane's end had spent its shared {mod.DISPLAY_BOUND_S:.0f}s")
    finally:
        exclusive._say = quiet
        mod._hid_idle_ns, mod.time = saved[0], saved[1]
        mod._idle.clear()
        mod._idle.update(saved[2])
    return out


def shade_door(runner, tools):
    out = []
    rel = "tools/android/run-emulator.py"
    door = py_function(runner, "open_shade")
    expands = {name: text.count('"expand-notifications"') for name, text in tools.items()
               if name not in (rel, "tools/check-exclusive.py")}
    expands[rel] = runner.count('"expand-notifications"')
    stray = {name: n for name, n in expands.items() if n}
    if stray != {rel: 1} or door.count('"expand-notifications"') != 1:
        out.append(f"{rel}: expand-notifications is sent outside open_shade ({stray}) — an expand "
                   f"that lands before the last collapse is CLOSED opens the shade without focus "
                   f"and uiautomator dumps the app")
    at = door.find('"expand-notifications"')
    gone = door.find('wait_shade(serial, "gone", SHADE_GONE_S)')
    if not (0 <= door.find('"statusbar", "collapse"') < gone < at):
        out.append(f"{rel}: open_shade does not collapse and wait for the shade's window to be "
                   f"gone before it expands")
    if door.find('wait_shade(serial, "open",') < at:
        out.append(f"{rel}: open_shade does not wait for the shade's window to be open and "
                   f"focusable after it expands")
    for hand in ("tap_notification", "reply_notification"):
        if "open_shade(serial, log)" not in py_function(runner, hand):
            out.append(f"{rel}: {hand} does not open the shade through open_shade")
    scope = {"re": re}
    try:
        exec(py_def(runner, "shade_state") + "\n" + py_def(runner, "SHADE_READINGS"), scope)
        misread = {want: scope["shade_state"](text)
                   for want, text in scope["SHADE_READINGS"].items()
                   if scope["shade_state"](text) != want}
        wanted = set(scope["SHADE_READINGS"])
    except (KeyError, SyntaxError, NameError) as why:
        misread, wanted = {"exec": repr(why)}, set()
    if misread or wanted != {"gone", "open", "unfocusable", "unreadable"}:
        out.append(f"{rel}: shade_state misread its measured readings {misread} "
                   f"(readings {sorted(wanted)})")
    return out


def py_def(text, name):
    """A top-level def or assignment's exact source, by ast."""
    import ast
    for node in ast.parse(text).body:
        names = ([node.name] if isinstance(node, ast.FunctionDef)
                 else [t.id for t in getattr(node, "targets", []) if isinstance(t, ast.Name)])
        if name in names:
            return ast.get_source_segment(text, node)
    return ""


def census(texts, lanes=None, tools=None):
    out = []
    lanes = lanes or {}
    # 1. THE FUNNELS ASK AND HOLD.
    for lane, runner, funnel, roster_rel in LANES:
        body = py_function(texts[runner], funnel)
        if not body:
            out.append(f"{runner}: no `def {funnel}(` to read — the funnel moved")
            continue
        if f'exclusive.wait("{lane}", name)' not in body:
            out.append(f"{runner}: {funnel} does not call exclusive.wait(\"{lane}\", name) — the "
                       f"lane starts legs while another holds the token")
        # The mac funnel holds through _admit, which idle_admit orders.
        held_in = body + (py_function(texts[runner], "_admit")
                          if "_admit(name, argv, env, scene)" in body else "")
        if f'exclusive.hold("{lane}", name)' not in held_in:
            out.append(f"{runner}: {funnel} never holds the token for the lane's exclusive legs")
        if 'os.environ.get("KAYA_EXCLUSIVE", "")' not in body:
            out.append(f"{runner}: {funnel} does not read KAYA_EXCLUSIVE — --exclusive and "
                       f"--no-exclusive would run everything on this lane")
        if "lane.EXCLUSIVE" not in body:
            out.append(f"{runner}: {funnel} does not read lane.EXCLUSIVE — the set is data nobody "
                f"uses")
        if "import exclusive" not in texts[runner]:
            out.append(f"{runner}: does not import exclusive")
        if f'exclusive.summary("{lane}")' not in texts[runner]:
            out.append(f"{runner}: never prints exclusion's summary — the wall cost of exclusion "
                       f"would "
                       f"stand nowhere beside the lane's duration")
        # 2. EVERY EXCLUSIVE NAME IS A LEG THE LANE RUNS.
        mod = lanes.get(lane)
        if mod is not None:
            known = roster(lane, mod)
            if len(known) < 10:
                out.append(f"{roster_rel}: the roster read {len(known)} legs — a reader that "
                           f"finds that few agrees with anything")
            for name in sorted(getattr(mod, "EXCLUSIVE", set())):
                if name not in known:
                    out.append(f"{roster_rel}: EXCLUSIVE names {name!r}, which no leg of this lane "
                               f"is "
                               f"called — an exclusive set naming nothing excludes nothing")
    # 3. THE LINUX HALF.
    sh = texts[LINUX]
    run_body = sh_function(sh, "run")
    for want in ('kaya_exclusive_wait linux "$name-$proto"',
                 'kaya_exclusive_hold_begin linux "$name-$proto"',
                 'kaya_exclusive_hold_end linux "$name-$proto"'):
        if want not in run_body:
            out.append(f"{LINUX}: run() lacks `{want}`")
    if ("source /work/tools/linux/exclusive.sh" not in sh
            or "kaya_exclusive_selftest linux" not in sh):
        out.append(f"{LINUX}: does not source tools/linux/exclusive.sh and run its self-test")
    if 'case "${KAYA_EXCLUSIVE:-}" in' not in run_body:
        out.append(f"{LINUX}: run() does not read KAYA_EXCLUSIVE")
    if "kaya_exclusive_summary linux" not in sh:
        out.append(f"{LINUX}: never prints exclusion's summary")
    m = re.search(r'^KAYA_EXCLUSIVE_LEGS="([^"]*)"', sh, re.M)
    if not m:
        out.append(f"{LINUX}: no KAYA_EXCLUSIVE_LEGS line")
    else:
        for name in m.group(1).split():
            stem, _, proto = name.rpartition("-")
            if proto not in ("x11", "wayland") or not re.search(
                    r'run "\$proto" ' + re.escape(stem) + r"\b", sh):
                out.append(f"{LINUX}: KAYA_EXCLUSIVE_LEGS names {name!r}, which no `run \"$proto\" "
                           f"{stem}` line runs")
    # 4. ONE SET OF SENTENCES.
    py = texts[EXCLUSIVE_PY]
    py_sentences = {}
    for key in SHARED:
        mm = re.search(r'^\s*"' + key + r'": "([^"]*)",', py, re.M)
        if mm:
            py_sentences[key] = flatten_py(mm.group(1))
        else:
            out.append(f"{EXCLUSIVE_PY}: SENTENCES lacks {key!r}")
    sh_sentences = {flatten_sh(s)
                    for s in re.findall(r'echo "(exclusive: [^"]*)"', texts[EXCLUSIVE_SH])}
    for key, flat in py_sentences.items():
        if flat not in sh_sentences:
            out.append(f"{EXCLUSIVE_SH}: does not say the python module's {key!r} sentence "
                       f"({flat!r}) — two spellings of one protocol")
    # 5. A NOTIFICATION LEG NEVER RUNS IN THE POOL AN EXCLUSIVE FUNNEL
    # DRAINS. The windows funnel JOINS every leg started before the
    # exclusive one in its block, and the block before it has just drained
    # — so a notification delivered there is in flight exactly when the
    # typing leg foregrounds, and the shell's notification host window
    # comes up ~2s later holding the foreground with nothing in it
    # (docs/deferred.md, the phantom notification window).
    win = lanes.get("windows")
    if win is not None:
        notify_legs = win.notification_legs(str(ROOT / "tools/scenes"))
        if not notify_legs:
            out.append("tools/lib/lanes/win.py: notification_legs read no leg at all — a census "
                       "that finds none agrees with every order")
        blame = ("the exclusive funnel joins it, so its toast is in flight when {leg} "
                 "foregrounds to type, and the shell's notification host window comes up ~2s "
                 "later holding the foreground with nothing in it for 30s "
                 "(docs/deferred.md, the phantom notification window). Move the notification "
                 "leg after the exclusive one")
        for at, block in enumerate(win.ORDER):
            for i, leg in enumerate(block):
                if leg not in win.EXCLUSIVE:
                    continue
                for name in [n for n in block[:i] if n in notify_legs]:
                    out.append(f"tools/lib/lanes/win.py: {name!r} is pooled before the exclusive "
                               f"leg {leg!r} in the same block — "
                               + blame.format(leg=leg))
                if i:
                    continue
                for name in [n for n in win.ORDER[at - 1] if n in notify_legs] if at else []:
                    out.append(f"tools/lib/lanes/win.py: {name!r} ends the block before the one "
                               f"{leg!r} opens — the drain between blocks joins it and "
                               + blame.format(leg=leg))
    # 5b. A WINDOWS LEG THAT TAKES A WINDOW FULLSCREEN IS EXCLUSIVE: the
    # window covers the VM's display and the user half presses F11 on the
    # system input queue (docs/fullscreen-plan.md §5). Read out of the scene
    # scripts, the mac clause's way.
    if win is not None:
        for leg in win.legs():
            scene, _lang = win.scene_lang(leg)
            steps = ROOT / "tools/scenes" / f"{scene}.steps"
            if not steps.exists():
                continue
            takes = [line for line in steps.read_text(encoding="utf-8").splitlines()
                     if re.match(r"(expect_fullscreen|user_fullscreen)\b.*\bon\s*$", line.strip())]
            if takes and leg not in win.EXCLUSIVE:
                out.append(f"tools/lib/lanes/win.py: {leg!r} is not EXCLUSIVE, yet its scene takes "
                           f"a window fullscreen ({takes[0].strip()!r}), which covers the VM's "
                           f"display and presses F11 on the system input queue "
                           f"(docs/fullscreen-plan.md §5)")
    # 5c. THE ANDROID QUIET TAIL (the maintainer's ruling of 2026-10-05):
    # every QUIET leg is an EXCLUSIVE leg the lane runs, and the runner's leg
    # selection reads KAYA_QUIET; tools/check-gates.py holds validate-all's half.
    android = lanes.get("android")
    if android is not None and hasattr(android, "QUIET"):
        for leg in sorted(android.QUIET - android.EXCLUSIVE):
            out.append(f"tools/lib/lanes/android.py: QUIET leg {leg!r} is not EXCLUSIVE — "
                       f"run in place by hand, it would share the host with the pool")
        for leg in sorted(android.QUIET - set(roster("android", android))):
            out.append(f"tools/lib/lanes/android.py: QUIET leg {leg!r} is no leg the lane runs")
    selected = py_function(texts["tools/android/run-emulator.py"], "selected_legs")
    if "lane.QUIET" not in selected or "QUIET_MODE" not in selected:
        out.append("tools/android/run-emulator.py: selected_legs does not read lane.QUIET "
                   "under KAYA_QUIET, so the matrix's two Android runs would each run every "
                   "microphone leg or none (docs/traps.md, the emulator's audio input entry)")
    # 6. THE COORDINATOR HANDS THE DIRECTORY; THE SWEEP YIELDS.
    if 'os.environ["KAYA_EXCLUSIVE_DIR"] = ' not in texts["tools/validate-all.py"]:
        out.append("tools/validate-all.py: never sets KAYA_EXCLUSIVE_DIR — the lanes cannot share "
                   "a token")
    if "KAYA_EXCLUSIVE_DIR=/flightrec-state/kaya/exclusive" not in texts["tools/validate-linux.py"]:
        out.append("tools/validate-linux.py: does not tell the container where the token lives")
    if 'exclusive.wait("gates", name)' not in texts["tools/gates.py"]:
        out.append("tools/gates.py: the sweep does not yield to a held token")
    # 6b. THE WINDOWS LANE REFUSES A DISPLAY ITS LEGS DO NOT ASSUME
    # (docs/traps.md, the UTM entry): desk_warm asks screens_refusal, which
    # is run here against the shipped reading and against doctored ones.
    if "lane.screens_refusal(out)" not in py_function(texts["tools/deploy-win.py"], "desk_warm"):
        out.append("tools/deploy-win.py: desk_warm never asks lane.screens_refusal(out), so the "
                   "lane runs its legs on whatever screens the interactive session has")
    if win is not None:
        ok = "deskwarm.screen=\\\\.\\DISPLAY2 primary=True 1280x800\n"
        for reading, want in ((ok, None),
                              (ok + "deskwarm.screen=\\\\.\\DISPLAY3 primary=False 800x600\n",
                               "800x600"),
                              ("deskwarm.screen=\\\\.\\DISPLAY1 primary=True 1024x768\n",
                               "1024x768"),
                              ("deskwarm.verdict=OK\n", "no screen at all")):
            got = win.screens_refusal(reading)
            if want is None and got is not None:
                out.append(f"tools/lib/lanes/win.py: screens_refusal refused the lane's own "
                           f"one 1280x800 screen: {got!r}")
            if want is not None and (got is None or want not in got
                                     or "DisplaySwitch.exe /internal" not in got):
                out.append(f"tools/lib/lanes/win.py: screens_refusal admitted or misnamed the "
                           f"reading {reading.strip()!r} ({got!r})")
    # 6c. THE ANDROID SHADE OPENS THROUGH ONE DOOR (docs/traps.md, the shade
    # an expand reopens without focus).
    out += shade_door(texts["tools/android/run-emulator.py"],
                      TOOLS if tools is None else tools)
    # 7. THE MAC FUNNEL WAITS FOR AN IDLE HOST.
    mac_mod = lanes.get("mac")
    if mac_mod is not None:
        out += mac_idle(texts, mac_mod, TOOLS if tools is None else tools)
    return out


FILES = [r for _, r, _, _ in LANES] + [LINUX, EXCLUSIVE_PY, EXCLUSIVE_SH, "tools/validate-all.py",
                                        "tools/validate-linux.py", "tools/gates.py",
                                        "tools/lib/flightrec_lane.py", MAC_LANE,
                                        "tools/run-leg.py"]
REAL = {rel: gate.read(rel) for rel in FILES}
MODS = {lane: load_lane(r) for lane, _, _, r in LANES}

# EVERY RUNNER AND GATE IN tools/, for the door's one-reader clause: a
# self-test door read by a second script is a knob, and a doctored run
# would then read as a real one.
TOOLS = {str(p.relative_to(ROOT)): p.read_text(encoding="utf-8", errors="replace")
         for p in gate.walk("*.py", "*.sh", "*.ps1", under="tools")}


def watched(label, texts, want, lanes=None, tools=None):
    gate.negative(label,
                  lambda: census(texts, lanes if lanes is not None else MODS, tools),
                  want=want)


# 1. A RUNNER STOPS ASKING.
no_wait = gate.doctor("the ios wait cut out", REAL["tools/ios/run-sim.py"],
                      r'\n\s*exclusive\.wait\("ios", name\)\n', "\n")
watched("an iOS funnel that starts legs under a held token",
        {**REAL, "tools/ios/run-sim.py": no_wait}, 'exclusive.wait("ios", name)')

# 2. A RUNNER STOPS HOLDING.
no_hold = gate.doctor("the android hold renamed", REAL["tools/android/run-emulator.py"],
                      r'with exclusive\.hold\("android", name\)',
                      'with exclusive.hold("droid", name)')
watched("an android funnel that never holds",
        {**REAL, "tools/android/run-emulator.py": no_hold}, "never holds the token")

# 3. AN EXCLUSIVE NAME NOTHING RUNS.
class Ghost:
    pass
ghost = Ghost()
for attr in ("LEGS",):
    setattr(ghost, attr, MODS["android"].LEGS)
ghost.EXCLUSIVE = MODS["android"].EXCLUSIVE | {"dnd-ghost"}
watched("an android EXCLUSIVE name no leg is called", REAL, "dnd-ghost",
        lanes={**MODS, "android": ghost})

# 4. THE LINUX FUNNEL STOPS HOLDING.
sh_no_hold = gate.doctor("the linux hold_begin cut out", REAL[LINUX],
                         r'\n\s*kaya_exclusive_hold_begin linux "\$name-\$proto"\n', "\n")
watched("a linux run() that never holds", {**REAL, LINUX: sh_no_hold}, "kaya_exclusive_hold_begin")

# 5. THE SHELL DRIFTS FROM THE PYTHON SENTENCE.
sh_drift = gate.doctor("the shell release sentence reworded", REAL[EXCLUSIVE_SH],
                       r'echo "exclusive: \$lane released after \$leg',
                       'echo "exclusive: $lane let go after $leg')
watched("a shell sentence the python module does not say", {**REAL, EXCLUSIVE_SH: sh_drift},
        "does not say the python module's 'released'")

# 6. THE COORDINATOR FORGETS THE DIRECTORY.
no_dir = gate.doctor("validate-all's KAYA_EXCLUSIVE_DIR line cut", REAL["tools/validate-all.py"],
                     r'os\.environ\["KAYA_EXCLUSIVE_DIR"\] = str\(EXCLUSIVE_DIR\)\n', "\n")
watched("a matrix whose lanes share no token", {**REAL, "tools/validate-all.py": no_dir},
        "never sets KAYA_EXCLUSIVE_DIR")

# 7. A LANE STOPS SAYING WHAT EXCLUSION COST IT.
no_summary = gate.doctor("the mac summary cut out", REAL["tools/validate-mac.py"],
                         r'\n\s*exclusive\.summary\("mac"\)\n', "\n")
watched("a mac lane with no exclusion summary", {**REAL, "tools/validate-mac.py": no_summary},
        "never prints exclusion's summary")

# 8. A RUNNER STOPS READING THE MODE.
no_mode = gate.doctor("the windows mode read cut out", REAL["tools/deploy-win.py"],
                      r'mode = os\.environ\.get\("KAYA_EXCLUSIVE", ""\)',
                      'mode = ""')
watched("a windows funnel that ignores --exclusive", {**REAL, "tools/deploy-win.py": no_mode},
        "does not read KAYA_EXCLUSIVE")

# 9. A NOTIFICATION LEG BACK IN THE POOL THE EXCLUSIVE FUNNEL DRAINS —
# the roster as it stood before the phantom slice, one leg moved. A DATA
# perturbation, so the copy is a doctored win.py loaded as a module.
WIN_LANE = "tools/lib/lanes/win.py"
_moved = gate.doctor("the windows notify leg lifted out from after notes_rust",
                     gate.read(WIN_LANE),
                     r'\n     # The notification conformance scene[\s\S]*?\n     "notify_rust",\n',
                     "\n")
_moved = gate.doctor("the windows notify leg put back before notes_rust", _moved,
                     r'\n     "richrows_rust",\n',
                     '\n     "richrows_rust",\n     "notify_rust",\n')
_ghost_win = gate.scratch() / "win-notify-before-notes.py"
_ghost_win.write_text(_moved, encoding="utf-8")
watched("a windows pool whose notification leg the exclusive funnel drains", REAL,
        "is pooled before the exclusive leg 'notes_rust'",
        lanes={**MODS, "windows": load_lane(_ghost_win)})

# 10. THE MAC WAIT CUT OUT — the state the tree was in until 2026-09-18.
_no_idle = gate.doctor("the mac idle admission cut from queue_leg", REAL[MAC_RUNNER],
                       r'outcome, said = _admit\(name, argv, env, scene\)\n'
                       r'(\s+)if outcome == "deferred":',
                       r'outcome, said = "ran", _leg_worker(name, argv, env, scene)\n'
                       r'\1if outcome == "deferred":')
watched("a mac funnel that admits an input-driving leg without asking about the human",
        {**REAL, MAC_RUNNER: _no_idle}, "queue_leg never admits through _admit")

# 11. THE WAIT PUT BACK INSIDE THE HOLD — the shape the 2026-10-07 matrix
# ran, which held every other lane on the human for 241s.
_inside = gate.doctor("the mac idle wait put back inside the hold", REAL[MAC_RUNNER],
                      r'    return lane\.idle_admit\(name, lambda: exclusive\.hold\("mac", name\),'
                      r'\n\s+lambda: _leg_worker\(name, argv, env, scene\)\)\n',
                      '    with exclusive.hold("mac", name):\n'
                      '        refused = lane.idle_wait(name)\n'
                      '        return (("not-run", refused) if refused\n'
                      '                else ("ran", _leg_worker(name, argv, env, scene)))\n')
watched("a mac idle wait inside the token's hold",
        {**REAL, MAC_RUNNER: _inside}, "_admit calls lane.idle_wait( itself")

# 12. A BUDGET THE CEILING CANNOT PAY.
_fat = gate.doctor("the mac idle budget raised past half the ceiling", REAL[MAC_LANE],
                   r"^IDLE_BUDGET_S = \d+(?:\.\d+)?$", "IDLE_BUDGET_S = 900.0", flags=re.M)
_fat_mod = gate.scratch() / "mac-fat-budget.py"
_fat_mod.write_text(_fat, encoding="utf-8")
watched("a mac idle budget over half the lane's ceiling", {**REAL, MAC_LANE: _fat},
        "over half the mac lane's", lanes={**MODS, "mac": load_lane(_fat_mod)})

# 13. THE EXPIRY STOPS SAYING THE LEG RUNS ANYWAY — a reader would then
# take the sentence for a refusal and hunt the tree for the red's cause.
_quiet = gate.doctor("the mac expiry sentence's promise reworded", REAL[MAC_LANE],
                     '— running it anyway, so "\n *"a red here is the host\'s',
                     "— giving up")
_quiet_mod = gate.scratch() / "mac-quiet-expiry.py"
_quiet_mod.write_text(_quiet, encoding="utf-8")
watched("a mac expiry sentence that stopped saying the leg runs", {**REAL, MAC_LANE: _quiet},
        "no longer says 'running it anyway'", lanes={**MODS, "mac": load_lane(_quiet_mod)})

# 14. A SECOND READER OF THE SELF-TEST DOOR.
_knob = {**TOOLS, "tools/validate-mac.py": TOOLS["tools/validate-mac.py"]
         + '\nif os.environ.get("KAYA_HID_IDLE_NS_OVERRIDE", ""):\n    pass\n'}
watched("a self-test door with a second reader", REAL,
        "the mac idle wait's self-test door", tools=_knob)

# 15. A RED MAC LEG THAT NAMES NOBODY.
_blind = gate.doctor(
    "the mac frontmost read cut from _leg_worker", REAL[MAC_RUNNER],
    r'\n *if verdict != "PASS":\n[\s\S]*?'
    r'flightrec_lane\.mac_frontmost\(ROOT\) \+ "\\n", encoding="utf-8"\)\n',
    "\n")
watched("a red mac leg whose verdict line names no frontmost app",
        {**REAL, MAC_RUNNER: _blind}, "does not read flightrec_lane.mac_frontmost(ROOT)")

# 16. A FULLSCREEN LEG BACK IN THE POOL.
_pooled = gate.doctor("fullscreen taken out of the mac host-UI scenes", REAL[MAC_LANE],
                      r'HOST_UI_SCENES = \("emoji", "fullscreen"\)', 'HOST_UI_SCENES = ("emoji",)')
_pooled_mod = gate.scratch() / "mac-fullscreen-pooled.py"
_pooled_mod.write_text(_pooled, encoding="utf-8")
watched("a mac fullscreen leg run in the pool", {**REAL, MAC_LANE: _pooled},
        "'fullscreen-rust-swiftui' is not EXCLUSIVE", lanes={**MODS, "mac": load_lane(_pooled_mod)})

# 17. FULLSCREEN NO LONGER A DISPLAY LEG.
_ran = gate.doctor("fullscreen taken out of the mac display scenes", REAL[MAC_LANE],
                   r'DISPLAY_SCENES = \("fullscreen",\)', "DISPLAY_SCENES = ()")
_ran_mod = gate.scratch() / "mac-fullscreen-not-display.py"
_ran_mod.write_text(_ran, encoding="utf-8")
watched("a mac fullscreen leg an expired wait runs anyway", {**REAL, MAC_LANE: _ran},
        "is not a DISPLAY_LEGS leg", lanes={**MODS, "mac": load_lane(_ran_mod)})

# 18. THE FUNNEL RUNNING A REFUSED LEG.
_ignored = gate.doctor("queue_leg running a refused leg", REAL[MAC_RUNNER],
                       r'(if outcome == "not-run":\n\s+)_not_run\(name, said\)',
                       r"\1_leg_worker(name, argv, env, scene)")
watched("a mac funnel that runs a leg its idle wait refused",
        {**REAL, MAC_RUNNER: _ignored}, "does not report a leg the idle wait refused")

# 19. THE WAIT ADMITTING A BUSY HOST.
_admits = gate.doctor("display_wait admitting on expiry", REAL[MAC_LANE],
                      r'(        if waited >= bound:\n            _idle\["display"\] \+= waited\n'
                      r"[\s\S]*?)return refused\n",
                      r"\1return None\n")
_admits_mod = gate.scratch() / "mac-display-admits.py"
_admits_mod.write_text(_admits, encoding="utf-8")
watched("a display wait that runs its leg on a busy host", {**REAL, MAC_LANE: _admits},
        "HIDIdleTime 5 ran the display leg", lanes={**MODS, "mac": load_lane(_admits_mod)})

# 20. THE HAND RUN MOVING THE DISPLAY.
_hand = gate.doctor("run-leg's display wait cut", REAL["tools/run-leg.py"],
                    r"refused = lane\.display_wait\(name\)", "refused = None")
watched("a hand run of a display leg that never waits", {**REAL, "tools/run-leg.py": _hand},
        "a hand run of a DISPLAY_SCENES leg")

# 20b. THE WAIT'S OWN WALL CUT: a wait under a held token no longer refuses.
_LANE_TEXT = gate.read(MAC_LANE)
_unwalled = gate.doctor("the under-token wall cut from both waits", _LANE_TEXT,
                        r"\n    _not_under_token\(leg\)\n", "\n", want=2)
_unwalled_mod = gate.scratch() / "mac-unwalled.py"
_unwalled_mod.write_text(_unwalled, encoding="utf-8")
watched("an idle wait that runs under a held token", REAL,
        "idle_wait waited for the human while this process held the matrix-wide token",
        lanes={**MODS, "mac": load_lane(_unwalled_mod)})

# 20c. idle_admit WAITING INSIDE ITS HOLD, the wall cut too so the sleep is
# what the clause sees.
_slept = gate.doctor("idle_admit's wait moved inside its hold", _unwalled,
                     r'        refused = idle_wait\(leg, say\)\n        if refused:\n'
                     r'            return "not-run", refused\n        with hold\(\):\n',
                     '        with hold():\n            refused = idle_wait(leg, say)\n'
                     '            if refused:\n                return "not-run", refused\n')
_slept_mod = gate.scratch() / "mac-slept-held.py"
_slept_mod.write_text(_slept, encoding="utf-8")
watched("idle_admit sleeping while it holds the token", REAL,
        "time(s) while holding the token", lanes={**MODS, "mac": load_lane(_slept_mod)})

# 20d. A BUSY DISPLAY LEG WAITING IN ITS QUEUE POSITION.
_in_place = gate.doctor("the display deferral cut", _LANE_TEXT,
                        r'in_place = leg in DISPLAY_LEGS and _idle\["deadline"\] is None',
                        "in_place = False")
_in_place_mod = gate.scratch() / "mac-display-in-place.py"
_in_place_mod.write_text(_in_place, encoding="utf-8")
watched("a busy display leg that waits where it is queued", REAL,
        "in its queue position: answered", lanes={**MODS, "mac": load_lane(_in_place_mod)})

# 20e. EVERY DEFERRED LEG ITS OWN BOUND.
_own_bound = gate.doctor("the shared deadline ignored", _LANE_TEXT,
                         r'bound = \(DISPLAY_BOUND_S if _idle\["deadline"\] is None\n'
                         r'\s+else max\(0\.0, _idle\["deadline"\] - started\)\)',
                         "bound = DISPLAY_BOUND_S")
_own_bound_mod = gate.scratch() / "mac-own-bound.py"
_own_bound_mod.write_text(_own_bound, encoding="utf-8")
watched("deferred display legs each waiting a whole bound", REAL,
        "after the lane's end had spent its shared",
        lanes={**MODS, "mac": load_lane(_own_bound_mod)})

# 20f. THE DEFERRED LEGS NEVER RUN.
_no_end = gate.doctor("run_deferred() cut from the lane's end", REAL[MAC_RUNNER],
                      r"\ndrain\(\)\nrun_deferred\(\)\n", "\ndrain()\n")
watched("a mac lane that never runs its deferred display legs",
        {**REAL, MAC_RUNNER: _no_end}, "run_deferred() does not follow the lane's last drain()")

# 21. A WINDOWS FULLSCREEN LEG BACK IN THE POOL.
_win_pooled = gate.doctor("fullscreen_go taken out of the windows EXCLUSIVE set",
                          gate.read(WIN_LANE), r'\n *"fullscreen_go", ', "\n             ")
_win_pooled_mod = gate.scratch() / "win-fullscreen-pooled.py"
_win_pooled_mod.write_text(_win_pooled, encoding="utf-8")
watched("a windows fullscreen leg run in the pool", REAL,
        "'fullscreen_go' is not EXCLUSIVE", lanes={**MODS, "windows": load_lane(_win_pooled_mod)})

# 22. THE WINDOWS WARM-UP STOPS ASKING ABOUT THE SCREENS.
_any_screen = gate.doctor("desk_warm's screens read cut", REAL["tools/deploy-win.py"],
                          r"refused = lane\.screens_refusal\(out\)", "refused = None")
watched("a windows warm-up that runs its legs on two screens",
        {**REAL, "tools/deploy-win.py": _any_screen}, "never asks lane.screens_refusal(out)")

# 23. THE DECISION ADMITS ANY READING.
_admits_all = gate.doctor("screens_refusal admitting every reading", gate.read(WIN_LANE),
                          r"(def screens_refusal\(warmup\):\n(?: .*\n)*?) +read = ",
                          r"\1    return None\n    read = ")
_admits_all_mod = gate.scratch() / "win-screens-admit.py"
_admits_all_mod.write_text(_admits_all, encoding="utf-8")
watched("a windows lane admitting the phantom second display", REAL,
        "admitted or misnamed the reading", lanes={**MODS, "windows": load_lane(_admits_all_mod)})

# 24. THE ANDROID RUNNER STOPS READING KAYA_QUIET.
_unquiet = gate.doctor("selected_legs' quiet filter cut", REAL["tools/android/run-emulator.py"],
                       r"\n    if QUIET_MODE:\n        legs = \[leg for leg in legs if "
                       r"\(leg in lane\.QUIET\) == \(QUIET_MODE == \"only\"\)\]",
                       "")
watched("an android runner that ignores KAYA_QUIET",
        {**REAL, "tools/android/run-emulator.py": _unquiet},
        "selected_legs does not read lane.QUIET")

# 25. A QUIET LEG THAT IS NOT EXCLUSIVE.
_loud = Ghost()
_loud.LEGS = MODS["android"].LEGS
_loud.EXCLUSIVE = MODS["android"].EXCLUSIVE - {"capture-go"}
_loud.QUIET = MODS["android"].QUIET
watched("an android QUIET leg outside EXCLUSIVE", REAL, "QUIET leg 'capture-go' is not EXCLUSIVE",
        lanes={**MODS, "android": _loud})

# 26-30. THE ANDROID SHADE'S DOOR.
_runner = REAL["tools/android/run-emulator.py"]
_bare = gate.doctor("an expand back in tap_notification", _runner,
                    r"    try:\n        opened, said = open_shade\(serial, log\)\n"
                    r"        if not opened:\n            return f\"the shade never opened with "
                    r"focus \(\{said\}\)\"\n        for attempt in range\(1, 5\):",
                    '    run(["adb", "-s", serial, "shell", "cmd", "statusbar",\n'
                    '         "expand-notifications"], stdout=log, stderr=log)\n'
                    '    try:\n        for attempt in range(1, 5):')
watched("a shade tap that expands on its own", {**REAL, "tools/android/run-emulator.py": _bare},
        "expand-notifications is sent outside open_shade",
        tools={**TOOLS, "tools/android/run-emulator.py": _bare})
_nogone = gate.doctor("the gone wait cut", _runner,
                      r'before, ms, seen = wait_shade\(serial, "gone", SHADE_GONE_S\)',
                      'before, ms, seen = "gone", 0, ["skipped"]')
watched("a door that expands into an unfinished collapse",
        {**REAL, "tools/android/run-emulator.py": _nogone},
        "wait for the shade's window to be gone")
_noopen = gate.doctor("the focus wait cut", _runner,
                      r'state, ms, seen = wait_shade\(serial, "open",\n\s+SHADE_OPEN_S if '
                      r'before == "gone" else SHADE_STALL_S\)',
                      'state, ms, seen = "open", 0, ["assumed"]')
watched("a door that dumps before the shade has focus",
        {**REAL, "tools/android/run-emulator.py": _noopen}, "open and focusable after it expands")
_blind = gate.doctor("shade_state blind to NOT_FOCUSABLE", _runner,
                     r'return "unfocusable" if "NOT_FOCUSABLE" in flags\.group\(1\)\.split\(\) '
                     r'else "open"', 'return "open"')
watched("a shade reader that calls the unfocusable shade open",
        {**REAL, "tools/android/run-emulator.py": _blind}, "shade_state misread")
_reply = gate.doctor("the reply's door cut", _runner,
                     r'(def reply_notification[\s\S]*?)opened, said = open_shade\(serial, log\)',
                     r'\1opened, said = True, "assumed"')
watched("a reply that opens the shade without the door",
        {**REAL, "tools/android/run-emulator.py": _reply},
        "reply_notification does not open the shade through open_shade")

# 31-33. THE IDLE WAITS COUNTED AGAINST THE CEILING AGAIN.
_unnetted = gate.doctor("the idle seconds cut from validate-all's net",
                        REAL["tools/validate-all.py"],
                        r"net = secs - waited - idle\n", "net = secs - waited\n")
watched("a ceiling that charges the lane for the human's minutes",
        {**REAL, "tools/validate-all.py": _unnetted}, "does not subtract")
_unsaid = gate.doctor("the idle seconds cut from the net line", REAL["tools/validate-all.py"],
                      r"\{idle\}s waiting for an idle host; ", "")
watched("a net line that hides the idle seconds",
        {**REAL, "tools/validate-all.py": _unsaid}, "never prints the idle-host seconds")
_half = gate.doctor("idle_waited_seconds dropping the display seconds", _LANE_TEXT,
                    r'int\(m\.group\("secs"\)\) \+ int\(m\.group\("display"\)\)',
                    'int(m.group("secs"))')
_half_mod = gate.scratch() / "mac-idle-half.py"
_half_mod.write_text(_half, encoding="utf-8")
watched("an idle reader that misses the display waits", REAL,
        "idle_waited_seconds read 240s", lanes={**MODS, "mac": load_lane(_half_mod)})

gate.negatives_ran(38)

gate.counted("windows legs whose scene posts a notification",
             sorted(MODS["windows"].notification_legs(str(ROOT / "tools/scenes"))), floor=2)
gate.counted("tools/ scripts read for the idle wait's self-test door",
             sorted(TOOLS), floor=60)

for line in census(REAL):
    gate.finding(line)

gate.verdict("every lane asks the token at its funnel and holds it for its exclusive legs")
