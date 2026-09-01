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

import os
import pathlib
import subprocess
import sys
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
