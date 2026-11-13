"""The linux lanes' Docker API, up before a matrix launches anything
(docs/traps.md, a matrix launched with Docker down)."""
import json
import pathlib
import subprocess
import time

DOCKER_BUNDLES = ("com.docker.docker", "com.electron.dockerdesktop")
API_WALL_S = 180
START = ["docker", "desktop", "start", "--detach"]
SETTINGS = (pathlib.Path.home()
            / "Library/Group Containers/group.com.docker/settings-store.json")
NO_DASHBOARD = "OpenUIOnStartupDisabled"


def _run(argv, timeout):
    try:
        got = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             encoding="utf-8", errors="replace", check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "", f"did not answer within {timeout}s"
    except OSError as error:
        return None, "", str(error)
    return got.returncode, got.stdout.strip(), got.stderr.strip()


def api():
    """(True, server version) when the daemon answers, else (False, what docker said)."""
    rc, out, err = _run(["docker", "info", "--format", "{{.ServerVersion}}"], 20)
    if rc == 0 and out:
        return True, out
    first = (err or out).splitlines()
    detail = first[0][:300] if first else "no output"
    return False, (f"`docker info` exited {rc}: {detail}" if rc is not None
                   else f"`docker info` {detail}")


def front_bundle():
    """The frontmost application's bundle id, by lsappinfo; never a window title."""
    rc, asn, err = _run(["lsappinfo", "front"], 10)
    if rc != 0 or not asn:
        return f"unreadable (lsappinfo front exited {rc}: {err[:120]})"
    rc, out, err = _run(["lsappinfo", "info", "-only", "bundleid", asn], 10)
    value = out.partition("=")[2].strip().strip('"')
    if rc != 0 or not value:
        return f"unreadable (lsappinfo info {asn} exited {rc}: {(err or out)[:120]})"
    return value


def no_dashboard_on_start(say, settings=SETTINGS):
    """Docker Desktop's "Open Docker Dashboard when Docker Desktop starts", turned off."""
    try:
        store = json.loads(settings.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        say(f"docker: could not read {settings} ({error}); starting without turning "
            f"{NO_DASHBOARD} on, and the frontmost app is read back after")
        return
    was = store.get(NO_DASHBOARD, "absent")
    if was is True:
        return
    store[NO_DASHBOARD] = True
    try:
        settings.write_text(json.dumps(store, indent=2), encoding="utf-8")
    except OSError as error:
        say(f"docker: could not write {NO_DASHBOARD} into {settings} ({error})")
        return
    say(f"docker: set {NO_DASHBOARD} in {settings} (it read {was!r} "
        f"before), so the start does not raise the dashboard")


def ensure(say, wall=API_WALL_S, start=START):
    """True when the API answers, starting Docker Desktop in the background if it does not.
    Every sentence goes through `say`; False means the matrix must not launch."""
    up, what = api()
    if up:
        say(f"docker: the API answers (server {what}); not started")
        return True
    no_dashboard_on_start(say)
    before = front_bundle()
    t0 = time.time()
    rc, out, err = _run(start, 60)
    if rc != 0:
        say(f"docker: REFUSED — the API did not answer ({what}) and `{' '.join(start)}` exited "
            f"{rc}: {(err or out)[:200] or 'no output'}. Start Docker Desktop (`docker desktop start`), wait "
            f"for `docker info` to answer, and launch again.")
        return False
    while True:
        up, now = api()
        if up or time.time() - t0 > wall:
            break
        time.sleep(2)
    after = front_bundle()
    took = time.time() - t0
    if not up:
        say(f"docker: REFUSED — `{' '.join(start)}` exited 0 but the API still did not answer "
            f"after {took:.0f}s ({now}); the frontmost app read {before} before and {after} "
            f"after. Read `docker desktop status`, start it by hand, and launch again once "
            f"`docker info` answers.")
        return False
    if after != before and after in DOCKER_BUNDLES:
        say(f"docker: REFUSED — the API answers (server {now}) after {took:.0f}s, but the "
            f"frontmost app moved from {before} to {after}, which would sit over the mac legs. "
            f"Hide Docker Desktop's window and launch again (Docker keeps running).")
        return False
    say(f"docker: started in the background (server {now}) after {took:.0f}s; the frontmost "
        f"app read {before} before and {after} after"
        + ("" if after == before else " (not Docker's; a hand at the host and a start that "
           "raised another app read the same here)"))
    return True
