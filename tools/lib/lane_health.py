"""What a reader of a slow lane needs, read at the lane's start and its end
(docs/traps.md, the windows lane slowed by a rebooted VM's Defender).

Every reading is split into a COMMAND and a pure PARSER, so each sentence
can be made to print from a doctored transcript (`selftest`, run by
tools/check-flightrec.py). A sentence prints only what its transcript
carried; a reading that failed says what came back instead.
"""

import base64
import datetime
import os
import pathlib
import re
import statistics
import subprocess
import threading
import time

PREFIX = "lane-health:"
LEG = re.compile(r"^(\S+): (?:PASS|FAIL)\b[^\n]*?\((\d+)s", re.M)
SHIFT = 0.25


def say(lane, when, sentence):
    print(f"{PREFIX} {lane} {when}: {sentence}", flush=True)


def _run(argv, *, timeout=30, stdin=None):
    try:
        got = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True,
                             encoding="utf-8", errors="replace",
                             timeout=timeout, check=False)
    except FileNotFoundError as error:
        return "", f"{argv[0]} is not on PATH ({error.strerror})"
    except subprocess.TimeoutExpired:
        return "", f"{argv[0]} did not answer within {timeout}s"
    if got.returncode != 0:
        tail = " ".join(got.stderr.split())[-200:]
        return got.stdout, f"{argv[0]} exited {got.returncode}: {tail or 'no stderr'}"
    return got.stdout, None


def duration(seconds):
    seconds = int(seconds)
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes, secs = divmod(rest, 60)
    if days:
        return f"{days}d{hours:02d}h{minutes:02d}m"
    if hours:
        return f"{hours}h{minutes:02d}m"
    if minutes:
        return f"{minutes}m{secs:02d}s"
    return f"{secs}s"


def clock_seconds(text):
    """ps's etime/time spellings: [dd-][hh:]mm:ss[.cc]."""
    days = 0
    if "-" in text:
        head, text = text.split("-", 1)
        days = int(head)
    parts = [float(p) for p in text.split(":")]
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return days * 86400 + secs


# ------------------------------------------------------------------ the host

def host_ps_text():
    return _run(["ps", "-Ao", "pid=,ppid=,etime=,time=,pcpu=,comm="])


def host_args_text():
    return _run(["ps", "-Ao", "pid=,command="])


def parse_ps(text):
    rows = []
    for line in text.splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        try:
            rows.append({"pid": int(parts[0]), "ppid": int(parts[1]),
                         "up": clock_seconds(parts[2]),
                         "cpu": clock_seconds(parts[3]),
                         "pcpu": float(parts[4]),
                         "name": pathlib.PurePosixPath(parts[5].strip()).name})
        except ValueError:
            continue
    return rows


def busiest(rows, n=4):
    hot = sorted((r for r in rows if r["pcpu"] > 0), key=lambda r: -r["pcpu"])[:n]
    return ", ".join(f"{r['name']} {share(r['pcpu'])}" for r in hot)


def share(pcpu):
    return f"{pcpu:.0f}%" if pcpu >= 1 else f"{pcpu:.1f}%"


def most_cpu(rows, n=4):
    top = sorted(rows, key=lambda r: -r["cpu"])[:n]
    return ", ".join(f"{r['name']} {duration(r['cpu'])}" for r in top if r["cpu"] > 0)


def host_boot_text():
    return _run(["sysctl", "-n", "kern.boottime"])


def host_sentence(ps_text, ps_problem, load, boot_text, boot_problem, now, cores):
    m = re.search(r"sec = (\d+)", boot_text or "")
    up = (f"up {duration(now - int(m.group(1)))}" if m and not boot_problem
          else f"uptime unreadable ({boot_problem or 'kern.boottime said ' + repr((boot_text or '').strip())})")
    head = (f"host {up}, load {load[0]:.1f} {load[1]:.1f} {load[2]:.1f} "
            f"(1, 5, 15 min) on {cores} cores")
    if ps_problem:
        return f"{head}; process table unreadable ({ps_problem})"
    rows = parse_ps(ps_text)
    if not rows:
        return f"{head}; ps listed no process it could parse"
    return (f"{head}; busiest now (ps's decaying share): "
            f"{busiest(rows) or 'nothing above 0%'}")


def thermal_sentence(text, problem):
    if problem:
        return f"thermal state unreadable ({problem})"
    said = [" ".join(line.split()).removeprefix("Note: ") for line in (text or "").splitlines()
            if line.strip()]
    if not said:
        return "thermal state unreadable (pmset -g therm printed nothing)"
    return "thermal (pmset -g therm): " + "; ".join(said)


MEMORY_SAMPLE_S = 1.0
UNITS = {"B": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}


def parse_vm_stat(text):
    m = re.search(r"page size of (\d+) bytes", text or "")
    if not m:
        return None
    counts = {k.strip().strip('"'): int(v) for k, v in
              re.findall(r'^([^:\n]+):\s+(\d+)\.?\s*$', text, re.M)}
    counts["page size"] = int(m.group(1))
    return counts


def gb(n):
    return f"{n / (1 << 30):.1f} GB"


def footprints(top_text, rows, n=5):
    names = {r["pid"]: r["name"] for r in rows}
    found = []
    for pid, size, unit in re.findall(r"^\s*(\d+)\s+([\d.]+)([BKMGT])[+-]?\s*$",
                                      top_text or "", re.M):
        found.append((float(size) * UNITS[unit], names.get(int(pid), f"pid {pid}")))
    found.sort(key=lambda f: -f[0])
    return ", ".join(f"{name} {gb(size)}" for size, name in found[:n])


def memory_sentence(vm_a, vm_b, vm_problem, interval, swap_text, swap_problem,
                    top_text, top_problem, rows):
    """The host's memory (docs/traps.md, the host out of memory under a matrix)."""
    said = []
    a, b = parse_vm_stat(vm_a), parse_vm_stat(vm_b)
    if vm_problem or not a or not b:
        said.append(f"vm_stat unreadable ({vm_problem or 'no page size in its output'})")
    else:
        page = b["page size"]
        said.append(f"{gb(b.get('Pages free', 0) * page)} free, compressor "
                    f"{gb(b.get('Pages stored in compressor', 0) * page)} held in "
                    f"{gb(b.get('Pages occupied by compressor', 0) * page)}")
        moved = {k: b.get(k, 0) - a.get(k, 0) for k in ("Pageins", "Compressions", "Swapouts")}
        said.append(f"over a {interval:.0f}s sample {moved['Pageins']} page-ins, "
                    f"{moved['Compressions']} compressions, {moved['Swapouts']} swap-outs")
    m = re.search(r"total = ([\d.]+)M\s+used = ([\d.]+)M", swap_text or "")
    if swap_problem or not m:
        said.append(f"swap unreadable ({swap_problem or 'vm.swapusage said ' + repr((swap_text or '').strip())})")
    else:
        said.append(f"swap {float(m.group(2)) / 1024:.1f} of {float(m.group(1)) / 1024:.1f} GB used")
    listed = None if top_problem else footprints(top_text, rows)
    said.append(f"largest footprints (top's mem): {listed}" if listed
                else f"footprints unreadable ({top_problem or 'top listed no pid and size'})")
    return "memory: " + "; ".join(said)


def memory_line(rows):
    vm_a, problem_a = _run(["vm_stat"])
    time.sleep(MEMORY_SAMPLE_S)
    vm_b, problem_b = _run(["vm_stat"])
    swap_text, swap_problem = _run(["sysctl", "-n", "vm.swapusage"])
    top_text, top_problem = _run(["top", "-l", "1", "-o", "mem", "-n", "8", "-stats", "pid,mem"])
    return memory_sentence(vm_a, vm_b, problem_a or problem_b, MEMORY_SAMPLE_S, swap_text,
                           swap_problem, top_text, top_problem, rows)


def host_line():
    t0 = time.monotonic()
    ps_text, ps_problem = host_ps_text()
    boot_text, boot_problem = host_boot_text()
    sentence = host_sentence(ps_text, ps_problem, os.getloadavg(), boot_text,
                             boot_problem, time.time(), os.cpu_count())
    sentence += "; " + thermal_sentence(*_run(["pmset", "-g", "therm"]))
    sentence += "; " + memory_line(parse_ps(ps_text))
    return sentence, int((time.monotonic() - t0) * 1000)


def top_consumers(n=4):
    text, problem = host_ps_text()
    return problem or busiest(parse_ps(text), n) or "nothing above 0%"


# ---------------------------------------------------------- iOS simulators

def ios_sentences(ps_text, args_text, udids):
    rows = parse_ps(ps_text)
    by_parent = {}
    for r in rows:
        by_parent.setdefault(r["ppid"], []).append(r)
    roots = {}
    for line in args_text.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and "launchd_sim" in parts[1]:
            for udid in udids:
                if f"/Devices/{udid}/" in parts[1]:
                    roots[udid] = int(parts[0])
    pid_rows = {r["pid"]: r for r in rows}
    out = []
    for udid in udids:
        root = roots.get(udid)
        if root is None or root not in pid_rows:
            out.append(f"simulator {udid}: no launchd_sim in the host's "
                       f"process table names it")
            continue
        tree, stack = [], [root]
        while stack:
            for child in by_parent.get(stack.pop(), []):
                tree.append(child)
                stack.append(child["pid"])
        out.append(
            f"simulator {udid}: up {duration(pid_rows[root]['up'])} (its "
            f"launchd_sim), {len(tree)} processes; busiest now: "
            f"{busiest(tree, 3) or 'nothing above 0%'}; most CPU since boot: "
            f"{most_cpu(tree, 3) or 'none recorded'}")
    return out


def ios_report(lane, when, udids):
    t0 = time.monotonic()
    host, _ = host_line()
    say(lane, when, host)
    ps_text, problem = host_ps_text()
    args_text, args_problem = host_args_text()
    if problem or args_problem:
        say(lane, when, f"simulators unreadable: {problem or args_problem}")
    else:
        for sentence in ios_sentences(ps_text, args_text, udids):
            say(lane, when, sentence)
    say(lane, when, f"the reading took {int((time.monotonic() - t0) * 1000)} ms")


# ------------------------------------------------------- Android emulators

ANDROID_SHELL = ("cat /proc/uptime; echo ==ps; ps -A -o TIME+,NAME -k -TIME+ "
                 "| head -5; echo ==top; top -b -d 1 -n 2 -q -o %CPU,NAME -s 1")


def android_sentence(serial, text, problem):
    if problem and not text.strip():
        return f"emulator {serial}: reading failed: {problem}"
    head, _, rest = text.partition("==ps")
    ps_part, _, top_part = rest.partition("==top")
    m = re.match(r"\s*([\d.]+)\s", head)
    up = f"up {duration(float(m.group(1)))}" if m else (
        f"uptime unreadable (/proc/uptime said {head.strip()[:60]!r})")
    since = []
    for line in ps_part.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and re.match(r"^[\d:.-]+$", parts[0]):
            since.append(f"{parts[1].strip()} {duration(clock_seconds(parts[0]))}")
    frames = [f for f in re.split(r"\n\s*\n", top_part.strip("\n")) if f.strip()]
    hot = []
    for line in (frames[-1].splitlines() if len(frames) >= 2 else []):
        parts = line.split(None, 1)
        try:
            share = float(parts[0])
        except (ValueError, IndexError):
            continue
        if share > 0 and len(parts) == 2:
            hot.append(f"{parts[1].strip()} {share:.0f}%")
    sample = (", ".join(hot[:3]) or "nothing above 0%") if len(frames) >= 2 else (
        f"no second top frame came back ({len(frames)} frame(s))")
    return (f"emulator {serial}: {up}; busiest over a 1s sample: {sample}; "
            f"most CPU since boot: {', '.join(since[:3]) or 'ps listed none'}")


