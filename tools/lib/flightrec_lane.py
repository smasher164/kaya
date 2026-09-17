"""The flight recorder's lane-side python half — what tools/lib/
flightrec.sh is to the shell runners, for the converted ones
(tools/deploy-win.py first; docs/runner-conversion-plan.md §6 says each
helper crosses WITH the first runner that stops sourcing it). The
journal itself stays tools/lib/flightrec.py; this wraps it the way the
shell functions did, plus the windows collection half, which left
flightrec.sh when its only consumer converted.

THE RECORDER MAY NEVER COST A LANE ITS LEGS: every entry point is a
no-op when the journal could not be opened, the miss is printed once by
start(), and nothing here raises to its caller.

A PASS TOUCHES NO SUBPROCESS AND NO VM. One python3 spawn per leg
measured 27ms and three ssh round trips per leg took the windows lane
110s over its ceiling on the recorder's first matrix
(docs/deferred.md); a passing leg costs one O_APPEND write to the
spool, flushed once at lane end.
"""

import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import threading
import re
import time

SECTION_CAP = int(os.environ.get("KAYA_FLIGHTREC_SECTION_CAP", "2097152"))
BUNDLE_CAP = int(os.environ.get("KAYA_FLIGHTREC_BUNDLE_CAP", "33554432"))

# WHAT A FAILURE-PATH BUNDLE CARRIES, PER LANE — one declaration, read by
# tools/check-flightrec.py and by finish() below, which writes a reasoned
# skip for any section the collect never reached. The linux row lives in
# tools/lib/flightrec.sh (FLIGHTREC_SECTIONS_LINUX) because that lane's
# runner is shell inside the container; the gate holds the two equal.
#
# Every lane carries the same first three — the leg's own log, the verb
# trace, and A PICTURE OF WHAT THE USER WOULD HAVE SEEN — and then what
# its platform can answer for (the maintainer's 2026-09-16 ruling: a
# bundle that could not name the cause is the defect to fix).
SECTIONS = {
    "mac": ("leg-log", "verb-trace", "shot", "desktop-shot", "windows",
            "windowserver", "sampler", "sample", "unified-log"),
    "windows": ("leg-log", "verb-trace", "shot", "desktop-shot", "desktop",
                "foreground", "foreground-text", "desktop-live", "notifications",
                "toast-moment"),
    "ios": ("leg-log", "verb-trace", "shot", "panic", "app-log", "devices"),
    "android": ("leg-log", "verb-trace", "shot", "logcat", "devices"),
    "linux": ("leg-log", "verb-trace", "shot", "desktop", "xvfb"),
}


def _flightrec(root):
    return str(pathlib.Path(root) / "tools" / "lib" / "flightrec.py")


