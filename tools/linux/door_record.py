#!/usr/bin/env python3
"""What a relaunch door did, on the record (docs/traps.md, the plain
door's lost Activate).

    tools/linux/door_record.py --self-test

Runs INSIDE the linux container (persist-leg.py's rule: no dev-shell
guard). persist-leg.py and link-leg.py start their session bus, push their
door and print their record through this module, so a red second act says
which of four places it stopped: the launcher, the bus daemon, the
activated Exec, or the process it started.
"""

import os
import pathlib
import select
import shutil
import subprocess
import sys
import tempfile
import time

EXEC_LOG_PREFIX = "act2-exec:"
ACT2_EXEC = pathlib.Path(__file__).resolve().parent / "act2-exec.sh"
LAUNCH_ENTRY = pathlib.Path(__file__).resolve().parent / "launch-entry.py"
OWNER = ("import sys\nfrom gi.repository import Gio\n"
         "app = Gio.Application(application_id=sys.argv[1], "
         "flags=Gio.ApplicationFlags.IS_SERVICE)\n"
         "app.connect('activate', lambda _: None)\n"
         "app.set_inactivity_timeout(300)\n"
         "app.run(None)\n")


def say(message):
    print(f"door-record: {message}", file=sys.stderr, flush=True)


class Bus:
    """A session bus whose daemon's own log is kept: dbus-launch points it
    at /dev/null."""

    def __init__(self, env, log_path):
        self.log_path = pathlib.Path(log_path)
        self.process = None
        self.variables = {}
        self.refusal = ""
        sink = self.log_path.open("w", encoding="utf-8")
        read_end, write_end = os.pipe()
        try:
            self.process = subprocess.Popen(
                ["dbus-daemon", "--session", "--nofork",
                 f"--print-address={write_end}"],
                env=env, stdin=subprocess.DEVNULL, stdout=sink, stderr=sink,
                pass_fds=(write_end,))
        except OSError as error:
            self.refusal = f"dbus-daemon could not start: {error}"
            os.close(read_end)
            os.close(write_end)
            sink.close()
            return
        os.close(write_end)
        sink.close()
        ready, _, _ = select.select([read_end], [], [], 15.0)
        address = os.read(read_end, 4096).decode().strip() if ready else ""
        os.close(read_end)
        if not address:
            self.refusal = (f"dbus-daemon printed no address within 15s; its "
                            f"log: {self.log_text().strip() or 'empty'}")
            self.stop()
            return
        self.variables = {"DBUS_SESSION_BUS_ADDRESS": address,
                          "DBUS_SESSION_BUS_PID": str(self.process.pid)}

    def log_text(self):
        try:
            return self.log_path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            return f"(the daemon's log could not be read: {error})"

    def stop(self):
        if self.process is None or self.process.poll() is not None:
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def exec_record(entry, data_home, app_id):
    """The Exec lines this door can run, as GLib and the bus will read them.

    On the DBusActivatable route the SERVICE file's Exec is what runs; the
    entry's is what a spawn route would run.
    """
    lines = []
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio
    info = Gio.DesktopAppInfo.new_from_filename(str(entry))
    if info is None:
        lines.append(f"entry {entry}: GLib will not load it")
    else:
        lines.append(f"entry {entry}: Exec={info.get_string('Exec')!r}, "
                     f"GLib's commandline {info.get_commandline()!r}, "
                     f"DBusActivatable={info.get_boolean('DBusActivatable')}")
    service = pathlib.Path(data_home) / "dbus-1/services" / f"{app_id}.service"
    if not service.is_file():
        lines.append(f"service {service}: absent")
        return lines
    execs = [line.partition("=")[2] for line in
             service.read_text(encoding="utf-8").splitlines()
             if line.startswith("Exec=")]
    for value in execs or [""]:
        program = value.split()[0] if value.split() else ""
        if not program:
            state = "names no program"
        elif not os.path.isfile(program):
            state = "its program does not exist"
        elif not os.access(program, os.X_OK):
            state = "its program is not executable"
        else:
            state = "its program exists and is executable"
        lines.append(f"service {service}: Exec={value!r}, {state}")
    return lines


def push(argv, env, log_path, ceiling=30.0, watch=None):
    """The launcher, its output to a FILE (link-leg.py's rule: a pipe here
    is a pipe on the app it starts). Answers (rc, output, seconds)."""
    if [pathlib.Path(argv[0]).name, *argv[1:2]] == ["gio", "launch"]:
        return ("refused", "door_record: `gio launch` exits before its "
                "Activate call is written and loses it under load; push "
                "tools/linux/launch-entry.py instead (docs/traps.md, the "
                "plain door's lost Activate)", 0.0)
    started = time.monotonic()
    with pathlib.Path(log_path).open("w", encoding="utf-8") as sink:
        process = subprocess.Popen(argv, env=env, stdout=sink,
                                   stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL)
        while process.poll() is None \
                and time.monotonic() - started < ceiling:
            if watch is not None:
                watch.sample()
            time.sleep(0.05)
        if process.poll() is None:
            process.kill()
            process.wait()
            rc = f"killed at its {ceiling:.0f}s ceiling"
        else:
            rc = process.returncode
    said = pathlib.Path(log_path).read_text(encoding="utf-8",
                                            errors="replace").strip()
    return rc, said, time.monotonic() - started