def android_report(lane, when, serials):
    t0 = time.monotonic()
    host, _ = host_line()
    say(lane, when, host)
    got = {}

    def read(serial):
        got[serial] = _run(["adb", "-s", serial, "shell", ANDROID_SHELL], timeout=20)

    threads = [threading.Thread(target=read, args=(s,)) for s in serials]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for serial in serials:
        text, problem = got.get(serial, ("", "never read"))
        say(lane, when, android_sentence(serial, text, problem))
    say(lane, when, f"the reading took {int((time.monotonic() - t0) * 1000)} ms")


# ------------------------------------------------------ the linux docker VM

LINUX_SHELL = ("cat /proc/uptime /proc/loadavg; nproc; echo ==ps; "
               "ps -eo time=,comm= --sort=-time | head -5")


def linux_sentence(text, problem):
    if problem and not text.strip():
        return f"docker VM reading failed: {problem}"
    head, _, ps_part = text.partition("==ps")
    lines = head.split("\n")
    up = re.match(r"\s*([\d.]+)\s", lines[0] + " ") if lines else None
    load = re.match(r"\s*([\d.]+) ([\d.]+) ([\d.]+)", lines[1]) if len(lines) > 1 else None
    cores = lines[2].strip() if len(lines) > 2 else "?"
    since = []
    for line in ps_part.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and re.match(r"^[\d:-]+$", parts[0]) and clock_seconds(parts[0]):
            since.append(f"{parts[1].strip()} {duration(clock_seconds(parts[0]))}")
    return ("docker VM " + (f"up {duration(float(up.group(1)))}" if up else
                            "uptime unreadable")
            + (f", load {load.group(1)} {load.group(2)} {load.group(3)} on "
               f"{cores} cores" if load else ", load unreadable")
            + f"; most CPU since boot: {', '.join(since[:4]) or 'ps listed none'}")


# Docker Desktop's own record of its VM (docs/traps.md, the linux lane's
# "docker VM up 4s"): Resource Saver stops the VM after five idle minutes and
# the next docker call starts it, so a short uptime is that, a crash or an
# OOM kill, and only this log says which.
DOCKER_LOG = pathlib.Path.home() / "Library/Containers/com.docker.docker/Data/log/host/com.docker.backend.log"
DOCKER_EVENT = re.compile(
    r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)[.\d]*Z\]\[com\.docker\.backend[.\w]*\] "
    r"(?:(stopping VM|starting VM)\b|idle -> busy \(was idle for (\S+?);|.*S->C.*(oom-kills)\b)",
    re.M)
_LINUX_START = {}


def docker_events(text):
    """[(utc stamp, 'stop'|'start'|'woke after <idle>'|'oom kill')] from the backend log."""
    out = []
    for m in DOCKER_EVENT.finditer(text):
        stamp = m.group(1)
        if m.group(2):
            out.append((stamp, "stop" if m.group(2) == "stopping VM" else "start"))
        elif m.group(3):
            out.append((stamp, f"woke after {m.group(3)}"))
        elif m.group(4):
            out.append((stamp, "oom kill"))
    return out


def docker_sentence(events, problem, since=None):
    if problem:
        return f"Docker Desktop's VM record unreadable: {problem}"
    if since is None:
        starts = [i for i, (_, kind) in enumerate(events) if kind == "start"]
        if not starts:
            return "Docker Desktop's VM record: no VM start in its backend log"
        i = starts[-1]
        stamp = events[i][0]
        woke = [k for s, k in events[max(0, i - 1):i + 2] if k.startswith("woke after")]
        stops = [s for s, k in events[:i] if k == "stop"]
        why = (f"Resource Saver had stopped it at {stops[-1]}Z and a docker call woke it "
               f"({woke[-1]})" if stops and woke else
               f"the previous stop is {'at ' + stops[-1] + 'Z' if stops else 'not in the log'}, "
               f"and no idle wake was logged beside the start")
        return f"Docker Desktop's VM last started at {stamp}Z: {why}"
    during = [(s, k) for s, k in events if s >= since and k in ("stop", "start", "oom kill")]
    if not during:
        return f"Docker Desktop's VM since {since}Z: no stop, start or OOM kill"
    return (f"Docker Desktop's VM since {since}Z: "
            + ", ".join(f"{k} at {s}Z" for s, k in during)
            + " — the VM moved under this lane")


def linux_report(lane, when, image):
    t0 = time.monotonic()
    host, _ = host_line()
    say(lane, when, host)
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    text, problem = _run(["docker", "run", "--rm", "--pid=host", image, "sh",
                          "-c", LINUX_SHELL], timeout=60)
    say(lane, when, linux_sentence(text, problem))
    try:
        log = DOCKER_LOG.read_text(encoding="utf-8", errors="replace")
        log_problem = None
    except OSError as error:
        log, log_problem = "", f"{DOCKER_LOG}: {error.strerror}"
    since = _LINUX_START.get(lane) if when == "end" else None
    say(lane, when, docker_sentence(docker_events(log), log_problem, since))
    if when == "start":
        _LINUX_START[lane] = now
    say(lane, when, f"the reading took {int((time.monotonic() - t0) * 1000)} ms")


def mac_report(lane, when):
    host, ms = host_line()
    say(lane, when, host)
    say(lane, when, f"the reading took {ms} ms")
    t0 = time.monotonic()
    if when == "start":
        MAC_APPS.root = pathlib.Path(__file__).resolve().parents[2]
        say(lane, when, MAC_APPS.start())
    else:
        for sentence in MAC_APPS.end():
            say(lane, when, sentence)
    say(lane, when, f"the app reading took {int((time.monotonic() - t0) * 1000)} ms")


# ------------------------------------------- applications that appear on the host

# docs/traps.md, the Preview a Go guest's checkin relaunched: an app no lane
# code launches came up mid-lane and nothing recorded it.
APP_TYPES = ("Foreground", "UIElement")
APP_HEAD = re.compile(r'^\s*\d+\) "(.*)" (ASN:\S+?):?\s*$')
# (label, how the executable is matched, the lane file that launches it, the
# text there that launches it). check-flightrec holds each text to its file.
LANE_APPS = (
    ("a binary built in the tree", "under-root", "",
     "tools/lib/lanes/mac.py", "def leg_argv(scene, lang, hs_bin):"),
    ("python3", "name", r"[Pp]ython(?:3(?:\.\d+)?)?",
     "tools/lib/lanes/mac.py", 'return ["python3", f"guests/python/{stem}.py"]'),
    ("node", "name", r"node",
     "tools/lib/lanes/mac.py", 'return ["node", f"guests/js/{stem}.ts"]'),
    ("dotnet", "name", r"dotnet",
     "tools/lib/lanes/mac.py", 'return ["dotnet", "exec", CS_GUEST]'),
    ("java", "name", r"java",
     "tools/lib/lanes/mac.py", 'return ["java", "-XstartOnFirstThread", "-cp",'),
)
# Host agents macOS itself relaunches through every lane, named so the record
# stays readable (docs/traps.md, Accessibility Services every minute).
HOST_AGENTS = (
    ("Accessibility Services", "com.apple.accessibility.AXVisualSupportAgent",
     "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/"
     "AXVisualSupportAgent.app/Contents/MacOS/AXVisualSupportAgent",
     "launchd respawns it for a pending mach message each time it quits after 60s, "
     "with or without a lane running"),
)
LANE_BUNDLE = re.compile(r"dev\.kaya(?:\.|$)")
BUNDLE_ID = re.compile(r"^[A-Za-z0-9_.\-]+$")
LOG_LINE = re.compile(r"^\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d\.\d+) \S+ +(.+?)\[(\d+):[0-9a-f]+\] "
                      r"(?:\[[^\]]*\] )?(.*)$")


def apps_text():
    return _run(["lsappinfo", "list"], timeout=10)


def _local_epoch(text):
    try:
        return time.mktime(time.strptime(text, "%Y/%m/%d %H:%M:%S"))
    except ValueError:
        return None


def parse_apps(text):
    """lsappinfo list's records: name, asn, bundle, exe, pid, type, parent,
    when (launch time, else checkin time) and its spelling."""
    apps, cur = [], None
    for line in text.splitlines():
        m = APP_HEAD.match(line)
        if m:
            cur = {"name": m.group(1), "asn": m.group(2).rstrip(":"), "bundle": None,
                   "exe": "", "pid": None, "type": "", "parent": "",
                   "when": None, "stamp": "", "checkin": None, "checkin_stamp": ""}
            apps.append(cur)
            continue
        if cur is None:
            continue
        s = line.strip()
        if s.startswith("bundleID="):
            b = re.match(r'bundleID="(.*)"', s)
            cur["bundle"] = b.group(1) if b else None
        elif s.startswith("executable path="):
            cur["exe"] = s[len('executable path="'):-1] if s.endswith('"') else ""
        elif s.startswith("pid = "):
            p = re.match(r"pid = (\d+)", s)
            t = re.search(r'type="(\w+)"', s)
            cur["pid"] = int(p.group(1)) if p else None
            cur["type"] = t.group(1) if t else ""
        elif s.startswith("parentASN="):
            p = re.match(r'parentASN="(.*?)" (ASN:\S+?):?\s*(\(inferred\))?$', s)
            if p:
                cur["parent"] = p.group(1) + (" (inferred)" if p.group(3) else "")
        elif s.startswith(("launch time =", "checkin time =")):
            w = re.search(r"(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d)", s)
            if w and (s.startswith("launch") or cur["when"] is None):
                cur["when"], cur["stamp"] = _local_epoch(w.group(1)), w.group(1)
            if w and s.startswith("checkin"):
                cur["checkin"], cur["checkin_stamp"] = _local_epoch(w.group(1)), w.group(1)
    return [a for a in apps if a["pid"] is not None]


def lane_owner(app, root):
    """The LANE_APPS label owning this executable, or None."""
    exe = app["exe"]
    for label, how, pattern, _rel, _needle in LANE_APPS:
        if how == "under-root":
            if root and exe.startswith(str(root).rstrip("/") + "/"):
                return label
        elif re.fullmatch(pattern, pathlib.PurePosixPath(exe).name):
            return label
    return None


def host_agent(app):
    """The HOST_AGENTS label for this record, by bundle id and executable both."""
    for label, bundle, exe, _why in HOST_AGENTS:
        if app["bundle"] == bundle and app["exe"] == exe:
            return label
    return None


def legs_at(legs, t):
    """Legs whose [began, ended] holds the whole second t (lsappinfo's
    resolution); a leg still running has ended None."""
    return [name for name, began, ended in legs
            if began < t + 1 and (ended is None or ended >= t)]