def winlist_bin(root):
    """The macOS window-list binary, built on demand to a content-hashed
    path; None when it cannot be built.

    MODULE-LEVEL because a caller may need the window list WITHOUT a
    recorder: constructing a LaneRecorder opens a flight-recorder run,
    and tools/lib/lanes/mac.py's link door only wants to ask whether the
    relaunched process owns a window (docs/app-links-plan.md L5). One
    copy of the rule, two callers.
    """
    root = pathlib.Path(root)
    src = root / "tools/mac/flightrec-winlist.swift"
    if not src.is_file():
        return None
    digest = hashlib.sha256(src.read_bytes()).hexdigest()[:12]
    binp = root / f"target/tools/flightrec-winlist-{digest}"
    if binp.is_file():
        return str(binp)
    (root / "target/tools").mkdir(parents=True, exist_ok=True)
    got = subprocess.run(
        ["bash", "-c",
         'source "$1/tools/lib/swift-toolchain.sh" && '
         'kaya_swiftc -O -o "$2" "$3"',
         "_", str(root), str(binp), str(src)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return str(binp) if got.returncode == 0 and binp.is_file() else None


class LaneRecorder:
    """One lane run's recorder. Generic half here; windows half below."""

    def __init__(self, lane, root):
        self.lane = lane
        self.root = pathlib.Path(root)
        self.ok = False
        self.run_id = ""
        self.run_dir = None
        self.spool = None
        # STDOUT ONLY for the id line — stderr carries the retention
        # sentence and must not be folded in (flightrec.sh's N0 lesson).
        try:
            out = subprocess.run(
                [sys.executable, _flightrec(root), "start", lane, str(root)],
                stdout=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", check=False)
        except OSError:
            out = None
        line = out.stdout.strip() if out and out.returncode == 0 else ""
        if not line or "\t" not in line:
            print("flightrec: the journal could not be opened — this run is "
                  "not recorded, but every leg still runs", file=sys.stderr)
            return
        self.run_id, run_dir = line.split("\t", 1)
        self.run_dir = pathlib.Path(run_dir)
        self.spool = self.run_dir / "spool.tsv"
        self.ok = True

    def leg(self, leg, verdict, secs, fail="", bundle=""):
        """One TSV spool line, one O_APPEND write — the pass path."""
        if not self.ok:
            return
        fail = str(fail).replace("\t", " ").replace("\n", " ").replace("\r", " ")
        line = (f"{self.lane}\t{leg}\t{verdict}\t{secs}\t{int(time.time())}"
                f"\t{bundle}\t{fail}\n")
        try:
            fd = os.open(str(self.spool), os.O_WRONLY | os.O_APPEND | os.O_CREAT,
                         0o644)
            try:
                os.write(fd, line.encode("utf-8"))
            finally:
                os.close(fd)
        except OSError:
            return

    def flush(self):
        """Spool -> journal, once; the flush truncates, so the atexit
        call after a normal one is a no-op rather than a double record."""
        if not self.ok or not self.spool.is_file() or not self.spool.stat().st_size:
            return
        try:
            out = subprocess.run(
                [sys.executable, _flightrec(self.root), "flush", self.run_id,
                 str(self.spool)],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                encoding="utf-8", errors="replace",
                check=False)
        except OSError:
            return
        n = out.stdout.strip()
        if n:
            print(f"flightrec: {n} leg record(s) written to "
                  f"{self.run_dir}/journal.jsonl")

    def bundle(self, leg):
        """A bundle directory for a failing leg, or None."""
        if not self.ok:
            return None
        try:
            out = subprocess.run(
                [sys.executable, _flightrec(self.root), "bundle", self.run_id,
                 self.lane, leg],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                encoding="utf-8", errors="replace",
                check=False)
        except OSError:
            return None
        line = out.stdout.strip()
        return pathlib.Path(line) if out.returncode == 0 and line else None

    # ---------------------------------------------------- bundle pieces

    @staticmethod
    def fail_sentence(log_path):
        """The harness's own failure sentence out of a leg log, so the
        journal carries WHY and not merely THAT."""
        p = pathlib.Path(log_path)
        if not p.is_file():
            return ""
        text = p.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if "KAYA_SELFTEST: FAILED" in line:
                return line
        for line in text.splitlines():
            if "KAYA_HARNESS: step-failed" in line:
                return line
        return ""

    @staticmethod
    def mark(bundle, name, state, size):
        try:
            with open(bundle / "MANIFEST", "a", encoding="utf-8") as f:
                f.write(f"{name} {state} {size}\n")
        except OSError:
            return

    def skip(self, bundle, name, why):
        """THE ONE WRITER OF A `.skip` FILE, so no marker can be left
        without a sentence: an empty marker is a diagnostic that cannot
        discriminate (invariant 3), and the windows notes bundle's shot
        marker was measured empty on 2026-09-16. A caller that names no
        reason gets a sentence saying THAT, which is the bug it is."""
        if bundle is None or not bundle.is_dir():
            return
        why = " ".join((why or "").split())
        if not why:
            why = (f"flightrec: section {name} was skipped and the collect "
                   f"path named no reason — that is a bug in the recorder, "
                   f"not something measured about this leg")
        (bundle / f"{name}.skip").write_text(f"{why}\n", encoding="utf-8")
        self.mark(bundle, name, "skip", 0)

    def adopt(self, bundle, name, src, why_absent=""):
        """Take a file a sampler already wrote, under the manifest. An
        absent source is an HONEST SKIP naming itself, never a silently
        missing section (invariant 3)."""
        if bundle is None or not bundle.is_dir():
            return
        src = pathlib.Path(src)
        if not src.is_file():
            self.skip(bundle, name, why_absent or
                      f"flightrec: nothing was sampled for section {name} "
                      f"({src})")
            return
        dest = bundle / f"{name}.txt"
        try:
            dest.write_bytes(src.read_bytes())
        except OSError:
            return
        size = dest.stat().st_size
        self.mark(bundle, name, "ok" if size else "empty", size)

    def adopt_shot(self, bundle, name, src, why_absent="", note_src=None):
        """A PICTURE the leg's own runner took at fail time, adopted by
        BYTES (a .png is not text). `note_src` is a file whose sentence
        says WHEN the picture was taken and what was on screen — it rides
        beside the image as <name>.when, because a photograph nobody can
        date answers a question it was never asked."""
        if bundle is None or not bundle.is_dir():
            return
        src = pathlib.Path(src)
        if not src.is_file() or not src.stat().st_size:
            self.skip(bundle, name, why_absent or
                      f"flightrec: no picture was taken for section {name} "
                      f"({src})")
            return
        dest = bundle / f"{name}.png"
        try:
            dest.write_bytes(src.read_bytes())
        except OSError:
            return
        if note_src is not None and pathlib.Path(note_src).is_file():
            try:
                (bundle / f"{name}.when").write_bytes(
                    pathlib.Path(note_src).read_bytes())
            except OSError:
                pass
        self.mark(bundle, name, "ok", dest.stat().st_size)

    def section(self, bundle, name, argv):
        """One captured command as a bundle section — the shell half's
        flightrec_section, argv-only. An error is marked, never raised
        (the recorder may never cost a lane its legs). A capture tool
        this host does not have leaves a .skip NAMING it, never a
        silently absent section (invariant 3 — flightrec-selftest N2
        watches this fire)."""
        if bundle is None or not bundle.is_dir():
            return
        dest = bundle / f"{name}.txt"
        try:
            with open(dest, "w", encoding="utf-8") as f:
                rc = subprocess.run(argv, stdout=f,
                                    stderr=subprocess.STDOUT,
                                    check=False).returncode
        except FileNotFoundError:
            dest.unlink(missing_ok=True)
            self.skip(bundle, name,
                      f"flightrec: {argv[0]} is not on this host — section "
                      f"{name} could not be captured")
            return
        except OSError:
            rc = 1
        size = dest.stat().st_size if dest.is_file() else 0
        if size > SECTION_CAP:
            data = dest.read_bytes()[:SECTION_CAP]
            dest.write_bytes(data + b"\n... truncated at %d bytes "
                                    b"(flightrec section cap)\n"
                             % SECTION_CAP)
            size = SECTION_CAP
        state = ("error" if rc != 0 else
                 "empty" if size == 0 else "ok")
        self.mark(bundle, name, state, size)

    def finish(self, bundle, out=None):
        """Close a bundle: every section this lane DECLARES (SECTIONS) is
        present or carries a sentence, and the report goes to the leg's
        log. A section the collect path never reached at all is the case
        nobody notices — it looks exactly like a section that was never
        needed — so it is marked here rather than left absent."""
        if bundle is None or not bundle.is_dir():
            return
        have = set()
        manifest = bundle / "MANIFEST"
        if manifest.is_file():
            for line in manifest.read_text(encoding="utf-8").splitlines():
                parts = line.split()
                if parts:
                    have.add(parts[0])
        for name in SECTIONS.get(self.lane, ()):
            if name not in have:
                self.skip(bundle, name,
                          f"flightrec: the {self.lane} lane's collect never "
                          f"reached section {name} on this leg — no branch "
                          f"of it wrote or skipped the section, so nothing "
                          f"here was measured about it")
        self.bundle_report(bundle, out=out)

    def bundle_report(self, bundle, out=None):
        """The counts and the size, PRINTED, AND EVERY SECTION BY NAME
        with its state and a skip's own sentence: a bundle whose sections
        silently stopped being collected looks exactly like one that was
        never needed, and a reader who has to open the directory to learn
        that has already lost the minute this line exists to save. `out`
        is the LEG's log on the runners' pool path — sys.stdout is
        process-global, so a redirect there would cross two concurrently
        failing legs' logs."""
        if bundle is None or not bundle.is_dir():
            return
        out = out if out is not None else sys.stdout
        states = {"ok": 0, "skip": 0, "empty": 0, "error": 0}
        rows = []
        manifest = bundle / "MANIFEST"
        if manifest.is_file():
            for line in manifest.read_text(encoding="utf-8").splitlines():
                parts = line.split()
                if len(parts) >= 2:
                    rows.append((parts[0], parts[1],
                                 parts[2] if len(parts) > 2 else "0"))
                    if parts[1] in states:
                        states[parts[1]] += 1
        size = sum(p.stat().st_size for p in bundle.rglob("*") if p.is_file())
        print(f"flightrec: bundle {bundle} — {len(rows)} sections "
              f"({states['ok']} ok, {states['skip']} skipped, "
              f"{states['empty']} empty, {states['error']} error), "
              f"{size} bytes (cap {BUNDLE_CAP})", file=out)
        for name, state, bytes_ in rows:
            why = ""
            marker = bundle / f"{name}.skip"
            if state == "skip" and marker.is_file():
                why = " ".join(marker.read_text(
                    encoding="utf-8", errors="replace").split())
            print(f"flightrec:   {name} {state} {bytes_}"
                  f"{' — ' + why if why else ''}", file=out)
        if size > BUNDLE_CAP:
            print(f"flightrec: bundle {bundle} is OVER its cap — the section "
                  f"caps did not hold it", file=out)


class WinRecorder(LaneRecorder):
    """The windows half: the guest side is tools/guest/flightrec.ps1 and
    must run in the INTERACTIVE session (schtasks /it) — an ssh session
    is session 0 and can see no desktop. Needs the runner's run_ssh/scp
    (injected via bind); every method is a no-op unbound or un-opened.

    TASK NAMES: the COLLECT is per leg, because two legs can fail at
    once; the SAMPLER is lane-wide, because the foreground is a
    machine-wide property — one poller answers for every leg."""

    def __init__(self, root):
        super().__init__("windows", root)
        self._ssh = None
        self._ssh_out = None
        self._scp_from = None
        self.skew = 0
        # This run's token, on the sampler's command line and in its pid
        # file, so the lane's exit can wait for ITS OWN sampler and tell a
        # leak from a neighbour's (docs/deferred.md, the LEAK entry).
        self.run_token = f"{int(time.time())}-{os.getpid()}"
        self._stopped_clean = False

    def bind(self, run_ssh, run_ssh_out, scp_from):
        """run_ssh(cmd)->rc, run_ssh_out(cmd)->text|None,
        scp_from(remote, local)->bool."""
        self._ssh = run_ssh
        self._ssh_out = run_ssh_out
        self._scp_from = scp_from

    def _ready(self):
        return self.ok and self._ssh is not None

    def lane_start(self):
        """Clear the previous lane's backstop, learn the guest clock,
        start the ONE sampler: three round trips per LANE, where there
        were three per LEG."""
        if not self._ready():
            return
        self._ssh("del C:\\kaya\\flightrec\\ALL.stop "
                  "C:\\kaya\\flightrec\\lane-foreground.txt 2>nul & exit /b 0")
        self.clock_sync()
        self._ssh("schtasks /create /tn kayafr_lane /tr \"wscript "
                  "C:\\kaya\\run-hidden-args.vbs flightrec.cmd sample lane "
                  f"{self.run_token}\" "
                  "/sc once /st 00:00 /it /rl highest /f >nul "
                  "&& schtasks /run /tn kayafr_lane >nul")

    def clock_sync(self):
        """The host-to-guest clock offset, read ONCE per lane. Without
        it the ring is a wall of guest timestamps no leg can be
        attributed to."""
        if not self._ready():
            return
        got = self._ssh_out('powershell -NoProfile -Command '
                            '"[int64](Get-Date -UFormat %s)"') or ""
        got = got.replace("\r", "").replace("\n", "").strip()
        self.skew = int(got) - int(time.time()) if got.isdigit() else 0
        print(f"flightrec: the guest's clock is {self.skew}s from this host's")

    # ---------------------------------------------- the sampler's end --
    # NO `if` IN THE STOP COMMAND. cmd runs everything after an `&` INSIDE
    # the if, so the older
    #   if not exist C:\kaya\flightrec mkdir ... & echo stop > ...ALL.stop
    # wrote the stop file only on a machine where the directory was MISSING
    # -- which it never is -- and the sampler polled to its own 5400s
    # deadline: three matrices, three leaks (docs/deferred.md's LEAK entry;
    # the same trap check-steps' cmd_precedence clause holds, measured
    # again on the VM 2026-09-09).
    STOP_CMD = ("mkdir C:\\kaya\\flightrec 2>nul "
                "& echo stop > C:\\kaya\\flightrec\\ALL.stop & exit /b 0")

    def samplers(self):
        """Every flight-recorder sampler the guest still has, as the
        guest's own lines (`sampler run=<token> pid=<n> ...`), or None
        when the question could not be asked."""
        if not self._ready():
            return None
        out = self._ssh_out(
            "powershell -NoProfile -ExecutionPolicy Bypass -File "
            "C:\\kaya\\flightrec.ps1 -Mode list -Leg lane")
        if out is None:
            return None
        return [ln.strip() for ln in out.replace("\r", "").splitlines()
                if ln.strip()]

    # A sampler whose run cannot be read: `?` is one the process list found
    # with no pid file, `none` one started from a build of flightrec.ps1
    # that predates the token (the runner starts the sampler BEFORE it
    # deploys, so a lane's first run after an edit to that script is always
    # the previous one). At the END of a lane both are leaks: nothing else
    # on this guest starts a flight-recorder sampler.
    UNATTRIBUTED = ("?", "none")

    def mine(self, lines):
        """The rows of a `samplers()` listing THIS lane must answer for:
        its own run, and any sampler nobody can attribute. A row carrying
        another concrete token is a concurrent runner's and is printed
        rather than refused."""
        want = [f"run={self.run_token} "] + [f"run={r} " for r in self.UNATTRIBUTED]
        return [ln for ln in (lines or [])
                if ln.startswith("sampler ")
                and any(w in ln + " " for w in want)]

    def stop_samplers(self, ceiling=40):
        """Drop the stop file and WAIT for this run's sampler to be gone
        (docs/deferred.md's LEAK entry: the remedy is a wait, not a file
        dropped on the way out). Returns the lines of this run's samplers
        that are STILL alive -- empty on the ordinary path."""
        if not self._ready():
            return []
        self._ssh(self.STOP_CMD)
        deadline = time.monotonic() + ceiling
        lines = self.samplers()
        while self.mine(lines) and time.monotonic() < deadline:
            time.sleep(2)
            lines = self.samplers()
        left = self.mine(lines)
        if not left:
            self._stopped_clean = True
            # The task's registration goes with the sampler it started;
            # the next lane_start recreates it. NOT because it would fire
            # again — measured 2026-09-09, a `/sc once` task that has run
            # reads `Next Run Time: N/A` — but so the guest carries no
            # armed task for a run that is over.
            self._ssh("schtasks /delete /tn kayafr_lane /f >nul 2>nul "
                      "& exit /b 0")
        return left

    def lane_end(self, out=None):
        """The verdict gate. The lane may not print a verdict while a
        sampler of its own is still polling the guest: it loads the
        machine the next lane is timed on, and three matrices shipped
        one each. Prints the guest's OWN census either way, and answers
        False when this run left one behind."""
        if not self._ready():
            return True
        out = out if out is not None else sys.stdout
        left = self.stop_samplers()
        lines = self.samplers()
        if lines is None:
            print("flightrec: the guest could not be asked what samplers "
                  "it still has (the ssh transport answered nothing), so "
                  "this lane cannot say it left none", file=out)
            return True
        census = [ln for ln in lines if ln.startswith(("sampler ", "stale "))]
        print(f"flightrec: samplers on the guest after this lane: "
              f"{len(census) if census else 0} listed, "
              f"{len(self.mine(lines))} this lane must answer for "
              f"(run={self.run_token}, plus any unattributed)", file=out)
        for ln in census:
            print(f"  {ln}", file=out)
        if not left:
            return True
        print(f"flightrec: THIS LANE LEFT {len(left)} SAMPLER(S) POLLING on "
              f"the guest -- they load the machine the next lane is timed "
              f"on, and a verdict is refused until they are gone "
              f"(docs/deferred.md, the windows sampler LEAK entry). Kill "
              f"them by the pid above and re-run.", file=out)
        return False

    def cleanup(self):
        """The lane's backstop, from the runner's exit path: no sampler
        outlives the lane and quietly loads the machine the next lane is
        timed on. lane_end() has usually done this already."""
        if not self._ready() or self._stopped_clean:
            return
        left = self.stop_samplers(ceiling=20)
        if left:
            print("flightrec: samplers of this run were STILL polling the "
                  "guest when the lane exited:", file=sys.stderr)
            for ln in left:
                print(f"  {ln}", file=sys.stderr)

    def collect(self, leg):
        """Run the guest-side collection NOW — from the timeout path
        while the guest is STILL ALIVE (the only moment a window, a
        dialog or a stack exists to photograph), or at leg end if that
        never happened."""
        if not self._ready():
            return
        # THE OLD ANSWER GOES FIRST (tools/deploy-win.py's run_guest_oneshot,
        # the same trap): this polls for COLLECTDONE in a file the previous
        # run of this leg left complete, so a second failure of the same leg
        # returned at once with the collect never run and pulled a file nine
        # hours old as this leg's desktop (matrix 27's notes red, 2026-09-16).
        # Every output the collect writes is deleted before the task runs;
        # the verb trace is the guest's own and is not touched.
        outputs = " ".join(f"C:\\kaya\\flightrec\\{leg}-{suffix}"
                           for suffix in ("collect.txt", "shot.png", "desktop.png",
                                          "fgtext.txt", "shotwhy.txt", "wpn.db"))
        self._ssh(f'cmd /c "del {outputs} 2>nul & exit /b 0"')
        self._ssh(f"schtasks /create /tn kayafrc_{leg} /tr \"wscript "
                  f"C:\\kaya\\run-hidden-args.vbs flightrec.cmd collect {leg}\" "
                  f"/sc once /st 00:00 /it /rl highest /f >nul "
                  f"&& schtasks /run /tn kayafrc_{leg} >nul")
        for _ in range(30):
            out = self._ssh_out(f"type C:\\kaya\\flightrec\\{leg}-collect.txt")
            if out and "COLLECTDONE" in out:
                break
            time.sleep(2)
        self._ssh(f"schtasks /delete /tn kayafrc_{leg} /f >nul 2>nul "
                  f"& exit /b 0")

    def pull(self, bundle, leg, suffix, section, dest_name, why=""):
        if bundle is None:
            return
        dest = bundle / dest_name
        got = self._scp_from(f"C:/kaya/flightrec/{leg}-{suffix}", dest)
        if not got or not dest.is_file() or not dest.stat().st_size:
            if dest.is_file():
                dest.unlink()
            self.skip(bundle, section, why or
                      f"flightrec: the guest wrote no {section} for this leg "
                      f"(C:\\kaya\\flightrec\\{leg}-{suffix})")
            return
        self.mark(bundle, section, "ok", dest.stat().st_size)

    def shot_reasons(self, bundle, leg):
        """The two pictures' own sentences, out of the guest's
        `<leg>-shotwhy.txt` (flightrec.ps1 writes one line per picture,
        saved or not). The host cannot know why a shot was not taken, so
        the guest measures and this carries it into the skip."""
        if bundle is None:
            return {}
        tmp = bundle / "shotwhy.tmp"
        got = self._scp_from(f"C:/kaya/flightrec/{leg}-shotwhy.txt", tmp)
        reasons = {}
        if got and tmp.is_file():
            for line in tmp.read_text(encoding="utf-8",
                                      errors="replace").splitlines():
                if ":" in line:
                    key, text = line.split(":", 1)
                    reasons[key.strip()] = text.strip()
            tmp.unlink()
        return reasons

    def foreground(self, bundle, t0):
        """The lane-wide foreground ring with THIS leg's window named at
        the top: the ring is machine-wide and shared by every concurrent
        leg, so a reader needs to be told which lines are theirs."""
        if bundle is None:
            return
        ring = bundle / "foreground.txt.ring"
        got = self._scp_from("C:/kaya/flightrec/lane-foreground.txt", ring)
        if not got or not ring.is_file() or not ring.stat().st_size:
            if ring.is_file():
                ring.unlink()
            self.skip(bundle, "foreground",
                      "flightrec: the lane sampler wrote no ring "
                      "(C:\\kaya\\flightrec\\lane-foreground.txt) — it did "
                      "not start, or the desktop never changed hands")
            return
        dest = bundle / "foreground.txt"
        now = int(time.time())
        head = (f"flightrec: this leg ran {t0 + self.skew}..{now + self.skew} "
                f"in GUEST epoch seconds (host {t0}..{now}, guest clock "
                f"{self.skew}s off).\n"
                f"flightrec: the ring below is LANE-WIDE — every leg that ran "
                f"concurrently is in it.\n")
        dest.write_text(head + ring.read_text(encoding="utf-8",
                                              errors="replace"),
                        encoding="utf-8")
        ring.unlink()
        self.mark(bundle, "foreground", "ok", dest.stat().st_size)

    def desktop_live(self, bundle, t0):
        ring = bundle / "foreground.txt"
        if not ring.is_file():
            self.skip(bundle, "desktop-live",
                      "flightrec: no foreground ring was pulled, so no toast "
                      "grab could be named for this leg")
            return
        lo, hi = t0 + self.skew, int(time.time()) + self.skew
        newest = None
        for line in ring.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r"at=(\d+) .*toastshot=(lane-toast-\d+\.png)", line)
            if m and lo <= int(m.group(1)) <= hi:
                newest = (int(m.group(1)), m.group(2), line)
        if newest is None:
            self.skip(bundle, "desktop-live",
                      "flightrec: the lane sampler saw no toast hold the "
                      "foreground during this leg, so there was no moment "
                      "to photograph")
            return
        dest = bundle / "desktop-live.png"
        got = self._scp_from(f"C:/kaya/flightrec/{newest[1]}", dest)
        if not got or not dest.is_file() or not dest.stat().st_size:
            if dest.is_file():
                dest.unlink()
            self.skip(bundle, "desktop-live",
                      f"flightrec: the sampler named {newest[1]} for a toast "
                      f"at guest epoch {newest[0]} but the file was gone by "
                      f"collect (the ring keeps six)")
            return
        (bundle / "desktop-live.when").write_text(newest[2] + "\n", encoding="utf-8")
        self.mark(bundle, "desktop-live", "ok", dest.stat().st_size)

    @staticmethod
    def _drop_db(db):
        """The copy AND the two files sqlite makes beside it. A read-only
        connection to a WAL database leaves `-shm` and `-wal` behind on
        close, and a bundle carrying two binary strays is a bundle whose
        reader wonders what they are (measured 2026-09-17)."""
        for stray in (db, pathlib.Path(f"{db}-wal"), pathlib.Path(f"{db}-shm")):
            if stray.is_file():
                stray.unlink()

    def render_wpn(self, db, since=None):
        """The platform's notification database as text, newest first —
        ONE reader for the two sections that copy that file (the collect's
        `notifications` and the guest's own `toast-moment`), because a
        second copy of the FILETIME arithmetic and the payload's XML would
        drift out of step with the first.

        Each row: the arrival time (UTC), the type, the sender's AUMID out
        of NotificationHandler.PrimaryId, its display name where
        HandlerAssets carries one (it is empty on the lane's VM, so most
        rows have none), and the toast's own text out of its XML payload.
        `since` is a GUEST epoch second: a row at or after it is marked as
        having arrived inside the leg."""
        import sqlite3
        import datetime
        lines = []
        try:
            con = sqlite3.connect(f"{pathlib.Path(db).as_uri()}?mode=ro", uri=True)
            cur = con.cursor()
            handlers = {r[0]: r[1] for r in
                        cur.execute("select RecordId, PrimaryId from NotificationHandler")}
            names = {}
            try:
                for hid, key, value in cur.execute(
                        "select HandlerId, AssetKey, AssetValue from HandlerAssets"):
                    if value and "name" in str(key).lower():
                        names[hid] = str(value)
            except sqlite3.Error as e:
                lines.append(f"flightrec: no display names — HandlerAssets "
                             f"would not be read: {e}")
            rows = cur.execute("select HandlerId, Type, ArrivalTime, Payload from "
                               "Notification order by ArrivalTime desc limit 40")
            for hid, typ, at, payload in rows:
                when = datetime.datetime(1601, 1, 1) + datetime.timedelta(microseconds=at / 10)
                text = ""
                if payload:
                    s = payload.decode("utf-8", "replace") if isinstance(payload, bytes) else str(payload)
                    text = " | ".join(re.findall(r"<text[^>]*>([^<]{1,120})</text>", s))[:240]
                # FILETIME is 100ns ticks from 1601; the guest epoch this is
                # compared against is seconds from 1970.
                inside = (since is not None
                          and at / 10_000_000 - 11644473600 >= since)
                who = handlers.get(hid, hid)
                if hid in names:
                    who = f"{who} ({names[hid]})"
                lines.append(f"{when:%Y-%m-%d %H:%M:%S}Z {typ:<6} {who} {text}"
                             f"{'   <- ARRIVED INSIDE THIS LEG' if inside else ''}")
            con.close()
        except Exception as e:  # noqa: BLE001 — the section says what it could not read
            lines.append(f"flightrec: the notification database would not render: {e}")
        return lines

    def notifications(self, bundle, leg):
        db = bundle / "notifications.db"
        got = self._scp_from(f"C:/kaya/flightrec/{leg}-wpn.db", db)
        if not got or not db.is_file() or not db.stat().st_size:
            if db.is_file():
                db.unlink()
            self.skip(bundle, "notifications",
                      "flightrec: the collect copied no notification database "
                      f"(C:\\kaya\\flightrec\\{leg}-wpn.db); its own "
                      "sentence is in desktop.txt under '== notifications =='")
            return
        lines = self.render_wpn(db)
        self._drop_db(db)
        head = ("flightrec: the platform's notification database at collect, newest first "
                "(UTC) — only what is still in the Action Center; a banner that closed "
                "and was not kept is not here, which is what desktop-live is for.\n")
        (bundle / "notifications.txt").write_text(head + "\n".join(lines) + "\n",
                                                  encoding="utf-8")
        self.mark(bundle, "notifications", "ok", (bundle / "notifications.txt").stat().st_size)

    def toast_moment(self, bundle, leg, t0):
        """THE RECORDS TAKEN WHILE THE BANNER WAS STILL UP. Five bundles
        in three days named the toast's CLASS and never its SENDER
        (docs/deferred.md, the notes_rust toast entry): the collect's
        database copy is taken after the banner closed and the lane
        sampler's sights of it fall outside the leg. The guest's own
        foreground wait copies the database — WITH ITS WAL, where the
        newest row lives — and grabs the screen the first moment it sees a
        toast (crates/kaya/src/winui/mod.rs, capture_toast_moment), and
        this renders both."""
        if bundle is None:
            return
        db = bundle / "toast-moment.db"
        bmp = bundle / "toast-moment.bmp"
        got_db = self._scp_from(f"C:/kaya/flightrec/{leg}-toastwpn.db", db)
        got_bmp = self._scp_from(f"C:/kaya/flightrec/{leg}-toast.bmp", bmp)
        have_db = bool(got_db) and db.is_file() and db.stat().st_size
        have_bmp = bool(got_bmp) and bmp.is_file() and bmp.stat().st_size
        if not have_db and not have_bmp:
            for stale in (db, bmp):
                if stale.is_file():
                    stale.unlink()
            self.skip(bundle, "toast-moment",
                      "flightrec: the guest's own wait saw no toast during "
                      "this leg, so it wrote neither record "
                      f"(C:\\kaya\\flightrec\\{leg}-toastwpn.db, "
                      f"{leg}-toast.bmp). The foreground at failure is in "
                      "foreground-text; a leg that never reached the type "
                      "verb never looked")
            return
        head = [f"flightrec: what the GUEST saw the first moment a toast held "
                f"the foreground during {leg}, taken by its own wait — not at "
                f"collect, by which time the banner has closed. The leg began "
                f"at guest epoch {t0 + self.skew}."]
        lines = []
        if have_db:
            # THE WAL CARRIES THE NEWEST ROWS and the banner's row is the
            # newest there is; sqlite recovers it only under this name.
            self._scp_from(f"C:/kaya/flightrec/{leg}-toastwpn.db-wal",
                           bundle / "toast-moment.db-wal")
            lines = self.render_wpn(db, since=t0 + self.skew)
        else:
            head.append("flightrec: the guest wrote no database copy at that "
                        "moment; its own sentence is in the leg log and the "
                        "verb trace.")
        if have_bmp:
            png = bundle / "toast-moment.png"
            got = subprocess.run(["sips", "-s", "format", "png", str(bmp),
                                  "--out", str(png)],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL,
                                 check=False).returncode
            if got == 0 and png.is_file() and png.stat().st_size:
                head.append(f"flightrec: the desktop at that moment is beside "
                            f"this file as toast-moment.png "
                            f"({png.stat().st_size} bytes).")
                bmp.unlink()
            else:
                head.append(f"flightrec: `sips -s format png` would not "
                            f"convert the guest's BMP (rc {got}), so the "
                            f"picture stays beside this file as "
                            f"toast-moment.bmp ({bmp.stat().st_size} bytes).")
        else:
            head.append("flightrec: the guest wrote no picture at that "
                        "moment; its own sentence is in the leg log and the "
                        "verb trace.")
        self._drop_db(db)
        (bundle / "toast-moment.txt").write_text(
            "\n".join(head) + "\n" + "\n".join(lines) + "\n", encoding="utf-8")
        size = sum(p.stat().st_size for p in bundle.glob("toast-moment.*")
                   if p.is_file())
        self.mark(bundle, "toast-moment", "ok", size)

    def win_leg(self, leg, verdict, secs, log, collected_already, t0,
                out=None):
        """The one per-leg entry point. A PASS RETURNS AFTER ONE spool
        write; everything below the verdict test is the failure path —
        no bundle scaffolded, no ssh spoken when a leg passes."""
        if not self.ok:
            return
        bundle, fail = None, ""
        if verdict != "PASS":
            bundle = self.bundle(leg)
            fail = self.fail_sentence(log)
            if bundle is not None:
                # The guest has already exited on the ordinary failure
                # path, so this second collect answers only the
                # retrospective questions; the live one, if it happened,
                # already wrote the file this overwrites.
                if not collected_already:
                    self.collect(leg)
                self.adopt(bundle, "leg-log", log)
                self.foreground(bundle, t0)
                self.pull(bundle, leg, "collect.txt", "desktop", "desktop.txt")
                why = self.shot_reasons(bundle, leg)
                self.pull(bundle, leg, "shot.png", "shot", "shot.png",
                          why=why.get("shot", ""))
                # THE DESKTOP, not the guest's window: a toast belongs to
                # another process and PrintWindow photographs one handle,
                # so the picture that names WHOSE banner is covering the
                # app is a console-session grab (docs/traps.md).
                self.pull(bundle, leg, "desktop.png", "desktop-shot",
                          "desktop-shot.png", why=why.get("desktop-shot", ""))
                self.pull(bundle, leg, "fgtext.txt", "foreground-text",
                          "foreground-text.txt")
                # THE PICTURE AT THE MOMENT: the sampler grabs the screen the
                # first time a toast holds the foreground and names the file
                # on its ring line; the newest grab inside this leg's window
                # is the banner the collect-time grab has already lost.
                self.desktop_live(bundle, t0)
                # WHOSE toast, in the platform's own words: the notification
                # database the collect copied, rendered here.
                self.notifications(bundle, leg)
                # AND THE SAME QUESTION ASKED WHILE THE BANNER WAS STILL UP,
                # by the only reader standing there — the guest's own
                # foreground wait.
                self.toast_moment(bundle, leg, t0)
                # The Rust verb trace (crates/kaya/src/vtrace.rs), dumped by
                # the guest on a failed verdict to the file its launcher
                # names (since 2026-09-07; check-steps holds the line).
                self.pull(bundle, leg, "vtrace.txt", "verb-trace",
                          "verb-trace.txt",
                          why="flightrec: the guest wrote no verb trace "
                              "(C:\\kaya\\flightrec\\" + leg + "-vtrace.txt). "
                              "The ring is dumped by the harness on a FAILED "
                              "verdict and by the step watchdog, so a leg "
                              "that was killed before either — a timeout, a "
                              "wedge, a crash — leaves none")
                self.finish(bundle, out=out)
        self.leg(leg, verdict, secs, fail, str(bundle) if bundle else "")


class IosRecorder(LaneRecorder):
    """The iOS half. EVERYTHING FROM THE DEVICE IS TAKEN AT FAIL TIME BY
    THE RUNNER, beside the leg's log, and adopted here: this runs in
    drain(), after the leg released its simulator, where another leg may
    already be driving that device — a picture taken here would be of
    somebody else's scene."""

    def __init__(self, root):
        super().__init__("ios", root)

    VTRACE_ABSENT = (
        "flightrec: the app's container held no verb-trace file for this "
        "leg. The ring is written on a FAILED verdict and by the step "
        "watchdog, so a leg the runner judged failed for its own reason "
        "(no verdict at all, a wedged launch, act one's door) leaves none")
    SHOT_ABSENT = (
        "flightrec: `simctl io <udid> screenshot` took nothing for this leg "
        "— the runner reached the fail path with no device in hand, or the "
        "call failed; run-sim.py's own log line beside the verdict says "
        "which")

    def ios_leg(self, leg, verdict, secs, log, out=None):
        """The one per-leg entry point: the journal takes every leg,
        pass or fail; the bundle is collected on a failure alone."""
        if not self.ok:
            return
        bundle, fail = None, ""
        if verdict != "PASS":
            bundle = self.bundle(leg)
            fail = self.fail_sentence(log)
            if bundle is not None:
                log = pathlib.Path(log)
                self.adopt(bundle, "leg-log", log)
                # Pulled out of the app's own container by the runner at
                # fail time, beside the log: the interpreter's verb trace
                # and the core's panic log (crates/kaya/src/vtrace.rs,
                # fault.rs's KAYA_PANIC_LOG).
                self.adopt(bundle, "verb-trace", log.with_suffix(".vtrace"),
                           why_absent=self.VTRACE_ABSENT)
                self.adopt(bundle, "panic", log.with_suffix(".panic"),
                           why_absent="flightrec: the core wrote no panic "
                                      "log for this leg (fault.rs's "
                                      "KAYA_PANIC_LOG) — nothing panicked")
                self.adopt(bundle, "app-log", log.with_suffix(".applog"),
                           why_absent="flightrec: no `simctl spawn … log "
                                      "show` slice was kept for this leg")
                self.adopt_shot(bundle, "shot", log.with_suffix(".shot.png"),
                                why_absent=self.SHOT_ABSENT,
                                note_src=log.with_suffix(".shotwhen"))
                self.section(bundle, "devices",
                             ["xcrun", "simctl", "list", "devices",
                              "booted"])
                self.finish(bundle, out=out)
        self.leg(leg, verdict, secs, fail, str(bundle) if bundle else "")


class AndroidRecorder(LaneRecorder):
    """The android half: the failure-path bundle is the leg's own log
    plus the adb device roster — an android leg that failed because its
    emulator went offline reads exactly like one that failed an
    assertion, and only the roster tells them apart."""

    def __init__(self, root):
        super().__init__("android", root)

    VTRACE_ABSENT = (
        "flightrec: `run-as <package> cat files/verb-trace-<leg>.txt` came "
        "back empty. The ring is written on a FAILED verdict and by the "
        "step watchdog, so a leg with no verdict at all — a launch that "
        "never mounted, a process the system killed — leaves none")
    SHOT_ABSENT = (
        "flightrec: `adb exec-out screencap -p` took nothing for this leg — "
        "the device was gone by the fail path, or the call failed; the leg "
        "log's own screencap line says which")

    def android_leg(self, leg, verdict, secs, log, out=None):
        """The one per-leg entry point: the journal takes every leg,
        pass or fail; the bundle is collected on a failure alone. The
        device-side captures are the runner's, taken at fail time while
        the emulator is still this leg's (the pool hands it on in
        drain)."""
        if not self.ok:
            return
        bundle, fail = None, ""
        if verdict != "PASS":
            bundle = self.bundle(leg)
            fail = self.fail_sentence(log)
            if bundle is not None:
                log = pathlib.Path(log)
                self.adopt(bundle, "leg-log", log)
                # Pulled out of the app's private files dir by the runner
                # (run-as) at fail time, beside the log.
                self.adopt(bundle, "verb-trace", log.with_suffix(".vtrace"),
                           why_absent=self.VTRACE_ABSENT)
                self.adopt(bundle, "logcat", log.with_suffix(".logcat"),
                           why_absent="flightrec: no logcat tail was kept "
                                      "for this leg")
                self.adopt_shot(bundle, "shot", log.with_suffix(".shot.png"),
                                why_absent=self.SHOT_ABSENT,
                                note_src=log.with_suffix(".shotwhen"))
                self.section(bundle, "devices", ["adb", "devices", "-l"])
                self.finish(bundle, out=out)
        self.leg(leg, verdict, secs, fail, str(bundle) if bundle else "")


class MacRecorder(LaneRecorder):
    """The mac half, crossed from tools/lib/flightrec.sh's mac-only
    functions with the runner conversion: a per-leg SAMPLER thread
    (cheap lines every 2s, ONE expensive `sample` plus a window shot
    taken while the guest is STILL ALIVE, just before the runner's
    120s kill lands), and the at-fail capture — sampler history,
    sample, leg log, WindowServer load, the guest's OWN window by id
    (never a full-screen grab and never a title match: both
    photographed the wrong thing once; docs/traps.md), and the
    bounded unified log."""

    def __init__(self, root):
        super().__init__("mac", root)
        self._winlist = None
        self._winlist_tried = False

    # ---- process genealogy: the guest is `timeout`'s descendant ----
    @classmethod
    def _descendants(cls, pid):
        out = []
        got = subprocess.run(["pgrep", "-P", str(pid)],
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True,
                             encoding="utf-8", errors="replace",
                             check=False)
        for kid in got.stdout.split():
            out.append(kid)
            out.extend(cls._descendants(kid))
        return out

    @staticmethod
    def _comm(pid):
        got = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)],
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True,
                             encoding="utf-8", errors="replace",
                             check=False)
        return pathlib.Path(got.stdout.strip()).name

    def guest_pid(self, root_pid):
        """ANCHORED ON `timeout`, not on a blocklist: both leg paths
        run the guest as `timeout 120 <guest>`, so the guest is
        timeout's descendant and nothing else is (a blocklist once
        profiled TEE for two seconds; the wrong-process shot exposed
        it). The ROOT ITSELF is the usual anchor here — the runner
        hands the sampler the `timeout` Popen directly, where the
        shell handed it a leg subshell with timeout underneath; the
        first live bundle had guest_pid=none for the leg's whole life
        because this walked only descendants
        (docs/measurements/validate-mac-conversion-2026-09-01.md)."""
        best = ""
        anchors = [str(root_pid)] if self._comm(root_pid) == "timeout" \
            else []
        for pid in self._descendants(root_pid):
            if self._comm(pid) == "timeout":
                anchors.append(pid)
        for anchor in anchors:
            for kid in self._descendants(anchor):
                if self._comm(kid) not in ("env", "sh", "bash", ""):
                    best = kid
        return best

    # ---- the window list binary, content-hashed like the shell's ----
    def winlist_bin(self):
        if self._winlist_tried:
            return self._winlist
        self._winlist_tried = True
        self._winlist = winlist_bin(self.root)
        return self._winlist

    def shot_pid(self, pid, dest, at=None):
        """ONE window, the GUEST'S OWN, addressed by pid -> window id.
        No pid or no window means no shot and a sentence saying why —
        never a full-screen grab."""
        if not shutil.which("screencapture"):
            return False
        winlist = self.winlist_bin()
        if not winlist:
            return False
        got = subprocess.run([winlist, str(pid)],
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True,
                             encoding="utf-8", errors="replace",
                             check=False)
        win = ""
        for line in got.stdout.splitlines():
            if "layer=0 " in line:
                for tok in line.split():
                    if tok.startswith("win="):
                        win = tok[4:]
                break
        if not win or win == "-1":
            return False
        subprocess.run(["screencapture", "-x", "-o", f"-l{win}",
                        str(dest)], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)
        dest = pathlib.Path(dest)
        if not dest.is_file() or not dest.stat().st_size:
            return False
        if at is not None:
            pathlib.Path(str(dest) + ".when").write_text(
                f"taken at t={at}s, window {win} of pid {pid}\n",
                encoding="utf-8")
        return True

    # ---- the per-leg sampler, a thread over the guest's Popen ----
    def sampler_start(self, scratch, proc):
        """Cheap lines every 2s while the leg's `timeout` process
        lives; ONE `sample` + live shot at KAYA_FLIGHTREC_SAMPLE_AT
        (default 100s), while the guest can still answer. Returns a
        handle for sampler_stop — EVERY CALLER MUST STOP IT."""
        if not self.ok:
            return None
        scratch = pathlib.Path(scratch)
        scratch.mkdir(parents=True, exist_ok=True)
        stop = threading.Event()

        def loop():
            at, sampled, gpid, gcomm = 0, False, "", ""
            hang_at = int(os.environ.get("KAYA_FLIGHTREC_SAMPLE_AT",
                                         "100"))
            while at < 130 and proc.poll() is None \
                    and not stop.is_set():
                if not gpid or self._comm(gpid) == "":
                    gpid = self.guest_pid(proc.pid)
                    gcomm = ""
                ws = ""
                got = subprocess.run(["ps", "-Ao", "pcpu=,comm="],
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL,
                                     text=True, encoding="utf-8",
                                     errors="replace", check=False)
                for line in got.stdout.splitlines():
                    if "WindowServer" in line:
                        ws = " ".join(line.split())
                        break
                if gpid and not gcomm:
                    gcomm = self._comm(gpid)
                with open(scratch / "sampler.txt", "a",
                          encoding="utf-8") as f:
                    f.write(f"t={at}s guest_pid={gpid or 'none'} "
                            f"guest={gcomm or 'none'} "
                            f"windowserver=[{ws}]\n")
                if gpid and at >= hang_at and not sampled:
                    sampled = True
                    # THE SHOT COMES FIRST (measured): it is
                    # instantaneous where `sample` blocks for its two
                    # seconds, and the window is what vanishes.
                    self.shot_pid(gpid, scratch / "shot-live.png", at)
                    got = subprocess.run(
                        ["sample", str(gpid), "2"],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, text=True,
                        encoding="utf-8", errors="replace",
                        check=False)
                    with open(scratch / "sample.txt", "a",
                              encoding="utf-8") as f:
                        f.write(f"== sample {gpid} 2, taken at "
                                f"t={at}s while the guest was STILL "
                                f"ALIVE\n== (the runner's timeout "
                                f"kill lands at 120s and would take "
                                f"it with it)\n")
                        f.write(got.stdout)
                stop.wait(2)
                at += 2
            with open(scratch / "sampler.txt", "a",
                      encoding="utf-8") as f:
                f.write(f"sampler: stopped at t={at}s (sample taken: "
                        f"{1 if sampled else 0})\n")

        t = threading.Thread(target=loop, daemon=True)
        t.start()
        return (t, stop)

    @staticmethod
    def sampler_stop(handle):
        if handle is None:
            return
        t, stop = handle
        stop.set()
        t.join(timeout=10)

    def _text_section(self, bundle, name, text):
        dest = bundle / f"{name}.txt"
        dest.write_text(text, encoding="utf-8")
        self.mark(bundle, name, "ok", dest.stat().st_size)

    def shot_desktop(self, dest):
        """THE WHOLE SCREEN, the one picture that can show what is
        covering the guest. Never the `shot` section — that one is the
        guest's own window by id, and a full-screen grab standing in for
        it photographed the wrong thing twice (docs/traps.md). This is
        its own section, taken only when the guest had no window."""
        if not shutil.which("screencapture"):
            return False
        subprocess.run(["screencapture", "-x", "-o", str(dest)],
                       stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)
        dest = pathlib.Path(dest)
        return dest.is_file() and dest.stat().st_size > 0

    def _shot(self, bundle, scratch):
        """The fail-time attempt first; the sampler's live shot is
        what answers when the guest is already gone (an assertion
        failure exits at once); the DESKTOP answers when neither did,
        which is the case the old skip sentence could only describe."""
        pid = ""
        sampler = scratch / "sampler.txt"
        if sampler.is_file():
            for line in sampler.read_text(encoding="utf-8",
                                          errors="replace").splitlines():
                for tok in line.split():
                    if tok.startswith("guest_pid=") \
                            and tok[10:].isdigit():
                        pid = tok[10:]
        if pid and self.shot_pid(pid, bundle / "shot.png"):
            self.mark(bundle, "shot", "ok",
                      (bundle / "shot.png").stat().st_size)
            self.skip(bundle, "desktop-shot",
                      f"flightrec: guest pid {pid} still owned its window "
                      f"at failure and the `shot` section beside this file "
                      f"is that window — nothing was covering it to "
                      f"photograph")
            return
        (bundle / "shot.png").unlink(missing_ok=True)
        live = scratch / "shot-live.png"
        if live.is_file() and live.stat().st_size:
            shutil.copy2(live, bundle / "shot.png")
            when = scratch / "shot-live.png.when"
            if when.is_file():
                shutil.copy2(when, bundle / "shot.when")
            self.mark(bundle, "shot", "ok",
                      (bundle / "shot.png").stat().st_size)
            self.skip(bundle, "desktop-shot",
                      "flightrec: the `shot` section beside this file is the "
                      "guest's own window, photographed by the sampler while "
                      "the leg was still running")
            return
        if not pid:
            self.skip(bundle, "shot",
                      "flightrec: the sampler never resolved a guest pid "
                      "for this leg, so no window is attributed to the "
                      "guest and none was photographed. The window list "
                      "beside this file is the whole desktop, and the "
                      "desktop-shot section is its picture.")
        else:
            self.skip(bundle, "shot",
                      f"flightrec: guest pid {pid} owned no on-screen "
                      f"window at failure and the sampler took none while "
                      f"it lived — the leg failed faster than the "
                      f"sampler's first shot. The window list beside this "
                      f"file is what was there, and the desktop-shot "
                      f"section is its picture.")
        # THE DESKTOP IS THE ANSWER TO "THEN WHAT WAS ON SCREEN?" — the
        # mac's own skip sentence has named that case since the recorder
        # landed and never answered it.
        if self.shot_desktop(bundle / "desktop-shot.png"):
            self.mark(bundle, "desktop-shot", "ok",
                      (bundle / "desktop-shot.png").stat().st_size)
        else:
            (bundle / "desktop-shot.png").unlink(missing_ok=True)
            self.skip(bundle, "desktop-shot",
                      "flightrec: `screencapture -x -o` took no picture of "
                      "the desktop — it is not on this host, or the screen "
                      "recording permission this lane's window shots also "
                      "need was refused")

    def _capture(self, bundle, log, scratch, out=None):
        scratch = pathlib.Path(scratch)
        self.adopt(bundle, "sampler", scratch / "sampler.txt",
                   why_absent="flightrec: the per-leg sampler thread wrote "
                              "no line at all — it never started, or the "
                              "leg was over before its first 2s turn")
        self.adopt(bundle, "sample", scratch / "sample.txt",
                   why_absent="flightrec: no `sample` was taken — the leg "
                              "ended before KAYA_FLIGHTREC_SAMPLE_AT "
                              "(default 100s), which is the only moment the "
                              "guest is both alive and worth a stack")
        self.adopt(bundle, "verb-trace", scratch / "verb-trace.txt",
                   why_absent="flightrec: the guest wrote no verb trace. "
                              "The ring is dumped by the harness on a FAILED "
                              "verdict and by the step watchdog, so a leg "
                              "killed before either — the runner's `timeout "
                              "120`, a crash, act one's own refusal — leaves "
                              "none")
        if log and pathlib.Path(log).is_file():
            self.adopt(bundle, "leg-log", log)
        else:
            self.skip(bundle, "leg-log",
                      "flightrec: this leg streamed to the terminal "
                      "(KAYA_JOBS=1), so there is no log file to keep")
        got = subprocess.run(["ps", "-Ao", "pid=,pcpu=,pmem=,comm="],
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True,
                             encoding="utf-8", errors="replace",
                             check=False)
        wanted = [line for line in got.stdout.splitlines()
                  if "WindowServer" in line or "loginwindow" in line]
        self._text_section(bundle, "windowserver",
                           "\n".join(wanted) + "\n")
        winlist = self.winlist_bin()
        if winlist:
            self.section(bundle, "windows", [winlist])
            self._shot(bundle, scratch)
        else:
            no_list = ("flightrec: no swiftc, or "
                       "tools/mac/flightrec-winlist.swift would not build — "
                       "no window list, and a window shot is addressed BY ID "
                       "out of that list, so there is no guest window shot "
                       "either")
            self.skip(bundle, "windows", no_list)
            self.skip(bundle, "shot", no_list)
            if self.shot_desktop(bundle / "desktop-shot.png"):
                self.mark(bundle, "desktop-shot", "ok",
                          (bundle / "desktop-shot.png").stat().st_size)
            else:
                (bundle / "desktop-shot.png").unlink(missing_ok=True)
                self.skip(bundle, "desktop-shot",
                          "flightrec: the window list would not build AND "
                          "`screencapture -x -o` took no picture — this "
                          "bundle has no image of any kind")
        self.section(bundle, "unified-log", [
            "log", "show", "--last", "2m", "--style", "compact",
            "--predicate",
            'process CONTAINS "kaya" OR senderImagePath CONTAINS '
            '"kaya" OR eventMessage CONTAINS "kaya"'])
        self.finish(bundle, out=out)

    def mac_leg(self, leg, verdict, secs, log, scratch, out=None):
        """The one per-leg entry point every leg path calls, so the
        serial and pooled paths cannot record different things. The
        journal takes every leg; the capture is collected on a
        failure alone, and the scratch dies either way."""
        if not self.ok:
            return
        bundle, fail = None, ""
        if verdict != "PASS":
            bundle = self.bundle(leg)
            fail = self.fail_sentence(log) if log else ""
            if bundle is not None:
                self._capture(bundle, log, scratch, out=out)
        self.leg(leg, verdict, secs, fail, str(bundle) if bundle else "")
        shutil.rmtree(scratch, ignore_errors=True)
