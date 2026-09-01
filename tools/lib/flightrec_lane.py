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
import time

SECTION_CAP = int(os.environ.get("KAYA_FLIGHTREC_SECTION_CAP", "2097152"))
BUNDLE_CAP = int(os.environ.get("KAYA_FLIGHTREC_BUNDLE_CAP", "33554432"))


def _flightrec(root):
    return str(pathlib.Path(root) / "tools" / "lib" / "flightrec.py")


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

    def adopt(self, bundle, name, src):
        """Take a file a sampler already wrote, under the manifest. An
        absent source is an HONEST SKIP naming itself, never a silently
        missing section (invariant 3)."""
        if bundle is None or not bundle.is_dir():
            return
        src = pathlib.Path(src)
        if not src.is_file():
            (bundle / f"{name}.skip").write_text(
                f"flightrec: nothing was sampled for section {name}\n",
                encoding="utf-8")
            self.mark(bundle, name, "skip", 0)
            return
        dest = bundle / f"{name}.txt"
        try:
            dest.write_bytes(src.read_bytes())
        except OSError:
            return
        size = dest.stat().st_size
        self.mark(bundle, name, "ok" if size else "empty", size)

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
            (bundle / f"{name}.skip").write_text(
                f"flightrec: {argv[0]} is not on this host — section "
                f"{name} could not be captured\n", encoding="utf-8")
            self.mark(bundle, name, "skip", 0)
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

    def bundle_report(self, bundle, out=None):
        """The counts and the size, PRINTED: a bundle whose sections
        silently stopped being collected looks exactly like one that was
        never needed. `out` is the LEG's log on the runners' pool path —
        sys.stdout is process-global, so a redirect there would cross
        two concurrently failing legs' logs."""
        if bundle is None or not bundle.is_dir():
            return
        out = out if out is not None else sys.stdout
        states = {"ok": 0, "skip": 0, "empty": 0, "error": 0}
        total = 0
        manifest = bundle / "MANIFEST"
        if manifest.is_file():
            for line in manifest.read_text(encoding="utf-8").splitlines():
                parts = line.split()
                if len(parts) >= 2:
                    total += 1
                    if parts[1] in states:
                        states[parts[1]] += 1
        size = sum(p.stat().st_size for p in bundle.rglob("*") if p.is_file())
        print(f"flightrec: bundle {bundle} — {total} sections "
              f"({states['ok']} ok, {states['skip']} skipped, "
              f"{states['empty']} empty, {states['error']} error), "
              f"{size} bytes (cap {BUNDLE_CAP})", file=out)
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
                  "C:\\kaya\\run-hidden-args.vbs flightrec.cmd sample lane\" "
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

    def cleanup(self):
        """The lane's backstop, from the runner's exit path: no sampler
        outlives the lane and quietly loads the machine the next lane is
        timed on."""
        if not self._ready():
            return
        self._ssh("if not exist C:\\kaya\\flightrec mkdir C:\\kaya\\flightrec "
                  ">nul 2>nul & echo stop > C:\\kaya\\flightrec\\ALL.stop "
                  "& exit /b 0")

    def collect(self, leg):
        """Run the guest-side collection NOW — from the timeout path
        while the guest is STILL ALIVE (the only moment a window, a
        dialog or a stack exists to photograph), or at leg end if that
        never happened."""
        if not self._ready():
            return
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

    def pull(self, bundle, leg, suffix, section, dest_name):
        if bundle is None:
            return
        dest = bundle / dest_name
        got = self._scp_from(f"C:/kaya/flightrec/{leg}-{suffix}", dest)
        if not got or not dest.is_file() or not dest.stat().st_size:
            if dest.is_file():
                dest.unlink()
            (bundle / f"{section}.skip").write_text(
                f"flightrec: the guest wrote no {section} for this leg "
                f"(C:\\kaya\\flightrec\\{leg}-{suffix})\n", encoding="utf-8")
            self.mark(bundle, section, "skip", 0)
            return
        self.mark(bundle, section, "ok", dest.stat().st_size)

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
            (bundle / "foreground.skip").write_text(
                "flightrec: the lane sampler wrote no ring "
                "(C:\\kaya\\flightrec\\lane-foreground.txt) — it did not "
                "start, or the desktop never changed hands\n",
                encoding="utf-8")
            self.mark(bundle, "foreground", "skip", 0)
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
                self.pull(bundle, leg, "shot.png", "shot", "shot.png")
                self.bundle_report(bundle, out=out)
        self.leg(leg, verdict, secs, fail, str(bundle) if bundle else "")