class Watch:
    """Every process the door's bus started: a child of the daemon, or a
    process carrying the leg's own XDG_STATE_HOME (an activated process
    inherits the daemon's environ). Sampled as the leg polls, since the
    process may be gone by the time the leg gives up."""

    def __init__(self, state_home, bus_pid, started):
        self.needle = f"XDG_STATE_HOME={state_home}".encode()
        self.bus_pid = int(bus_pid) if bus_pid else -1
        self.started = started
        self.seen = {}
        self.samples = 0

    def sample(self):
        self.samples += 1
        now = time.monotonic() - self.started
        live = set()
        proc = pathlib.Path("/proc")
        for entry in proc.iterdir() if proc.is_dir() else ():
            if not entry.name.isdigit() or int(entry.name) == self.bus_pid:
                continue
            try:
                stat = (entry / "stat").read_text(encoding="utf-8",
                                                  errors="replace")
                ppid = int(stat.rpartition(")")[2].split()[1])
                if ppid != self.bus_pid and \
                        self.needle not in (entry / "environ").read_bytes():
                    continue
                try:
                    exe = os.readlink(entry / "exe")
                except OSError:
                    exe = "(exited, not yet reaped)"
                cmdline = (entry / "cmdline").read_bytes().replace(
                    b"\0", b" ").decode("utf-8", "replace").strip()
            except (OSError, ValueError, IndexError):
                continue
            pid = int(entry.name)
            live.add(pid)
            if pid not in self.seen:
                self.seen[pid] = {"exes": [], "ppid": ppid, "first": now,
                                  "gone": None}
            # A pid sampled between fork and exec reads as its parent's
            # program first (docs/traps.md, the plain door's lost Activate).
            if (exe, cmdline) not in self.seen[pid]["exes"]:
                self.seen[pid]["exes"].append((exe, cmdline))
        for pid, row in self.seen.items():
            if pid not in live and row["gone"] is None:
                row["gone"] = now

    def processes(self):
        return [(pid, exe, cmdline)
                for pid, row in sorted(self.seen.items())
                for exe, cmdline in row["exes"]]

    def lines(self):
        if not self.seen:
            return [f"processes: none started by the bus or carrying this "
                    f"leg's XDG_STATE_HOME, in {self.samples} samples"]
        out = []
        for pid, row in sorted(self.seen.items()):
            parent = ("the bus daemon" if row["ppid"] == self.bus_pid
                      else f"pid {row['ppid']}")
            end = (f"gone by +{row['gone']:.1f}s" if row["gone"] is not None
                   else "still running")
            out.append(f"process {pid} (child of {parent}) seen at "
                       f"+{row['first']:.1f}s, {end}: "
                       + " then ".join(f"exe {exe} ({cmdline})"
                                       for exe, cmdline in row["exes"]))
        return out


def exec_log_lines(act2_log):
    """act2-exec.sh's own start and exit lines out of the act-two log."""
    path = pathlib.Path(act2_log)
    if not path.is_file():
        return [f"act2-exec.sh: no {path}, so the activated Exec never ran "
                f"(it writes its start line before anything else)"]
    found = [line for line in path.read_text(
        encoding="utf-8", errors="replace").splitlines()
             if line.startswith(EXEC_LOG_PREFIX)]
    return found or [f"act2-exec.sh: {path} exists and carries no "
                     f"`{EXEC_LOG_PREFIX}` line"]


def report(name, launcher, pushed, execs, bus, watch, act2_log, app_id):
    """The door's record, into the leg log whatever the verdict."""
    rc, said, seconds = pushed
    lines = [f"launcher `{' '.join(launcher)}` exited {rc} after "
             f"{seconds:.2f}s; its output: {said or '(none)'}"]
    lines += execs
    lines += watch.lines()
    lines += exec_log_lines(act2_log)
    daemon = bus.log_text().strip().splitlines()
    asked = sum(f"Activating service name='{app_id}'" in line
                for line in daemon)
    lines.append(f"the bus daemon logged {asked} activation request(s) for "
                 f"{app_id}" + ("" if asked else
                                ": the launcher's call never reached it, or "
                                "the name was already owned"))
    lines += [f"bus daemon pid {bus.variables.get('DBUS_SESSION_BUS_PID')} "
              f"log ({len(daemon)} lines):"]
    lines += [f"  {line}" for line in daemon] or ["  (empty: it was never "
                                                  "asked to activate anything)"]
    print(f"--- {name} door record ---", file=sys.stderr)
    for line in lines:
        print(line, file=sys.stderr)
    sys.stderr.flush()
    return lines