def requester_predicate(bundle):
    return (f'(process == "runningboardd" AND eventMessage CONTAINS "LS launch {bundle}") '
            f'OR (process == "talagentd" AND eventMessage CONTAINS "{bundle}") '
            f'OR (process == "launchservicesd" AND eventMessage CONTAINS "CHECKIN:" '
            f'AND eventMessage CONTAINS "{bundle}") '
            f'OR (process == "WindowServer" AND eventMessage CONTAINS "STUB process") '
            f'OR eventMessage BEGINSWITH "CHECKIN: pid="')


REQUESTER_BEFORE, REQUESTER_AFTER = 5, 2


def requester_log(bundle, t):
    span = [time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(x))
            for x in (t - REQUESTER_BEFORE, t + REQUESTER_AFTER)]
    return _run(["/usr/bin/log", "show", "--style", "compact", "--start", span[0],
                 "--end", span[1], "--predicate", requester_predicate(bundle)], timeout=60)


def requester_clauses(text, bundle, name, pid):
    """What the unified log says asked for this app, one clause per line read."""
    names, out = {}, []
    rows = [m.groups() for m in map(LOG_LINE.match, text.splitlines()) if m]
    for _at, proc, ppid, _msg in rows:
        names.setdefault(ppid, proc)
    for at, proc, _ppid, msg in rows:
        if proc == "runningboardd":
            m = re.search(r'from originator \[(.+?)\] with description '
                          r'<RBSAssertionDescriptor\| "LS launch ' + re.escape(bundle) + '"', msg)
            if m:
                out.append(f"LaunchServices launched it at {at} for {m.group(1)}")
        elif proc == "talagentd" and bundle in msg:
            out.append(f"talagentd at {at}: {msg.lstrip('- ').strip()}")
        elif proc == "launchservicesd":
            m = re.search(r"CHECKIN:(\S+) (\d+) " + re.escape(bundle) + r"\b", msg)
            if m and int(m.group(2)) != pid:
                who = names.get(m.group(2), "a process the log names nowhere else")
                out.append(f"pid {m.group(2)} ({who}) checked in under {bundle}'s ASN "
                           f"{m.group(1)} at {at}")
        elif proc == "WindowServer":
            m = re.search(r"STUB process (\S+) \((.+?)\) is migrating to real process.*?"
                          r"updating pid 0 -> (\d+)", msg)
            if m and (m.group(2) == name or int(m.group(3)) == pid):
                who = names.get(m.group(3), "a process the log names nowhere else")
                out.append(f"WindowServer moved {m.group(2)}'s stub {m.group(1)} to pid "
                           f"{m.group(3)} ({who}) at {at}")
    return out


def requester_sentence(app, text, problem):
    bundle = app["bundle"]
    if not bundle:
        return "no bundle id, so the log was not asked for a requester"
    if not BUNDLE_ID.match(bundle):
        return f"bundle id {bundle!r} cannot be spelled in a log predicate; the log was not asked"
    if problem:
        return f"the unified log could not be read ({problem})"
    found = requester_clauses(text, bundle, app["name"], app["pid"])
    if not found:
        return (f"the unified log names no requester (runningboardd's LS launch, talagentd, "
                f"launchservicesd's checkins and WindowServer's stub moves, read "
                f"{REQUESTER_BEFORE}s before to {REQUESTER_AFTER}s after the launch)")
    return "the log: " + "; ".join(found)


def window_sentence(pid, text, problem):
    if problem:
        return f"its windows unreadable ({problem})"
    own = [m for m in (re.match(r"win=\d+ pid=(\d+) layer=(-?\d+) bounds=(\S+) app=\".*\" "
                                r"title=(.*)$", ln) for ln in text.splitlines())
           if m and int(m.group(1)) == pid]
    if not own:
        tail = [ln for ln in text.splitlines() if ln.startswith("flightrec-winlist:")]
        return (f"no window of its own on screen when first seen "
                f"({tail[-1] if tail else 'the window list printed no count'})")
    shown = ", ".join(f"layer {m.group(2)} {m.group(4)} at {m.group(3)}" for m in own[:4])
    return f"{len(own)} window(s) of its own on screen when first seen: {shown}"


def parent_sentence(pid, text, problem):
    if problem:
        return f"its parent process unreadable ({problem})"
    rows = {r["pid"]: r for r in parse_ps(text)}
    me = rows.get(pid)
    if me is None:
        return "gone before its parent process could be read"
    up = rows.get(me["ppid"])
    return f"parent process {up['name'] if up else 'unlisted'} (pid {me['ppid']})"


def _windows(pid, root):
    import flightrec_lane
    binp = flightrec_lane.winlist_bin(root)
    if not binp:
        return "", "tools/mac/flightrec-winlist.swift would not build"
    return _run([binp, str(pid)], timeout=20)


class MacApps:
    """The GUI applications that appear on the mac host while the lane runs.

    Read at the lane's start, after every leg and at its end; every reader
    is an argument so selftest drives each sentence from doctored text."""

    def __init__(self, read=apps_text, log=requester_log, windows=_windows,
                 ps=host_ps_text, clock=time.time):
        self.read, self.log, self.windows, self.ps, self.clock = read, log, windows, ps, clock
        self.root = None
        self.lock = threading.Lock()
        self.base = None
        self.base_problem = ""
        self.began = None
        self.legs = []
        self.seen = {}
        self.excluded = {}
        self.host_excluded = {}
        self.exe_at_start = {}
        self.adopted = {}
        self.readings = 0
        self.failed = []

    def start(self):
        self.began = self.clock()
        text, problem = self.read()
        self.readings = 1
        if problem:
            self.base_problem = problem
            return f"app list unreadable at the lane's start ({problem}); no app can be called new"
        every = parse_apps(text)
        self.exe_at_start = {a["pid"]: a["exe"] for a in every}
        apps = [a for a in every if a["type"] in APP_TYPES]
        self.base = {a["pid"] for a in apps}
        return f"{len(apps)} GUI applications running at the lane's start (lsappinfo)"

    def leg_began(self, name):
        entry = [name, self.clock(), None]
        with self.lock:
            self.legs.append(entry)
        return entry

    def leg_ended(self, entry):
        entry[2] = self.clock()
        self.sample(f"after {entry[0]}")

    def sample(self, where):
        if self.base is None:
            return set()
        text, problem = self.read()
        with self.lock:
            self.readings += 1
            if problem:
                self.failed.append(f"{where}: {problem}")
                return set()
        now = set()
        for app in parse_apps(text):
            self.adoption(app, where)
            if app["type"] not in APP_TYPES:
                continue
            now.add(app["pid"])
            if app["pid"] in self.base or (app["when"] is not None
                                           and app["when"] < self.began - 1):
                continue
            with self.lock:
                if (app["pid"] in self.seen or app["pid"] in self.excluded
                        or app["pid"] in self.host_excluded):
                    continue
            owner = lane_owner(app, self.root)
            agent = host_agent(app)
            if agent and not owner:
                with self.lock:
                    self.host_excluded[app["pid"]] = agent
                continue
            if owner and (not app["bundle"] or LANE_BUNDLE.match(app["bundle"])):
                with self.lock:
                    self.excluded[app["pid"]] = owner
                continue
            first = {"app": app, "owner": owner, "where": where}
            first["windows"] = window_sentence(app["pid"], *self.windows(app["pid"], self.root))
            first["parent"] = parent_sentence(app["pid"], *self.ps())
            with self.lock:
                self.seen.setdefault(app["pid"], first)
        return now

    def adoption(self, app, where):
        """docs/traps.md, the Preview a Go guest's checkin relaunched: a lane
        binary registered under another app's bundle id took that app's record."""
        owner = lane_owner(app, self.root)
        bundle = app["bundle"]
        if (not owner or not bundle or LANE_BUNDLE.match(bundle)
                or self.exe_at_start.get(app["pid"]) == app["exe"]):
            return
        t = app["checkin"]
        if t is None:
            when = "at a checkin time lsappinfo did not give"
        else:
            running = legs_at(self.legs, t)
            when = (f"checked in {app['checkin_stamp']} while "
                    + (f"{', '.join(running)} ran" if running
                       else "no leg of this lane was running"))
        with self.lock:
            self.adopted.setdefault(app["pid"], (
                f"IDENTITY ADOPTED: pid {app['pid']} ({app['exe']}, the lane's own: {owner}) "
                f"is registered with LaunchServices as {app['name']} ({bundle}, {app['asn']}, "
                f"{app['type'] or 'no type'}), {when}; first seen {where}. A kaya process "
                f"checks in under its own identity or respawns off a pid that holds another "
                f"app's record (crates/kaya/src/ls_identity.rs), and this one did neither"))

    def refusals(self):
        with self.lock:
            return [self.adopted[pid] for pid in sorted(self.adopted)]

    def end(self):
        if self.base is None:
            return [f"app list unreadable at the lane's start ({self.base_problem}); "
                    f"no app appearing during the lane can be named"]
        alive = self.sample("at the lane's end")
        out = []
        for pid, first in sorted(self.seen.items()):
            out.append(self.sentence(first, pid in alive))
        counts = {}
        for label in self.excluded.values():
            counts[label] = counts.get(label, 0) + 1
        kept = (", ".join(f"{k} {v}" for k, v in sorted(counts.items()))
                if counts else "none")
        agents = {}
        for label in self.host_excluded.values():
            agents[label] = agents.get(label, 0) + 1
        hosted = (", ".join(f"{k} {v}" for k, v in sorted(agents.items()))
                  if agents else "none")
        head = (f"{len(self.seen)} GUI application(s) appeared during the lane"
                if self.seen else "no GUI application appeared during the lane")
        tail = ""
        if self.failed:
            tail = (f"; the app list was unreadable at {len(self.failed)} of them "
                    f"(first: {self.failed[0]})")
        out.append(f"{head} ({self.readings} readings across {len(self.legs)} legs; the "
                   f"lane's own apps excluded by name: {kept}; host agents excluded by name: "
                   f"{hosted}){tail}")
        return out + self.refusals()

    def sentence(self, first, alive):
        app = first["app"]
        t = app["when"]
        if t is None:
            when, during = "at a time lsappinfo did not give,", "so the legs running then are unknown"
        else:
            running = legs_at(self.legs, t)
            when = f"launched {app['stamp']}"
            during = (f"while {', '.join(running)} ran" if running
                      else "while no leg of this lane was running")
        owner = (f"; its executable is the lane's own ({first['owner']}) but it checked "
                 f"in as {app['bundle']}" if first["owner"] else "")
        parent = (f"lsappinfo's parent {app['parent']}" if app["parent"]
                  else "lsappinfo names no parent")
        if t is None:
            asked = "the log was not asked: no launch time"
        else:
            asked = requester_sentence(app, *(self.log(app["bundle"], t)
                                              if app["bundle"] and BUNDLE_ID.match(app["bundle"])
                                              else ("", None)))
        state = "still running at the lane's end" if alive else "gone by the lane's end"
        return (f"APP APPEARED: {app['name']} ({app['bundle'] or 'no bundle id'}, pid "
                f"{app['pid']}, {app['type']}, {app['exe']}) {when} {during}{owner}; "
                f"first seen {first['where']}; {parent}; {first['parent']}; {asked}; "
                f"{first['windows']}; {state}")


MAC_APPS = MacApps()


# --------------------------------------------------------- the windows guest