class IosRecorder(LaneRecorder):
    """The iOS half: no VM transport — the failure-path bundle is the
    leg's own log (the harness's step timeline) plus the booted-device
    census, collected where drain() prints the verdict."""

    def __init__(self, root):
        super().__init__("ios", root)

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
                self.adopt(bundle, "leg-log", log)
                self.section(bundle, "devices",
                             ["xcrun", "simctl", "list", "devices",
                              "booted"])
                self.bundle_report(bundle, out=out)
        self.leg(leg, verdict, secs, fail, str(bundle) if bundle else "")


class AndroidRecorder(LaneRecorder):
    """The android half: the failure-path bundle is the leg's own log
    plus the adb device roster — an android leg that failed because its
    emulator went offline reads exactly like one that failed an
    assertion, and only the roster tells them apart."""

    def __init__(self, root):
        super().__init__("android", root)

    def android_leg(self, leg, verdict, secs, log, out=None):
        """The one per-leg entry point: the journal takes every leg,
        pass or fail; the bundle is collected on a failure alone."""
        if not self.ok:
            return
        bundle, fail = None, ""
        if verdict != "PASS":
            bundle = self.bundle(leg)
            fail = self.fail_sentence(log)
            if bundle is not None:
                self.adopt(bundle, "leg-log", log)
                self.section(bundle, "devices", ["adb", "devices", "-l"])
                self.bundle_report(bundle, out=out)
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
        src = self.root / "tools/mac/flightrec-winlist.swift"
        if not src.is_file():
            return None
        digest = hashlib.sha256(src.read_bytes()).hexdigest()[:12]
        binp = self.root / f"target/tools/flightrec-winlist-{digest}"
        if binp.is_file():
            self._winlist = str(binp)
            return self._winlist
        (self.root / "target/tools").mkdir(parents=True, exist_ok=True)
        got = subprocess.run(
            ["bash", "-c",
             'source "$1/tools/lib/swift-toolchain.sh" && '
             'kaya_swiftc -O -o "$2" "$3"',
             "_", str(self.root), str(binp), str(src)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False)
        if got.returncode == 0 and binp.is_file():
            self._winlist = str(binp)
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

    def _shot(self, bundle, scratch):
        """The fail-time attempt first; the sampler's live shot is
        what answers when the guest is already gone (an assertion
        failure exits at once)."""
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
            return
        if not pid:
            (bundle / "shot.skip").write_text(
                "flightrec: the sampler never resolved a guest pid "
                "for this leg, so no window is attributed to the "
                "guest and none was photographed. The window list "
                "beside this file is the whole desktop.\n",
                encoding="utf-8")
        else:
            (bundle / "shot.skip").write_text(
                f"flightrec: guest pid {pid} owned no on-screen "
                f"window at failure and the sampler took none while "
                f"it lived — the leg failed faster than the "
                f"sampler's first shot. The window list beside this "
                f"file is what was there.\n", encoding="utf-8")
        self.mark(bundle, "shot", "skip", 0)

    def _capture(self, bundle, log, scratch):
        scratch = pathlib.Path(scratch)
        self.adopt(bundle, "sampler", scratch / "sampler.txt")
        self.adopt(bundle, "sample", scratch / "sample.txt")
        if log and pathlib.Path(log).is_file():
            self.adopt(bundle, "leg-log", log)
        else:
            (bundle / "leg-log.skip").write_text(
                "flightrec: this leg streamed to the terminal "
                "(KAYA_JOBS=1), so there is no log file to keep\n",
                encoding="utf-8")
            self.mark(bundle, "leg-log", "skip", 0)
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
            (bundle / "windows.skip").write_text(
                "flightrec: no swiftc, or "
                "tools/mac/flightrec-winlist.swift would not build — "
                "no window list and therefore no window shot\n",
                encoding="utf-8")
            self.mark(bundle, "windows", "skip", 0)
            self.mark(bundle, "shot", "skip", 0)
        self.section(bundle, "unified-log", [
            "log", "show", "--last", "2m", "--style", "compact",
            "--predicate",
            'process CONTAINS "kaya" OR senderImagePath CONTAINS '
            '"kaya" OR eventMessage CONTAINS "kaya"'])
        self.bundle_report(bundle)

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
                self._capture(bundle, log, scratch)
                if out is not None:
                    self.bundle_report(bundle, out=out)
        self.leg(leg, verdict, secs, fail, str(bundle) if bundle else "")
        shutil.rmtree(scratch, ignore_errors=True)