def self_test():
    """Three doors pushed at a real bus, each record read back."""
    if shutil.which("dbus-daemon") is None or shutil.which("gio") is None:
        say("SELF-TEST FAILED — no dbus-daemon or gio here, so no door can "
            "be pushed")
        return 1
    failures = 0
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="kaya-door-selftest-"))
    try:
        cases = (
            ("D1 an Exec that takes its name", "owner", True,
             ("Successfully activated service", "act2-exec: pid",
              "1 activation request(s)", "exited 0 after")),
            ("D2 an Exec that exits 7", "seven", True,
             ("exited with status 7", "act2-exec: pid", "exited 7",
              "was not launched")),
            ("D3 an Exec naming no program", None, False,
             ("Failed to execute program", "its program does not exist",
              "the activated Exec never ran")),
        )
        for label, body, real, wants in cases:
            home = scratch / label.split()[0]
            share = home / "share"
            (share / "applications").mkdir(parents=True)
            (share / "dbus-1/services").mkdir(parents=True)
            app_id = "dev.kaya.DoorSelfTest"
            program = home / "app.sh"
            if real:
                (home / "owner.py").write_text(OWNER, encoding="utf-8")
                program.write_text(
                    f"#!/bin/sh\nexec python3 {home / 'owner.py'} {app_id}\n"
                    if body == "owner" else "#!/bin/sh\nexit 7\n",
                    encoding="utf-8")
                program.chmod(0o755)
            service_exec = f"{ACT2_EXEC} {program}" if real else str(program)
            entry = share / "applications" / f"{app_id}.desktop"
            entry.write_text(
                "[Desktop Entry]\nType=Application\nName=door\n"
                "Exec=/bin/true\nDBusActivatable=true\n", encoding="utf-8")
            (share / "dbus-1/services" / f"{app_id}.service").write_text(
                f"[D-BUS Service]\nName={app_id}\nExec={service_exec}\n",
                encoding="utf-8")
            env = dict(os.environ, XDG_DATA_HOME=str(share),
                       XDG_STATE_HOME=str(home / "state"),
                       KAYA_ACT2_LOG=str(home / "act2.log"))
            bus = Bus(env, home / "bus.log")
            if bus.refusal:
                say(f"SELF-TEST FAILED — {label}: {bus.refusal}")
                failures += 1
                continue
            try:
                env.update(bus.variables)
                started = time.monotonic()
                watch = Watch(env["XDG_STATE_HOME"],
                              bus.variables["DBUS_SESSION_BUS_PID"], started)
                launcher = [sys.executable, str(LAUNCH_ENTRY), str(entry)]
                pushed = push(launcher, env, home / "door.log", watch=watch)
                while time.monotonic() - started < 10:
                    watch.sample()
                    if "ctivated service" in bus.log_text():
                        break
                    time.sleep(0.05)
                lines = report(label, launcher, pushed,
                               exec_record(entry, share, app_id), bus, watch,
                               env["KAYA_ACT2_LOG"], app_id)
            finally:
                bus.stop()
            text = "\n".join(lines)
            missing = [w for w in wants if w not in text]
            print(f"door-record: self-test {label}: {len(lines)} record "
                  f"line(s), {len(wants) - len(missing)} of {len(wants)} "
                  f"wanted")
            if missing:
                say(f"SELF-TEST FAILED — {label}'s record lacks {missing}")
                failures += 1
        state = str(scratch / "D5-state")
        later = subprocess.Popen(
            ["sh", "-c", "sleep 0.5; exec sleep 1"],
            env=dict(os.environ, XDG_STATE_HOME=state))
        watch = Watch(state, -1, time.monotonic())
        while later.poll() is None:
            watch.sample()
            time.sleep(0.05)
        exes = [exe for pid, exe, _ in watch.processes() if pid == later.pid]
        print(f"door-record: self-test D5 a pid that execs after it is "
              f"first seen: {exes}")
        if not any(exe.endswith("/sleep") for exe in exes):
            say(f"SELF-TEST FAILED — D5 kept only the program a pid had "
                f"when first sampled: {exes}")
            failures += 1
        rc, said, _ = push(["/usr/bin/gio", "launch", "x.desktop"],
                           dict(os.environ), scratch / "gio.log")
        print(f"door-record: self-test D4 a `gio launch` door: {rc}")
        if rc != "refused" or "launch-entry.py" not in said:
            say(f"SELF-TEST FAILED — D4 pushed `gio launch`: {rc} {said}")
            failures += 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if failures:
        say(f"SELF-TEST FAILED — {failures} case(s)")
        return 1
    print("door-record: self-test — 5 case(s), every record read back")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    say("usage: door_record.py --self-test (the legs import it)")
    sys.exit(2)