# docs/traps.md, the stale .NET Framework native images: a .NET update leaves
# PowerShell's own assemblies StatusPending and every start JIT-compiles them.
NGEN_FRAMEWORKS = ("FrameworkArm64", "Framework64", "Framework")
NGEN_EXE = "C:\\Windows\\Microsoft.NET\\{}\\v4.0.30319\\ngen.exe"
NGEN_READ = (r"""try{foreach($f in @(""" + ",".join(f"'{f}'" for f in NGEN_FRAMEWORKS)
             + r""")){$e="$env:windir\Microsoft.NET\$f\v4.0.30319\ngen.exe";if(Test-Path $e){$o=& $e display;"ngen="+$f+"|"+$LASTEXITCODE+"|"+@($o|Select-String -SimpleMatch 'StatusPending').Count}else{"ngen="+$f+"|absent|0"}}}catch{"ngen.error="+($_.Exception.Message -replace '\s+',' ')}
""")
PS_START = r"""try{$q=New-Object Diagnostics.ProcessStartInfo 'powershell.exe','-NoProfile -Command exit';$q.UseShellExecute=$false;$q.CreateNoWindow=$true;$s=[Diagnostics.Stopwatch]::StartNew();$p=[Diagnostics.Process]::Start($q);$p.WaitForExit();"pscpu="+(N $p.TotalProcessorTime.TotalMilliseconds)+"|"+$s.ElapsedMilliseconds}catch{"pscpu.error="+($_.Exception.Message -replace '\s+',' ')}
"""
PS_SLOW_MS = 900

WINDOWS_SCRIPT = r"""$ErrorActionPreference='Stop';$w=[Diagnostics.Stopwatch]::StartNew()
$I=[Globalization.CultureInfo]::InvariantCulture
function T($d){if($d){$d.ToUniversalTime().ToString('o')}else{''}}
function N($x){([double]$x).ToString('0.##',$I)}
try{"boot="+(T (Get-CimInstance Win32_OperatingSystem).LastBootUpTime)}catch{"boot.error="+($_.Exception.Message -replace '\s+',' ')}
"now="+(T (Get-Date));"cores="+[Environment]::ProcessorCount
$a=@{};foreach($p in Get-Process){if($p.CPU -ne $null){$a[$p.Id]=$p.CPU}}
$s=[Diagnostics.Stopwatch]::StartNew();Start-Sleep -Milliseconds 2000;"sample="+(N $s.Elapsed.TotalSeconds)
foreach($p in Get-Process){if($p.CPU -ne $null){$d=0;if($a.ContainsKey($p.Id)){$d=$p.CPU-$a[$p.Id]};"cpu="+$p.ProcessName+"|"+(N $p.CPU)+"|"+(N $d)}else{"cpuhidden="+$p.ProcessName}}
try{$m=Get-MpComputerStatus;"mp.rtp="+$m.RealTimeProtectionEnabled;"mp.mode="+$m.AMRunningMode;"mp.qs="+(T $m.QuickScanStartTime);"mp.qe="+(T $m.QuickScanEndTime);"mp.fs="+(T $m.FullScanStartTime);"mp.fe="+(T $m.FullScanEndTime)}catch{"mp.error="+($_.Exception.Message -replace '\s+',' ')}
try{$f=Get-MpPreference;foreach($x in $f.ExclusionPath){"mp.xpath="+$x};foreach($x in $f.ExclusionProcess){"mp.xproc="+$x}}catch{"mp.preferror="+($_.Exception.Message -replace '\s+',' ')}
foreach($r in @(RUNTIMES)){$n,$q=$r;if(-not $q){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){$q=$c.Source}}elseif(-not(Test-Path $q)){$q='missing:'+$q};"rt="+$n+"|"+$q}
""" + PS_START + NGEN_READ + r"""
"took="+$w.ElapsedMilliseconds
"""


def windows_script(runtimes):
    """`runtimes` is (name, path-or-empty); an empty path is resolved on the
    guest's PATH the way a launcher's bare `python` is."""
    spelled = ",".join(f"@('{n}','{p}')" for n, p in runtimes)
    return WINDOWS_SCRIPT.replace("RUNTIMES", spelled)


def windows_command(runtimes):
    encoded = base64.b64encode(windows_script(runtimes).encode("utf-16-le")).decode()
    return f"powershell -NoProfile -NonInteractive -EncodedCommand {encoded}"


def _iso(text):
    text = re.sub(r"(\.\d{6})\d+", r"\1", text.strip())
    try:
        return datetime.datetime.fromisoformat(text)
    except ValueError:
        return None


def windows_sentences(text, problem):
    keys = {}
    multi = {"cpu": [], "cpuhidden": [], "mp.xpath": [], "mp.xproc": [], "rt": [], "ngen": []}
    for line in text.splitlines():
        key, eq, value = line.partition("=")
        if not eq:
            continue
        key = key.strip()
        if key in multi:
            multi[key].append(value.strip())
        else:
            keys[key] = value.strip()
    if not keys and not any(multi.values()):
        return [f"guest reading failed: {problem or 'the guest printed nothing'}"]
    out = []
    now = _iso(keys.get("now", ""))
    boot = _iso(keys.get("boot", ""))
    if "boot.error" in keys:
        out.append(f"guest boot time unreadable: {keys['boot.error']}")
    elif boot and now:
        out.append(f"guest booted {boot:%Y-%m-%d %H:%M}Z, up {duration((now - boot).total_seconds())}")
    else:
        out.append(f"guest boot time unreadable: boot={keys.get('boot', '')!r} now={keys.get('now', '')!r}")

    procs = []
    for row in multi["cpu"]:
        parts = row.split("|")
        if len(parts) != 3:
            continue
        try:
            procs.append((parts[0], float(parts[1]), float(parts[2])))
        except ValueError:
            continue
    try:
        sample = float(keys.get("sample", "0"))
    except ValueError:
        sample = 0.0
    totals = {}
    for name, total, delta in procs:
        t = totals.setdefault(name, [0.0, 0.0])
        t[0] += total
        t[1] += delta
    hot = sorted(((n, d) for n, (_, d) in totals.items() if d > 0.01), key=lambda x: -x[1])[:5]
    if sample <= 0:
        out.append(f"guest CPU sample unreadable (sample={keys.get('sample', '')!r})")
    else:
        out.append(f"guest busiest over a {sample:.1f}s sample ({keys.get('cores', '?')} cores): "
                   + (", ".join(f"{n} {d / sample * 100:.0f}% of a core" for n, d in hot)
                      or "no process used CPU"))
    top = sorted(totals.items(), key=lambda x: -x[1][0])[:5]
    out.append("guest CPU since boot: "
               + (", ".join(f"{n} {t[0]:.0f}s" for n, t in top) or "no process reported any"))
    if multi["cpuhidden"]:
        hidden = sorted(set(multi["cpuhidden"]) - {""})
        out.append(f"guest: {len(multi['cpuhidden'])} processes' CPU unreadable to this "
                   f"session ({', '.join(hidden[:6])}{', ...' if len(hidden) > 6 else ''})")

    if "mp.error" in keys:
        out.append(f"Defender status unreadable: {keys['mp.error']}")
    else:
        scans = []
        for kind, s_key, e_key in (("quick", "mp.qs", "mp.qe"), ("full", "mp.fs", "mp.fe")):
            start, end = _iso(keys.get(s_key, "")), _iso(keys.get(e_key, ""))
            if start is None:
                scans.append(f"no {kind} scan recorded")
            elif end is None or start > end:
                scans.append(f"a {kind} scan started {start:%Y-%m-%d %H:%M}Z and has "
                              f"recorded no end since (running, or stopped without one)")
            else:
                ago = f", {duration((now - end).total_seconds())} before this reading" if now else ""
                scans.append(f"last {kind} scan {start:%Y-%m-%d %H:%M}Z to {end:%H:%M}Z{ago}")
        out.append(f"Defender real-time protection {keys.get('mp.rtp', '?')}, mode "
                   f"{keys.get('mp.mode', '?')}; " + "; ".join(scans))

    if "mp.preferror" in keys:
        out.append(f"Defender exclusions unreadable: {keys['mp.preferror']}")
    elif any(x.startswith("N/A") for x in multi["mp.xpath"] + multi["mp.xproc"]):
        said = next(x for x in multi["mp.xpath"] + multi["mp.xproc"] if x.startswith("N/A"))
        out.append(f"Defender exclusions unreadable to this session: {said}")
    else:
        paths = [x.rstrip("\\").lower() for x in multi["mp.xpath"] if x]
        procs_x = {x.lower() for x in multi["mp.xproc"] if x}
        verdicts = []
        for row in multi["rt"]:
            name, _, where = row.partition("|")
            if not where:
                verdicts.append(f"{name} not found on the guest's PATH")
                continue
            if where.startswith("missing:"):
                verdicts.append(f"{name} absent at {where[len('missing:'):]}")
                continue
            low = where.lower()
            cover = next((p for p in paths if low == p or low.startswith(p + "\\")), None)
            if cover:
                verdicts.append(f"{name} excluded ({where} under {cover})")
            elif low in procs_x or low.rsplit("\\", 1)[-1] in procs_x:
                verdicts.append(f"{name} excluded as a process ({where})")
            else:
                verdicts.append(f"{name} SCANNED ({where}; no exclusion covers it)")
        out.append("real-time scanning: " + ("; ".join(verdicts) or "no runtime was named"))
    out.append(powershell_sentence(keys))
    out.append("native-image queues: " + ngen_summary(ngen_rows(multi["ngen"]),
                                                      keys.get("ngen.error")))
    if "took" in keys:
        out.append(f"the guest's reading took {keys['took']} ms (2 s of it the CPU sample)")
    return out


def powershell_sentence(keys):
    if "pscpu.error" in keys:
        return f"guest PowerShell start unreadable: {keys['pscpu.error']}"
    cpu, _, wall = keys.get("pscpu", "").partition("|")
    try:
        cpu_ms, wall_ms = float(cpu), int(wall)
    except ValueError:
        return f"guest PowerShell start unreadable (pscpu={keys.get('pscpu', '')!r})"
    slow = f"SLOW, past {PS_SLOW_MS} ms: " if cpu_ms > PS_SLOW_MS else ""
    return (f"guest PowerShell start (-NoProfile -Command exit): {slow}{cpu_ms:.0f} ms of CPU, "
            f"{wall_ms} ms wall (300-480 ms of CPU measured with current native images, "
            f"1400-1900 ms with stale ones; docs/traps.md, the stale .NET native images)")


def ngen_rows(values):
    """`ngen=<framework>|<display's exit or absent>|<StatusPending lines>`."""
    rows = []
    for value in values:
        parts = value.split("|")
        if len(parts) == 3:
            rows.append(tuple(p.strip() for p in parts))
    return rows


def ngen_pending(rows):
    """{framework: pending} over the frameworks whose reading counted."""
    return {f: int(c) for f, rc, c in rows if rc == "0" and c.isdigit()}


def ngen_unreadable(rows):
    return [f"{f} (ngen display exited {rc}, counted {c!r})" for f, rc, c in rows
            if rc != "absent" and not (rc == "0" and c.isdigit())]


def ngen_summary(rows, error):
    if error:
        return f"unreadable: {error}"
    if not rows:
        return "the guest printed no ngen reading"
    parts = []
    for f, rc, c in rows:
        if rc == "absent":
            parts.append(f"{f} has no ngen.exe")
        elif f in ngen_pending(rows):
            parts.append(f"{f} {c} {'PENDING' if c != '0' else 'pending'}")
        else:
            parts.append(f"{f} unreadable (ngen display exited {rc}, counted {c!r})")
    return ", ".join(parts)


