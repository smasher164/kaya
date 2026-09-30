"""The media suite's local server, as a lane holds it (docs/media-plan.md §7a).

`with serving() as base:` starts tools/media-server.py, returns once a Range
fetch answers 206, and on exit stops it and proves it gone, raising if the
process is alive or the port still answers: a lane may not leave one running.
"""

import contextlib
import hashlib
import os
import pathlib
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SCRIPT = ROOT / "tools" / "media-server.py"
HOST = "127.0.0.1"
PORT = 8765
PROBE = "h264_aac.mp4"
READY_S = 15.0


def listening(host=HOST, port=PORT):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex((host, port)) == 0


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def range_status(base):
    req = urllib.request.Request(f"{base}/{PROBE}", headers={"Range": "bytes=0-1"})
    try:
        with urllib.request.urlopen(req, timeout=2) as r:
            return r.status, len(r.read())
    except (urllib.error.URLError, OSError) as e:
        return f"{type(e).__name__}: {e}", 0


def stop(proc, port=PORT, host=HOST):
    """Stop the server and prove it: the pid gone AND nothing on the port."""
    if proc.poll() is None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
    alive = pid_alive(proc.pid)
    answering = listening(host, port)
    if alive or answering:
        raise RuntimeError(
            f"media-server: still running after stop — pid {proc.pid} "
            f"{'alive' if alive else 'gone'}, {host}:{port} "
            f"{'answering' if answering else 'closed'}")
    print(f"media-server: stopped, pid {proc.pid} gone and {host}:{port} "
          f"closed", file=sys.stderr, flush=True)


@contextlib.contextmanager
def serving(host=HOST, port=PORT, log=None):
    if listening(host, port):
        raise RuntimeError(
            f"media-server: {host}:{port} already answers before this run "
            f"started one — a server some earlier run left behind; "
            f"`lsof -nP -iTCP:{port}` names its pid")
    out = open(log, "a", encoding="utf-8") if log else subprocess.DEVNULL
    proc = subprocess.Popen(
        [sys.executable, str(SCRIPT), "--bind", host, "--port", str(port)],
        stdout=out, stderr=out, start_new_session=True)
    base = f"http://{host}:{port}"
    try:
        deadline = time.monotonic() + READY_S
        status = None
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(
                    f"media-server: exited {proc.returncode} before it answered"
                    + (f"; its log is {log}" if log else ""))
            status, n = range_status(base)
            if status == 206 and n == 2:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(
                f"media-server: no 206 for a Range fetch of {PROBE} within "
                f"{READY_S:.0f}s; last answer {status}")
        print(f"media-server: {base} answering Range, pid {proc.pid}",
              file=sys.stderr, flush=True)
        yield base
    finally:
        stop(proc, port, host)
        if log:
            out.close()


def mediaremote_lib(root=ROOT):
    """The session_send helper (tools/mac/mediaremote.c), built on demand to a
    content-hashed path under target/tools; None when it cannot be built."""
    root = pathlib.Path(root)
    src = root / "tools/mac/mediaremote.c"
    digest = hashlib.sha256(src.read_bytes()).hexdigest()[:12]
    lib = root / f"target/tools/mediaremote-{digest}.dylib"
    if lib.is_file():
        return str(lib)
    lib.parent.mkdir(parents=True, exist_ok=True)
    got = subprocess.run(
        ["clang", "-dynamiclib", "-fblocks", "-O1", "-framework", "CoreFoundation",
         "-o", str(lib), str(src)],
        capture_output=True, text=True, encoding="utf-8", check=False)
    if got.returncode != 0 or not lib.is_file():
        print(f"media-server: could not build {src.name}: {got.stderr.strip()}",
              file=sys.stderr, flush=True)
        return None
    return str(lib)
