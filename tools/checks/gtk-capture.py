#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die, scratch_dir

import contextlib
import io
import re
import subprocess
import types

dev_shell_or_die()
g = Gate("gtk-capture")
path = ROOT / "tools/linux/shot-gtk.py"
source = path.read_text(encoding="utf-8")
PNG = b"\x89PNG\r\n\x1a\n" + bytes(1200)


def load(text):
    namespace = {"__name__": "capture_checks", "__file__": str(path)}
    exec(compile(text, str(path), "exec"), namespace)
    return namespace


def inner_case(text, case):
    module = load(text)
    calls = []
    refusal = None
    polls = 0

    class Guest:
        def poll(self):
            nonlocal polls
            polls += 1
            if case == "early-exit" or (case == "capture-exit" and polls >= 2):
                return 7
            return None

        def terminate(self):
            calls.append("terminate")

        def wait(self, **kwargs):
            calls.append("wait")
            if case == "kill" and "kill" not in calls:
                raise subprocess.TimeoutExpired("guest", 5)

        def kill(self):
            calls.append("kill")

    def run(command, **kwargs):
        stage = {"cargo": "build", "python3": "verify", "import": "screenshot",
                 "convert": "crop"}[command[0]]
        calls.append(stage)
        if case == stage:
            return types.SimpleNamespace(returncode=42)
        if stage in ("screenshot", "crop"):
            if case != stage + "-missing":
                blob = b"bad" if case == stage + "-bad" else PNG
                pathlib.Path(command[-1]).write_bytes(blob)
        return types.SimpleNamespace(returncode=0)

    def popen(command, **kwargs):
        calls.append("guest")
        kwargs["stdout"].write(b"measured guest output\n")
        return Guest()

    module["subprocess"] = types.SimpleNamespace(
        run=run, Popen=popen, STDOUT=subprocess.STDOUT,
        TimeoutExpired=subprocess.TimeoutExpired)
    module["time"] = types.SimpleNamespace(sleep=lambda _: None)
    with scratch_dir("gtk-capture-case-") as tmp:
        try:
            module["capture"]("confirm", tmp / "crop.png", None, 0)
        except (OSError, RuntimeError) as error:
            refusal = str(error)
        if case in ("success", "kill"):
            assert refusal is None, refusal
            assert (tmp / "crop.png").read_bytes() == PNG
        else:
            assert refusal is not None, f"{case}: accepted failure"
        expected = ["build"]
        if case != "build":
            expected += ["verify"]
            if case != "verify":
                expected += ["guest"]
                if case != "early-exit":
                    expected += ["screenshot"]
                    if case not in ("screenshot", "screenshot-missing",
                                    "screenshot-bad", "capture-exit"):
                        expected += ["crop"]
                if case not in ("early-exit", "capture-exit"):
                    expected += ["terminate", "wait"]
                    if case == "kill":
                        expected += ["kill", "wait"]
                else:
                    expected += ["wait"]
        assert calls == expected, f"{case}: calls {calls}, expected {expected}"
    return refusal


def host_case(text, case):
    module = load(text)
    refusal = None
    calls = []
    seen = []

    def run(command, **kwargs):
        calls.append("container")
        mounts = [command[i + 1] for i, arg in enumerate(command[:-1]) if arg == "-v"]
        mount = next(value for value in mounts if value.endswith(":/capture"))
        scratch = pathlib.Path(mount.removesuffix(":/capture"))
        seen.append(scratch)
        assert command[0:3] == ["timeout", "300", "docker"]
        assert "bash" not in command
        assert command[-2:] == ["--crop", "600x400"]
        settings = (scratch / "config/gtk-4.0/settings.ini").read_text(encoding="utf-8")
        assert settings.endswith("appmenu:close\n")
        kwargs["stdout"].write(b"build transcript\n")
        (scratch / "guest.log").write_bytes(b"guest transcript\n")
        if case != "missing":
            (scratch / "crop.png").write_bytes(b"bad" if case == "bad" else PNG)
        return types.SimpleNamespace(returncode=42 if case == "failure" else 0)

    module["subprocess"] = types.SimpleNamespace(run=run, STDOUT=subprocess.STDOUT)
    args = types.SimpleNamespace(scene="confirm", layout="appmenu:close",
                                 crop="600x400", settle_seconds=0)
    with scratch_dir("gtk-capture-host-") as tmp:
        out = tmp / "a photo.png"
        out.write_bytes(b"previous photograph")
        try:
            module["photograph"](args, out, "expect title\nsettle 20000\n")
        except (OSError, RuntimeError) as error:
            refusal = str(error)
        assert calls == ["container"], calls
        assert all(not directory.exists() for directory in seen), "scratch survived"
        transcript = out.with_name(out.name + ".log").read_bytes()
        assert b"build transcript" in transcript and b"guest transcript" in transcript
        if case == "success":
            assert refusal is None, refusal
            assert out.read_bytes() == PNG
        else:
            assert refusal is not None, f"host {case}: accepted failure"
            assert out.read_bytes() == b"previous photograph", "replaced output on failure"
    return refusal


CASES = ["success", "build", "verify", "early-exit", "screenshot", "capture-exit",
         "screenshot-missing", "screenshot-bad", "crop", "crop-missing", "crop-bad", "kill"]
for case in CASES:
    with contextlib.redirect_stdout(io.StringIO()):
        refusal = inner_case(source, case)
    print(f"gtk-capture: {case}: {refusal or 'accepted'}")
for case in ("success", "failure", "missing", "bad"):
    with contextlib.redirect_stdout(io.StringIO()):
        refusal = host_case(source, case)
    print(f"gtk-capture: host {case}: {refusal or 'accepted'}")

cuts = [
    ("unchecked command", "if result.returncode != 0:", "if False:", 2, inner_case, "build"),
    ("skip verification",
     'checked("build verification", ["python3", "tools/build-id.py", "--verify",\n'
     '                                   str(target / "debug/libkaya.so")])',
     "None", 1, inner_case, "success"),
    ("early exit ignored", "if rc is not None:", "if False:", 2, inner_case, "early-exit"),
    ("during-capture exit ignored",
     'raise RuntimeError(f"{scene} exited {rc} during the screenshot")',
     "pass", 1, inner_case, "capture-exit"),
    ("raw image unchecked", "image_bytes(raw)", "None", 1, inner_case, "screenshot-bad"),
    ("crop image unchecked", "image_bytes(out)", "None", 1, inner_case, "crop-bad"),
    ("guest not terminated", "guest.terminate()", "None", 1, inner_case, "success"),
    ("guest not killed", "guest.kill()", "None", 1, inner_case, "kill"),
    ("host failure ignored",
     'raise RuntimeError(f"container exited {result.returncode}; read {transcript}")',
     "pass", 1, host_case, "failure"),
    ("publish without PNG check", 'image_bytes(scratch / "crop.png")',
     '(scratch / "crop.png").read_bytes()', 1, host_case, "bad"),
]
for label, before, after, count, probe, case in cuts:
    mutant = g.doctor(label, source, re.escape(before), lambda _: after, want=count)
    caught = None
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            probe(mutant, case)
        except (AssertionError, subprocess.TimeoutExpired) as error:
            caught = str(error)
    if caught is None:
        g.refuse(f"{label}: mutation escaped executed checks")
    print(f"gtk-capture: watched negative {label}: {caught}")
print("gtk-capture: 16 execution cases and 10 counted mutations passed")