def ngen_command():
    script = r"""$ErrorActionPreference='Stop'
""" + NGEN_READ
    encoded = base64.b64encode(script.encode("utf-16-le")).decode()
    return f"powershell -NoProfile -NonInteractive -EncodedCommand {encoded}"


def ngen_drain_command(framework):
    return f"{NGEN_EXE.format(framework)} executeQueuedItems"


def _ngen_refusal(what):
    cmds = "; ".join(f"`{ngen_drain_command(f)}`" for f in NGEN_FRAMEWORKS)
    return (f"deploy-win: {what}. Every PowerShell start JIT-compiles an assembly whose "
            f"native image is StatusPending (1400-1900 ms of CPU against 300-480 ms measured), "
            f"and every leg starts one. On the VM, as administrator, run {cmds}, then "
            f"`{NGEN_EXE.format(NGEN_FRAMEWORKS[0])} display` should list nothing "
            f"StatusPending (docs/traps.md, the stale .NET native images).")


def ngen_plan(text, problem, after=""):
    """(frameworks to drain as (name, pending), sentence, refusal)."""
    keys, values = {}, []
    for line in text.splitlines():
        key, eq, value = line.partition("=")
        if eq and key.strip() == "ngen":
            values.append(value.strip())
        elif eq:
            keys[key.strip()] = value.strip()
    rows = ngen_rows(values)
    if problem or "ngen.error" in keys or not rows:
        why = problem or keys.get("ngen.error") or "the guest printed no ngen reading"
        return [], None, _ngen_refusal(f"the guest's .NET native-image queues could not "
                                       f"be read{after} ({why})")
    bad = ngen_unreadable(rows)
    if bad:
        return [], None, _ngen_refusal("the native-image queue could not be counted for "
                                       + ", ".join(bad))
    pending = ngen_pending(rows)
    if not pending:
        return [], None, _ngen_refusal("no framework on the guest has an ngen.exe ("
                                       + ngen_summary(rows, None) + ")")
    todo = [(f, n) for f, n in pending.items() if n]
    total = sum(n for _, n in todo)
    if not todo:
        return [], f"deploy-win: .NET native images: nothing pending ({ngen_summary(rows, None)})", None
    return todo, (f"deploy-win: .NET native images: {total} items pending "
                  f"({ngen_summary(rows, None)}); draining the queue before any leg"), None


def ngen_verdict(results, text, problem):
    """`results` is (framework, pending before, failure or None, seconds) per
    drain; `text` the reading after them. (lines, refusal)."""
    lines = [f"deploy-win: ngen executeQueuedItems on {f}: {n} items pending before, "
             f"{secs:.0f}s, {why or 'exit 0'}" for f, n, why, secs in results]
    todo, _, refusal = ngen_plan(text, problem, " after the drain")
    if refusal:
        return lines, refusal
    if todo:
        left = ", ".join(f"{f} {n}" for f, n in todo)
        failed = "; ".join(f"{f} {why}" for f, _, why, _ in results if why) or "every drain exited 0"
        return lines, _ngen_refusal(f"{sum(n for _, n in todo)} items are still pending after "
                                    f"executeQueuedItems ({left}; {failed})")
    took = sum(secs for _, _, _, secs in results)
    lines.append(f"deploy-win: .NET native images: drained "
                 f"{sum(n for _, n, _, _ in results)} items in {took:.0f}s; nothing pending now")
    return lines, None


def windows_report(lane, when, ssh_argv, runtimes):
    """`ssh_argv` is the lane's own ssh prefix up to and including the host."""
    t0 = time.monotonic()
    host, _ = host_line()
    say(lane, when, host)
    text, problem = _run([*ssh_argv, windows_command(runtimes)], timeout=60)
    for sentence in windows_sentences(text, problem):
        say(lane, when, sentence)
    say(lane, when, f"the reading took {int((time.monotonic() - t0) * 1000)} ms from the host")


# ------------------------------------------------------- run against run

def leg_times(text):
    return {m.group(1): int(m.group(2)) for m in LEG.finditer(text)}


def baseline(lane, current, runs_dir, exclude):
    """The newest earlier run whose `lane` log shares at least half of this
    run's legs (and ten), with its legs."""
    need = max(10, len(current) // 2)
    try:
        dirs = sorted((d for d in pathlib.Path(runs_dir).iterdir()
                       if d.is_dir() and d.name != exclude), reverse=True)
    except OSError:
        return None, {}, need
    for d in dirs:
        log = d / f"{lane}.log"
        if not log.is_file():
            continue
        legs = leg_times(log.read_text(encoding="utf-8", errors="replace"))
        if len(set(legs) & set(current)) >= need:
            return d.name, legs, need
    return None, {}, need


def compare_sentence(lane, current, stamp, previous, need, net, budget):
    """(fires, sentence): fires when the shared legs' sum moved more than
    SHIFT or the lane ran over its ceiling."""
    over = budget > 0 and net > budget
    if stamp is None:
        return over, (f"{lane}: no earlier run under target/validate-lanes/runs carries "
                      f"a {lane} log sharing {need} of this run's {len(current)} legs; "
                      f"no leg-time baseline")
    shared = sorted(set(current) & set(previous))
    now_sum = sum(current[k] for k in shared)
    then_sum = sum(previous[k] for k in shared)
    change = (now_sum / then_sum - 1) if then_sum else 0.0
    fires = over or abs(change) > SHIFT
    head = (f"{lane}: legs' sum {now_sum}s over the {len(shared)} legs this run shares "
            f"with run {stamp}, against {then_sum}s there ({change:+.0%})")
    if not fires:
        return False, head
    slower = sum(1 for k in shared if current[k] > previous[k])
    faster = sum(1 for k in shared if current[k] < previous[k])
    ratios = [current[k] / previous[k] for k in shared if previous[k] >= 2]
    median = (f"median ratio {statistics.median(ratios):.2f}x over the {len(ratios)} "
              f"legs of 2s or more there" if ratios else "no leg took 2s or more there")
    movers = sorted(shared, key=lambda k: -abs(current[k] - previous[k]))[:5]
    new = sorted(set(current) - set(previous))
    gone = sorted(set(previous) - set(current))
    tail = ""
    if new:
        tail += f"; {len(new)} legs new since then ({sum(current[k] for k in new)}s)"
    if gone:
        tail += f"; {len(gone)} legs of that run not run now"
    why = (f"over its {budget}s ceiling at {net}s net" if over else
           f"moved more than {SHIFT:.0%}")
    return True, (f"LEG-TIME SHIFT ({why}) — {head}; {slower} slower, {faster} faster, "
                  f"{median}; largest movers: "
                  + ", ".join(f"{k} {previous[k]}->{current[k]}s" for k in movers) + tail)


def compare_runs(lane, log_text, runs_dir, exclude, net, budget):
    current = leg_times(log_text)
    if not current:
        return False, f"{lane}: the log carries no `<leg>: PASS (Ns)` line to compare"
    stamp, previous, need = baseline(lane, current, runs_dir, exclude)
    return compare_sentence(lane, current, stamp, previous, need, net, budget)


def health_lines(log_text):
    return [ln for ln in log_text.splitlines() if ln.startswith(PREFIX)]


# ------------------------------------------------------------ the drive

WIN_GOOD = """boot=2026-10-14T11:12:00.0000000Z
now=2026-10-14T12:12:30.0000000Z
cores=4
sample=2.01
cpu=MsMpEng|450.5|1.6
cpu=dwm|262|0.4
cpu=svchost|90|0
cpu=svchost|10|0.02
cpuhidden=System
cpuhidden=Idle
mp.rtp=True
mp.mode=Normal
mp.qs=2026-10-14T11:20:00.0000000Z
mp.qe=2026-10-14T11:05:00.0000000Z
mp.fs=2026-10-01T02:00:00.0000000Z
mp.fe=2026-10-01T03:30:00.0000000Z
mp.xpath=C:\\kaya
mp.xproc=java.exe
rt=python.exe|C:\\Python313\\python.exe
rt=java.exe|C:\\jdk\\bin\\java.exe
rt=node.exe|C:\\kaya\\node24\\node.exe
rt=go.exe|missing:C:\\kaya\\go127\\go\\bin\\go.exe
rt=dotnet.exe|
pscpu=1620.5|910
ngen=FrameworkArm64|0|64
ngen=Framework64|0|0
ngen=Framework|absent|0
took=3120
"""

WIN_QUIET = """boot.error=Access denied
now=2026-10-14T12:12:30Z
sample=0
mp.error=Get-MpComputerStatus : not recognized
mp.preferror=Get-MpPreference : not recognized
pscpu.error=Access is denied
ngen.error=The term ngen.exe is not recognized
"""

WIN_NA = """boot=2026-10-14T11:12:00Z
now=bogus
sample=2
cpu=Idle|5|0
mp.rtp=True
mp.mode=Normal
mp.qs=
mp.qe=
mp.fs=2026-10-01T02:00:00Z
mp.fe=2026-10-01T03:00:00Z
mp.xpath=N/A: Must be an administrator to view exclusions
pscpu=390.63|220
ngen=FrameworkArm64|5|0
ngen=Framework64|0|x
"""

NGEN_CLEAN = "ngen=FrameworkArm64|0|0\nngen=Framework64|0|0\nngen=Framework|0|0\n"
NGEN_STALE = "#< CLIXML\nngen=FrameworkArm64|0|64\nngen=Framework64|0|3\nngen=Framework|0|0\n"


def _plan(text, problem=None):
    todo, sentence, refusal = ngen_plan(text, problem)
    return [f"todo {todo}", f"sentence {sentence}", f"refusal {refusal}"]


def _verdict(results, text, problem=None):
    lines, refusal = ngen_verdict(results, text, problem)
    return lines + [f"refusal {refusal}"]

PS = """    1     0 05-10:00:00   9:00.00   0.0 /sbin/launchd
  100     1 01:00:00   1:00.00  12.0 /usr/bin/launchd_sim
  101   100 59:00   0:30.00  40.0 /usr/libexec/searchd
  102   101 58:00   0:02.00   0.0 /Applications/Kaya.app/kaya
  200     1 02:00:00   2:00.00   0.0 /usr/bin/launchd_sim
  201   200 1:59:00   0:01.00   0.0 /usr/libexec/backboardd
  300     1 10:00   0:05.00  95.0 /usr/bin/qemu-system-aarch64
"""
VM_A = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                     9000.
Pages stored in compressor:                  5600000.
Pages occupied by compressor:                1400000.
Compressions:                                  20000.
Pageins:                                        1000.
Swapouts:                                          3.
"""
VM_B = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                     2963.
Pages stored in compressor:                  5653794.
Pages occupied by compressor:                1424209.
Compressions:                                 200000.
Pageins:                                       14000.
Swapouts:                                         10.
"""
SWAP = "total = 13312.00M  used = 11597.06M  free = 1714.94M  (encrypted)\n"
TOP_MEM = """Processes: 900 total
PhysMem: 63G used (8G wired, 22G compressor), 100M unused.

PID    MEM
300    16G
101    8496M+
100    512M-
"""
ARGS = """  100 launchd_sim /Users/x/Library/Developer/CoreSimulator/Devices/AAAA/data/var/run/launchd_bootstrap.plist
  200 launchd_sim /Users/x/Library/Developer/CoreSimulator/Devices/BBBB/data/var/run/launchd_bootstrap.plist
"""

ANDROID_GOOD = """17329.00 65026.75
==ps
    TIME+ NAME
  8:20.99 surfaceflinger
  5:03.35 system_server
==top
 4.0 top
 0.0 kworker

 12.0 system_server
 3.0 surfaceflinger
 0.0 init
"""
ANDROID_ONEFRAME = """bogus
==ps
==top
 0.0 top
"""

DOCKER_GOOD = """[2026-10-14T19:07:52.479865000Z][com.docker.backend.idle] stopping VM
[2026-10-14T20:36:17.499842000Z][com.docker.backend.idle] idle -> busy (was idle for 1h33m25.36s; reason: [x])
[2026-10-14T20:36:17.500070000Z][com.docker.backend.idle] starting VM
[2026-10-14T20:40:00.705377000Z][com.docker.backend.ipc] (6c135af2-16) a4ae0185-BackendAPI S->C 19bdc181-init POST /analytics/track/oom-kills (1.4ms): 1
[2026-10-14T21:08:22.787023000Z][com.docker.backend.idle] stopping VM
"""

LINUX_GOOD = """3600.5 9000.1
2.50 1.20 0.80 3/349 657
18
==ps
00:12:00 dockerd
00:01:00 containerd
"""


def _legs(pairs):
    return "".join(f"{k}: PASS ({v}s)\n" for k, v in pairs.items())


def _app(n, name, asn, bundle, exe, pid, kind, launch="", checkin="2026/10/14 09:00:00",
         parent=""):
    b = f'bundleID="{bundle}"' if bundle else "bundleID=[ NULL ] "
    lines = [f'{n:>2}) "{name}" {asn}: ', f"    {b}", f'    executable path="{exe}"',
             f'    pid = {pid} type="{kind}" flavor=3 Version="1" Arch=ARM64 ']
    if parent:
        lines.append(f'    parentASN="{parent}" ASN:0x0-0x10010: ')
    if launch:
        lines.append(f"    launch time =  {launch} ( 1 minutes ago )")
    lines.append(f"    checkin time = {checkin} ( 1 minutes ago )")
    return "\n".join(lines) + "\n"


APPS_START = (_app(1, "Finder", "ASN:0x0-0x1a01a", "com.apple.finder",
                   "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", 704,
                   "Foreground")
              + _app(2, "Terminal", "ASN:0x0-0x760760", "com.apple.Terminal",
                     "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                     72377, "Foreground", launch="2026/09/20 19:09:59", parent="Dock"))
PREVIEW = _app(3, "Preview", "ASN:0x0-0x25e44f00", "com.apple.Preview",
               "/System/Applications/Preview.app/Contents/MacOS/Preview", 84150, "Foreground",
               launch="2026/10/14 16:00:38", checkin="2026/10/14 16:00:39")
HIJACK = _app(4, "Preview", "ASN:0x0-0x25e44e1f", "com.apple.Preview",
              "/repo/target/go-guests/kaya-go", 84118, "Foreground",
              checkin="2026/10/14 16:00:38")
PY_GUEST = _app(5, "python3.13", "ASN:0x0-0x2a2a2a", "", "/nix/store/x-python3/bin/python3.13",
                900, "UIElement", checkin="2026/10/14 16:00:31")
DAEMON = _app(6, "helperd", "ASN:0x0-0x3b3b3b", "com.example.helperd", "/usr/libexec/helperd",
              901, "BackgroundOnly", checkin="2026/10/14 16:00:32")
LONER = _app(7, "Calculator", "ASN:0x0-0x4c4c4c", "com.apple.calculator",
             "/System/Applications/Calculator.app/Contents/MacOS/Calculator", 902, "Foreground",
             launch="2026/10/14 16:00:50", parent="Terminal")
NOBUNDLE = _app(8, "a.out", "ASN:0x0-0x5d5d5d", "", "/tmp/a.out", 903, "Foreground",
                checkin="2026/10/14 16:00:33")
AXAGENT = _app(14, "Accessibility Services", "ASN:0x0-0x9b9b9b", HOST_AGENTS[0][1], HOST_AGENTS[0][2],
                906, "UIElement", launch="2026/10/14 16:00:35", checkin="2026/10/14 16:00:35")
ODD = _app(9, "Odd", "ASN:0x0-0x6e6e6e", 'com.x"y', "/Applications/Odd.app/Contents/MacOS/Odd",
           904, "Foreground", checkin="2026/10/14 16:00:34")
SIGHTING_LOG = """Timestamp               Ty Process[PID:TID]
2026-10-14 16:00:38.593 Df kaya-go[84118:10d9b379] [com.apple.processmanager:front-35286506] CHECKIN: pid=84118
2026-10-14 16:00:38.599 Df launchservicesd[384:10d97cfb] [com.apple.launchservices:cas] CHECKIN:0x0-0x25e44e1f 84118 com.apple.Preview
2026-10-14 16:00:38.876 Df WindowServer[414:1390] [com.apple.SkyLight.processes:Lifecycle] 9cae53[CreateApplication]: Process update: STUB process 0x0-0x25e44e1f (Preview) is migrating to real process, updating connectionID 0x97ac0f -> 0x9cae53, updating pid 0 -> 84118 in session 0x101
2026-10-14 16:00:38.900 Df talagentd[27914:10d9bf86] [com.apple.talagent:log] - com.apple.Preview: Relaunching due to app activation or Dock menu command
2026-10-14 16:00:38.929 Df runningboardd[422:10d97bb4] [com.apple.runningboard:ttl] Acquiring assertion targeting app<application.com.apple.Preview.1.2(501)> from originator [osservice<com.apple.coreservices.uiagent(501)>:652] with description <RBSAssertionDescriptor| "LS launch com.apple.Preview" ID:422-652-1326377 target:app<application.com.apple.Preview.1.2(501)> attributes:[
2026-10-14 16:00:38.940 Df launchservicesd[384:10d97cfb] [com.apple.launchservices:cas] CHECKIN:0x0-0x25e44f00 84150 com.apple.Preview
"""
WINLIST = ('win=12 pid=84150 layer=0 bounds=0,25,800,600 app="Preview" title="Open"\n'
           'win=13 pid=700 layer=25 bounds=0,0,10,10 app="Dock" title=""\n'
           "flightrec-winlist: 2 window(s)\n")
APPS_PS = ("    1     0 05-10:00:00   9:00.00   0.0 /sbin/launchd\n"
           "84150     1 00:05   0:01.00   3.0 /System/Applications/Preview.app/Contents/MacOS/Preview\n"
           "  902 72377 00:15   0:01.00   0.0 /System/Applications/Calculator.app/Contents/MacOS/Calculator\n"
           "72377     1 20:00:00   1:00.00   0.0 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal\n")


def _apps_run(listings, legs=(), log=(SIGHTING_LOG, None), windows=(WINLIST, None),
              ps=(APPS_PS, None)):
    """[the start's sentence, the end's sentences...] over doctored readers:
    `listings` is (text, problem) for the start, each leg's end, and the end."""
    queue = list(listings)
    apps = MacApps(read=lambda: queue.pop(0), log=lambda b, t: log,
                   windows=lambda pid, root: windows, ps=lambda: ps,
                   clock=lambda: _local_epoch("2026/10/14 16:00:00"))
    apps.root = "/repo"
    said = [apps.start()]
    apps.legs = [[n, _local_epoch(a), _local_epoch(b)] for n, a, b in legs]
    while len(queue) > 1:
        apps.sample("after a leg")
    return said + apps.end()


SIGHTING_LEGS = (("scroll-go-swiftui", "2026/10/14 16:00:30", "2026/10/14 16:00:40"),
                 ("scrollto-rust-swiftui", "2026/10/14 16:00:37", "2026/10/14 16:00:39"),
                 ("canvas-rust-swiftui", "2026/10/14 15:59:00", "2026/10/14 16:00:20"),
                 ("ended-before", "2026/10/14 16:00:10", "2026/10/14 16:00:37"),
                 ("began-after", "2026/10/14 16:00:39", "2026/10/14 16:00:45"))
NOTIME = ' 10) "Ghost" ASN:0x0-0x7f7f7f: \n    bundleID="com.example.ghost"\n' \
         '    executable path="/Applications/Ghost.app/Contents/MacOS/Ghost"\n' \
         '    pid = 905 type="Foreground" flavor=3 Arch=ARM64 \n'


def drive():
    """Every branch's sentence from a doctored transcript: (label, wanted
    fragment, sentences)."""
    cases = []
    boot = "{ sec = 1000, usec = 0 } Thu"
    cases.append(("host", "busiest now (ps's decaying share): qemu-system-aarch64 95%",
                  [host_sentence(PS, None, (1.0, 2.0, 3.0), boot, None, 4600, 8)]))
    cases.append(("host uptime", "up 1h00m",
                  [host_sentence(PS, None, (1.0, 2.0, 3.0), boot, None, 4600, 8)]))
    cases.append(("host no uptime", "uptime unreadable (sysctl exited 1",
                  [host_sentence(PS, None, (1, 1, 1), "", "sysctl exited 1: x", 0, 8)]))
    cases.append(("host no ps", "process table unreadable (ps did not answer",
                  [host_sentence("", "ps did not answer within 30s", (1, 1, 1), boot, None, 4600, 8)]))
    cases.append(("host empty ps", "ps listed no process it could parse",
                  [host_sentence("garbage\n", None, (1, 1, 1), boot, None, 4600, 8)]))
    cases.append(("host idle", "busiest now (ps's decaying share): nothing above 0%",
                  [host_sentence("  1 0 1:00 0:01.00 0.0 /sbin/launchd\n", None, (1, 1, 1),
                                 boot, None, 4600, 8)]))
    cases.append(("thermal", "thermal (pmset -g therm): CPU_Scheduler_Limit = 100; CPU_Speed_Limit = 62; CPU_Available_CPUs = 12",
                  [thermal_sentence("CPU_Scheduler_Limit \t= 100\nCPU_Speed_Limit = 62\n"
                                    "CPU_Available_CPUs = 12\n", None)]))
    cases.append(("thermal nominal", "thermal (pmset -g therm): No thermal warning level has been recorded",
                  [thermal_sentence("Note: No thermal warning level has been recorded\n", None)]))
    cases.append(("thermal no pmset", "thermal state unreadable (pmset exited 1",
                  [thermal_sentence("", "pmset exited 1: x")]))
    cases.append(("thermal silent", "thermal state unreadable (pmset -g therm printed nothing)",
                  [thermal_sentence("\n", None)]))
    rows = parse_ps(PS)
    mem = memory_sentence(VM_A, VM_B, None, 1.0, SWAP, None, TOP_MEM, None, rows)
    for label, want in (
            ("memory pressure", "memory: 0.0 GB free, compressor 86.3 GB held in 21.7 GB"),
            ("memory sample", "over a 1s sample 13000 page-ins, 180000 compressions, 7 swap-outs"),
            ("memory swap", "swap 11.3 of 13.0 GB used"),
            ("memory footprints", "largest footprints (top's mem): qemu-system-aarch64 16.0 GB, "
             "searchd 8.3 GB, launchd_sim 0.5 GB")):
        cases.append((label, want, [mem]))
    cases.append(("memory unreadable", "memory: vm_stat unreadable (vm_stat exited 1: x); swap "
                  "unreadable (sysctl exited 1: y); footprints unreadable (top did not answer",
                  [memory_sentence("", "", "vm_stat exited 1: x", 1.0, "", "sysctl exited 1: y",
                                   "", "top did not answer within 30s", rows)]))
    cases.append(("memory garbled", "vm_stat unreadable (no page size in its output); swap "
                  "unreadable (vm.swapusage said 'x'); footprints unreadable (top listed no pid "
                  "and size)", [memory_sentence("x", "x", None, 1.0, "x", None, "x", None, rows)]))
    cases.append(("memory unnamed pid", "largest footprints (top's mem): pid 999 2.0 GB",
                  [memory_sentence(VM_A, VM_B, None, 1.0, SWAP, None, "999 2048M+\n", None, rows)]))
    ios = ios_sentences(PS, ARGS, ["AAAA", "BBBB", "CCCC"])
    cases.append(("simulator", "simulator AAAA: up 1h00m (its launchd_sim), 2 processes; "
                  "busiest now: searchd 40%; most CPU since boot: searchd 30s, kaya 2s", ios))
    cases.append(("idle simulator", "simulator BBBB: up 2h00m (its launchd_sim), 1 processes; "
                  "busiest now: nothing above 0%", ios))
    cases.append(("missing simulator", "simulator CCCC: no launchd_sim", ios))
    cases.append(("emulator", "emulator e1: up 4h48m; busiest over a 1s sample: system_server "
                  "12%, surfaceflinger 3%; most CPU since boot: surfaceflinger 8m20s, "
                  "system_server 5m03s", [android_sentence("e1", ANDROID_GOOD, None)]))
    cases.append(("emulator one frame", "uptime unreadable (/proc/uptime said 'bogus'); busiest "
                  "over a 1s sample: no second top frame came back (1 frame(s)); most CPU since "
                  "boot: ps listed none", [android_sentence("e2", ANDROID_ONEFRAME, None)]))
    cases.append(("emulator failed", "emulator e3: reading failed: adb exited 1",
                  [android_sentence("e3", "", "adb exited 1: device offline")]))
    cases.append(("docker VM", "docker VM up 1h00m, load 2.50 1.20 0.80 on 18 cores; most CPU "
                  "since boot: dockerd 12m00s, containerd 1m00s",
                  [linux_sentence(LINUX_GOOD, None)]))
    events = docker_events(DOCKER_GOOD)
    cases.append(("docker VM woken", "Docker Desktop's VM last started at 2026-10-14T20:36:17Z: "
                  "Resource Saver had stopped it at 2026-10-14T19:07:52Z and a docker call woke it "
                  "(woke after 1h33m25.36s)", [docker_sentence(events[:3], None)]))
    cases.append(("docker VM moved", "since 2026-10-14T20:36:20Z: oom kill at 2026-10-14T20:40:00Z, "
                  "stop at 2026-10-14T21:08:22Z — the VM moved under this lane",
                  [docker_sentence(events, None, "2026-10-14T20:36:20")]))
    cases.append(("docker VM still", "since 2026-10-14T20:36:20Z: no stop, start or OOM kill",
                  [docker_sentence(events[:3], None, "2026-10-14T20:36:20")]))
    cases.append(("docker VM no start", "no VM start in its backend log", [docker_sentence([], None)]))
    cases.append(("docker VM cold start", "the previous stop is not in the log, and no idle wake",
                  [docker_sentence(events[2:3], None)]))
    cases.append(("docker log unreadable", "Docker Desktop's VM record unreadable: x: No such file",
                  [docker_sentence([], "x: No such file")]))
    cases.append(("docker VM failed", "docker VM reading failed: docker exited 125",
                  [linux_sentence("", "docker exited 125: no such image")]))
    cases.append(("docker VM garbled", "docker VM uptime unreadable, load unreadable; most CPU "
                  "since boot: ps listed none", [linux_sentence("x\n", None)]))
    good = windows_sentences(WIN_GOOD, None)
    for label, want in (
            ("guest boot", "guest booted 2026-10-14 11:12Z, up 1h00m"),
            ("guest sample", "guest busiest over a 2.0s sample (4 cores): MsMpEng 80% of a core, "
             "dwm 20% of a core, svchost 1% of a core"),
            ("guest since boot", "guest CPU since boot: MsMpEng 450s, dwm 262s, svchost 100s"),
            ("guest hidden", "guest: 2 processes' CPU unreadable to this session (Idle, System)"),
            ("scan running", "a quick scan started 2026-10-14 11:20Z and has recorded no end"),
            ("scan done", "last full scan 2026-10-01 02:00Z to 03:30Z, 13d08h42m before this "
             "reading"),
            ("excluded path", "node.exe excluded (C:\\kaya\\node24\\node.exe under c:\\kaya)"),
            ("excluded process", "java.exe excluded as a process (C:\\jdk\\bin\\java.exe)"),
            ("scanned", "python.exe SCANNED (C:\\Python313\\python.exe; no exclusion covers it)"),
            ("absent runtime", "go.exe absent at C:\\kaya\\go127\\go\\bin\\go.exe"),
            ("runtime off PATH", "dotnet.exe not found on the guest's PATH"),
            ("guest cost", "the guest's reading took 3120 ms")):
        cases.append((label, want, good))
    quiet = windows_sentences(WIN_QUIET, None)
    cases.append(("boot error", "guest boot time unreadable: Access denied", quiet))
    cases.append(("no sample", "guest CPU sample unreadable (sample='0')", quiet))
    cases.append(("no processes", "guest CPU since boot: no process reported any", quiet))
    cases.append(("Defender error", "Defender status unreadable: Get-MpComputerStatus", quiet))
    cases.append(("exclusions error", "Defender exclusions unreadable: Get-MpPreference", quiet))
    na = windows_sentences(WIN_NA, None)
    cases.append(("bad clock", "guest boot time unreadable: boot='2026-10-14T11:12:00Z' "
                  "now='bogus'", na))
    cases.append(("idle guest", "(? cores): no process used CPU", na))
    cases.append(("sub-percent share", "busiest now: launchd 0.3%",
                  ios_sentences("  1 0 1:00 0:01.00 0.0 /sbin/launchd_sim\n"
                                "  2 1 1:00 0:01.00 0.3 /sbin/launchd\n",
                                "  1 launchd_sim /x/Devices/DDDD/data\n", ["DDDD"])))
    cases.append(("docker VM idle ps", "most CPU since boot: ps listed none",
                  [linux_sentence("1 1\n0 0 0 1/1 1\n4\n==ps\n00:00:00 initd\n", None)]))
    cases.append(("never scanned", "no quick scan recorded", na))
    cases.append(("scan without age", "last full scan 2026-10-01 02:00Z to 03:00Z|END",
                  [s + "|END" for s in na]))
    cases.append(("exclusions N/A", "Defender exclusions unreadable to this session: N/A: Must be",
                  na))
    for label, want in (
            ("slow powershell", "guest PowerShell start (-NoProfile -Command exit): SLOW, past "
             "900 ms: 1620 ms of CPU, 910 ms wall (300-480 ms"),
            ("pending images", "native-image queues: FrameworkArm64 64 PENDING, Framework64 0 "
             "pending, Framework has no ngen.exe")):
        cases.append((label, want, good))
    cases.append(("quick powershell", "(-NoProfile -Command exit): 391 ms of CPU, 220 ms wall", na))
    cases.append(("powershell error", "guest PowerShell start unreadable: Access is denied", quiet))
    garbled = windows_sentences("now=2026-10-14T12:12:30Z\npscpu=x\n", None)
    cases.append(("powershell garbled", "guest PowerShell start unreadable (pscpu='x')", garbled))
    cases.append(("images error", "native-image queues: unreadable: The term ngen.exe", quiet))
    cases.append(("images unreadable", "native-image queues: FrameworkArm64 unreadable (ngen "
                  "display exited 5, counted '0'), Framework64 unreadable (ngen display exited 0, "
                  "counted 'x')", na))
    cases.append(("images unprinted", "native-image queues: the guest printed no ngen reading",
                  garbled))
    cases.append(("plan clean", "sentence deploy-win: .NET native images: nothing pending "
                  "(FrameworkArm64 0 pending, Framework64 0 pending, Framework 0 pending)",
                  _plan(NGEN_CLEAN)))
    cases.append(("plan stale", "sentence deploy-win: .NET native images: 67 items pending "
                  "(FrameworkArm64 64 PENDING, Framework64 3 PENDING, Framework 0 pending); "
                  "draining the queue before any leg", _plan(NGEN_STALE)))
    cases.append(("plan drains only the pending", "todo [('FrameworkArm64', 64), "
                  "('Framework64', 3)]", _plan(NGEN_STALE)))
    cases.append(("plan ssh failed", "refusal deploy-win: the guest's .NET native-image queues "
                  "could not be read (ssh exited 255: x)", _plan("", "ssh exited 255: x")))
    cases.append(("plan names the command", "run `C:\\Windows\\Microsoft.NET\\FrameworkArm64"
                  "\\v4.0.30319\\ngen.exe executeQueuedItems`; `C:\\Windows\\Microsoft.NET"
                  "\\Framework64\\v4.0.30319\\ngen.exe executeQueuedItems`",
                  _plan("", "ssh exited 255: x")))
    cases.append(("plan ngen error", "could not be read (The term ngen.exe is not recognized)",
                  _plan(WIN_QUIET)))
    cases.append(("plan silent", "could not be read (the guest printed no ngen reading)",
                  _plan("#< CLIXML\n")))
    cases.append(("plan uncounted", "the native-image queue could not be counted for "
                  "FrameworkArm64 (ngen display exited 5, counted '0'), Framework64 (ngen display "
                  "exited 0, counted 'x')", _plan(WIN_NA)))
    cases.append(("plan no ngen", "no framework on the guest has an ngen.exe (FrameworkArm64 has "
                  "no ngen.exe)", _plan("ngen=FrameworkArm64|absent|0\n")))
    drained = _verdict([("FrameworkArm64", 64, None, 183.2), ("Framework64", 3, None, 4.1)],
                       NGEN_CLEAN)
    cases.append(("drain line", "deploy-win: ngen executeQueuedItems on FrameworkArm64: 64 items "
                  "pending before, 183s, exit 0", drained))
    cases.append(("drained", "deploy-win: .NET native images: drained 67 items in 187s; nothing "
                  "pending now", drained))
    cases.append(("drained without refusal", "refusal None", drained[-1:]))
    left = _verdict([("FrameworkArm64", 64, "ssh exited 1: x", 20.0)],
                    "ngen=FrameworkArm64|0|2\nngen=Framework64|0|0\nngen=Framework|0|0\n")
    cases.append(("drain failed", "refusal deploy-win: 2 items are still pending after "
                  "executeQueuedItems (FrameworkArm64 2; FrameworkArm64 ssh exited 1: x)", left))
    cases.append(("drain failed line", "64 items pending before, 20s, ssh exited 1: x", left))
    cases.append(("drain exited 0 and left items", "(FrameworkArm64 2; every drain exited 0)",
                  _verdict([("FrameworkArm64", 64, None, 20.0)],
                           "ngen=FrameworkArm64|0|2\nngen=Framework|0|0\n")))
    cases.append(("drain unreadable after", "could not be read after the drain (ssh did not "
                  "answer within 60s)",
                  _verdict([("Framework", 1, "ssh did not answer within 1800s", 1800.0)], "",
                           "ssh did not answer within 60s")))
    cases.append(("guest silent", "guest reading failed: ssh exited 255",
                  windows_sentences("", "ssh exited 255: Connection refused")))
    cases.append(("guest printed nothing", "guest reading failed: the guest printed nothing",
                  windows_sentences("\n", None)))

    seen = _apps_run([(APPS_START, None),
                      (APPS_START + PREVIEW + HIJACK + PY_GUEST + DAEMON + AXAGENT, None),
                      (APPS_START + PREVIEW + PY_GUEST, None)], SIGHTING_LEGS)
    for label, want in (
            ("apps at start", "2 GUI applications running at the lane's start (lsappinfo)"),
            ("app appeared", "APP APPEARED: Preview (com.apple.Preview, pid 84150, Foreground, "
             "/System/Applications/Preview.app/Contents/MacOS/Preview) launched 2026/10/14 "
             "16:00:38 while scroll-go-swiftui, scrollto-rust-swiftui ran; first seen after "
             "a leg; lsappinfo names no parent; parent process launchd (pid 1)"),
            ("LaunchServices requester", "LaunchServices launched it at 16:00:38.929 for "
             "osservice<com.apple.coreservices.uiagent(501)>:652"),
            ("TAL relaunch", "talagentd at 16:00:38.900: com.apple.Preview: Relaunching due "
             "to app activation or Dock menu command"),
            ("foreign checkin", "pid 84118 (kaya-go) checked in under com.apple.Preview's "
             "ASN 0x0-0x25e44e1f at 16:00:38.599"),
            ("stub moved", "WindowServer moved Preview's stub 0x0-0x25e44e1f to pid 84118 "
             "(kaya-go) at 16:00:38.876"),
            ("window on screen", "1 window(s) of its own on screen when first seen: layer 0 "
             "\"Open\" at 0,25,800,600; still running at the lane's end"),
            ("lane binary under another id", "launched 2026/10/14 16:00:38 while "
             "scroll-go-swiftui, scrollto-rust-swiftui ran; its executable is the lane's own "
             "(a binary built in the tree) but it checked in as com.apple.Preview"),
            ("no window", "no window of its own on screen when first seen "
             "(flightrec-winlist: 2 window(s))"),
            ("gone by the end", "no window of its own on screen when first seen "
             "(flightrec-winlist: 2 window(s)); gone by the lane's end"),
            ("parent gone", "gone before its parent process could be read"),
            ("summary", "2 GUI application(s) appeared during the lane (3 readings across 5 "
             "legs; the lane's own apps excluded by name: python3 1; host agents excluded by "
             "name: Accessibility Services 1)")):
        cases.append((label, want, seen))
    cases.append(("identity adopted", "IDENTITY ADOPTED: pid 84118 (/repo/target/go-guests/"
                  "kaya-go, the lane's own: a binary built in the tree) is registered with "
                  "LaunchServices as Preview (com.apple.Preview, ASN:0x0-0x25e44e1f, Foreground), "
                  "checked in 2026/10/14 16:00:38 while scroll-go-swiftui, scrollto-rust-swiftui "
                  "ran; first seen after a leg", seen))
    late = _app(11, "Preview", "ASN:0x0-0x25e44e1f", "com.apple.Preview",
                "/repo/target/rust-guests/scroll", 84200, "BackgroundOnly",
                launch="2026/09/24 19:20:07", checkin="2026/10/14 16:00:50")
    ghost = (' 12) "Preview" ASN:0x0-0x25e44e20: \n    bundleID="com.apple.Preview"\n'
             '    executable path="/repo/target/c-guests/scroll"\n'
             '    pid = 84201 type="Foreground" flavor=3 Arch=ARM64 \n')
    own = _app(13, "Notes", "ASN:0x0-0x8a8a8a", "dev.kaya.aurora.notes",
               "/repo/target/rust-guests/notes.app/Contents/MacOS/notes", 84202, "Foreground",
               checkin="2026/10/14 16:00:36")
    stale = _apps_run([(APPS_START + HIJACK, None), (APPS_START + HIJACK + late + ghost + own, None),
                       (APPS_START, None)], SIGHTING_LEGS)
    for label, want in (
            ("adopted while no leg ran", "IDENTITY ADOPTED: pid 84200 (/repo/target/rust-guests/"
             "scroll, the lane's own: a binary built in the tree) is registered with "
             "LaunchServices as Preview (com.apple.Preview, ASN:0x0-0x25e44e1f, BackgroundOnly), "
             "checked in 2026/10/14 16:00:50 while no leg of this lane was running"),
            ("adopted with no checkin time", "IDENTITY ADOPTED: pid 84201 (/repo/target/c-guests/"
             "scroll, the lane's own: a binary built in the tree) is registered with "
             "LaunchServices as Preview (com.apple.Preview, ASN:0x0-0x25e44e20, Foreground), at "
             "a checkin time lsappinfo did not give")):
        cases.append((label, want, stale))
    quiet = [s for s in stale if s.startswith("IDENTITY ADOPTED") and (
        "pid 84118 " in s or "pid 84202 " in s)]
    cases.append(("a record held since the start and kaya's own bundle not refused",
                  "refused 2 of 4: 84200 84201",
                  [f"refused {len([x for x in stale if x.startswith('IDENTITY ADOPTED')])} of 4: "
                   + " ".join(x.split()[3] for x in stale if x.startswith("IDENTITY ADOPTED"))
                   + (" WRONGLY " + repr(quiet) if quiet else "")]))
    alone = _apps_run([(APPS_START, None),
                       (APPS_START + LONER + NOBUNDLE + ODD + NOTIME, None),
                       (APPS_START + LONER, None)],
                      SIGHTING_LEGS, log=("Timestamp\n", None),
                      windows=("", "flightrec-winlist exited 1: x"))
    for label, want in (
            ("no leg running", "launched 2026/10/14 16:00:50 while no leg of this lane was "
             "running; first seen"),
            ("lsappinfo parent", "lsappinfo's parent Terminal; parent process Terminal "
             "(pid 72377)"),
            ("no requester", "the unified log names no requester (runningboardd's LS launch, "
             "talagentd, launchservicesd's checkins and WindowServer's stub moves, read 5s "
             "before to 2s after the launch)"),
            ("no bundle", "APP APPEARED: a.out (no bundle id, pid 903"),
            ("no bundle not asked", "no bundle id, so the log was not asked for a requester"),
            ("odd bundle", "bundle id 'com.x\"y' cannot be spelled in a log predicate"),
            ("no launch time", "Ghost (com.example.ghost, pid 905, Foreground, "
             "/Applications/Ghost.app/Contents/MacOS/Ghost) at a time lsappinfo did not give, "
             "so the legs running then are unknown"),
            ("no launch time not asked", "the log was not asked: no launch time"),
            ("windows unreadable", "its windows unreadable (flightrec-winlist exited 1: x)")):
        cases.append((label, want, alone))
    cases.append(("nothing appeared", "no GUI application appeared during the lane (3 readings "
                  "across 0 legs; the lane's own apps excluded by name: none; host agents "
                  "excluded by name: none)",
                  _apps_run([(APPS_START, None), (APPS_START + DAEMON, None),
                             (APPS_START, None)])))
    blind = _apps_run([("", "lsappinfo exited 1: x")])
    cases.append(("start unreadable", "app list unreadable at the lane's start (lsappinfo "
                  "exited 1: x); no app can be called new", blind))
    cases.append(("end without a start", "no app appearing during the lane can be named", blind))
    cases.append(("reading failed mid-lane", "the app list was unreadable at 1 of them (first: "
                  "after a leg: lsappinfo did not answer within 10s)",
                  _apps_run([(APPS_START, None), ("", "lsappinfo did not answer within 10s"),
                             (APPS_START, None)])))
    dark = _apps_run([(APPS_START, None), (APPS_START + PREVIEW, None)],
                     log=("", "log exited 1: y"), ps=("", "ps exited 1: z"))
    cases.append(("log unreadable", "the unified log could not be read (log exited 1: y)", dark))
    cases.append(("ps unreadable", "its parent process unreadable (ps exited 1: z)", dark))

    then = {f"leg{i}": 10 for i in range(20)}
    slow = {f"leg{i}": 15 for i in range(20)}
    slow["leg3"] = 40
    slow["fresh"] = 7
    cases.append(("shift", "LEG-TIME SHIFT (moved more than 25%) — w: legs' sum 325s over the 20 "
                  "legs this run shares with run R1, against 200s there (+62%); 20 slower, 0 "
                  "faster, median ratio 1.50x over the 20 legs of 2s or more there; largest "
                  "movers: leg3 10->40s",
                  [compare_sentence("w", slow, "R1", then, 10, 900, 1650)[1]]))
    cases.append(("new legs", "; 1 legs new since then (7s)",
                  [compare_sentence("w", slow, "R1", then, 10, 900, 1650)[1]]))
    gone = dict(then, extra=3)
    cases.append(("legs not run", "; 1 legs of that run not run now",
                  [compare_sentence("w", slow, "R1", gone, 10, 900, 1650)[1]]))
    near = {k: v + 1 for k, v in then.items()}
    cases.append(("within band", "w: legs' sum 220s over the 20 legs this run shares with run "
                  "R1, against 200s there (+10%)",
                  [compare_sentence("w", near, "R1", then, 10, 900, 1650)[1]]))
    cases.append(("ceiling", "LEG-TIME SHIFT (over its 1650s ceiling at 1742s net)",
                  [compare_sentence("w", near, "R1", then, 10, 1742, 1650)[1]]))
    tiny = {f"leg{i}": 1 for i in range(20)}
    cases.append(("short legs", "no leg took 2s or more there",
                  [compare_sentence("w", {k: 2 for k in tiny}, "R1", tiny, 10, 0, 0)[1]]))
    cases.append(("no baseline", "w: no earlier run under target/validate-lanes/runs carries a "
                  "w log sharing 10 of this run's 21 legs",
                  [compare_sentence("w", slow, None, {}, 10, 0, 0)[1]]))
    fires = [compare_sentence("w", near, "R1", then, 10, 900, 1650)[0],
             compare_sentence("w", slow, "R1", then, 10, 900, 1650)[0]]
    cases.append(("fires only on a shift", "False True", [f"{fires[0]} {fires[1]}"]))
    parsed = leg_times("a: PASS (3s)\nb: FAIL (4s) red\nc: SKIP (1s)\nlane-health: x\n")
    cases.append(("leg parse", "{'a': 3, 'b': 4}", [repr(parsed)]))
    return cases


def selftest(echo=False):
    findings = []
    for label, want, sentences in drive():
        if echo:
            for s in sentences:
                if want in s:
                    print(f"lane-health drive [{label}]: {s}")
                    break
        if not any(want in s for s in sentences):
            findings.append(f"lane-health branch `{label}` did not print {want!r}; it "
                            f"printed: {' | '.join(sentences) or '(nothing)'}")
    return findings
