#!/usr/bin/env python3
"""THE LINUX LANE'S FOCUS RING (docs/deferred.md, the wayland clipboard
seed entry; tools/guest/flightrec.ps1's foreground ring is the shape).

    tools/linux/focus-ring.py sample <ring-dir> [--seconds N]
    tools/linux/focus-ring.py cut <ring-file> <out> --leg L --since T0 [...]
    tools/linux/focus-ring.py --self-test

Runs INSIDE the linux container, from tools/linux/run-suites.sh, so it
carries no dev-shell guard (persist-leg.py's, act2.py's and notifyd.py's
rule).

WHY A RING AND NOT A READING AT COLLECT: the `desktop` section is the sway
tree at COLLECT, with the guest already gone, so it can say what the
workspace looked like afterwards and nothing about who held focus WHILE
the leg ran. On wayland that is the question a clipboard red asks — a
client is handed a data offer through its seat, and the seat's focus is
the compositor's, not gdk's.

ONE RING PER SESSION, not one per lane: every leg claims a session of its
own from this lane's pools (a headless sway per wayland slot, an Xvfb per
x11 display), so focus inside a leg's session can only be taken by a
process on that session. A slot is reused by the legs that follow, which
is why `cut` prints the leg's own range first and the whole ring under
it.
"""

import json
import os
import pathlib
import subprocess
import sys
import time

# The ring's cap, in lines per session. Halved rather than trimmed by one:
# a rewrite per sample would cost more than the sample.
RING_LINES = 400
INTERVAL = 1.0


def swaymsg(runtime, what):
    """One sway IPC read, as parsed JSON — or a sentence saying why not."""
    ipc = runtime / "ipc"
    if not ipc.is_file():
        return None, "no ipc socket is recorded for this session"
    sock = ipc.read_text(encoding="utf-8").strip()
    env = dict(os.environ, SWAYSOCK=sock, XDG_RUNTIME_DIR=str(runtime))
    try:
        out = subprocess.run(["swaymsg", "-t", what], env=env,
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as e:
        return None, f"unreadable ({type(e).__name__}: {e})"
    if out.returncode != 0:
        said = " ".join((out.stderr or "").split())[:200]
        return None, f"unreadable (swaymsg exited {out.returncode}: {said!r})"
    try:
        return json.loads(out.stdout), ""
    except ValueError as e:
        return None, f"unparsable ({e})"


def sway_seats(runtime):
    """THE SEAT'S OWN ANSWER, beside the tree's: a wayland client is handed
    the selection through the seat that has its surface in keyboard focus,
    and the transient virtual keyboards this lane creates (wtype's F24 tap,
    the `type` verb) come and go on it."""
    seats, why = swaymsg(runtime, "get_seats")
    if seats is None:
        return f"seats={why}"
    said = []
    for seat in seats if isinstance(seats, list) else []:
        devices = ",".join(sorted(
            str(d.get("identifier") or d.get("name"))
            for d in seat.get("devices", []) or []))
        said.append(f"{seat.get('name')!r} focus={seat.get('focus')} "
                    f"devices=[{devices}]")
    return "seats=" + ("; ".join(said) if said else "none")


def sway_focus(runtime):
    """The focused node of one headless sway, and every view beside it."""
    tree, why = swaymsg(runtime, "get_tree")
    if tree is None:
        if why == "no ipc socket is recorded for this session":
            return None
        return f"tree={why}"
    views = []
    focused = None
    stack = [tree]
    while stack:
        node = stack.pop()
        if not isinstance(node, dict):
            continue
        stack.extend(n for n in node.get("nodes", []) or [])
        stack.extend(n for n in node.get("floating_nodes", []) or [])
        if node.get("pid") is None and node.get("app_id") is None:
            # A workspace or an output: it can hold focus, and says so
            # below, but it is not a window.
            if node.get("focused") and focused is None:
                focused = (f"type={node.get('type')!r} "
                           f"name={node.get('name')!r} id={node.get('id')}")
            continue
        view = (f"id={node.get('id')} app_id={node.get('app_id')!r} "
                f"pid={node.get('pid')} name={node.get('name')!r}")
        views.append(view)
        if node.get("focused"):
            focused = view
    views.sort()
    body = "; ".join(views) if views else "none"
    return (f"focus={focused or 'nothing'} | {sway_seats(runtime)} "
            f"| windows: {body}")


def xdotool(display, *args):
    """One xdotool read: its first line, or a sentence saying why not.

    EACH FIELD IS ASKED FOR SEPARATELY (invariant 3). Chained
    (`getwindowfocus getwindowname getwindowpid`) xdotool prints the id
    only when it is the LAST command, so the lines come back shifted; and
    a window with no `_NET_WM_PID` — every window under this lane's bare
    Xvfb, which runs no window manager — fails the pid lookup, which read
    as `focus=none` when one sentence carried all three.
    """
    env = dict(os.environ, DISPLAY=f":{display}")
    try:
        out = subprocess.run(["xdotool", *args], env=env,
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as e:
        return None, f"unreadable ({type(e).__name__}: {e})"
    said = [ln for ln in (out.stdout or "").splitlines() if ln.strip()]
    if out.returncode != 0 or not said:
        err = " ".join((out.stderr or "").split())[:160]
        return None, f"xdotool exited {out.returncode}: {err!r}"
    return said[0].strip(), ""


def x11_focus(display):
    """XGetInputFocus, and what that window says about itself.

    THREE EXECS, NOT ONE CACHED READING: an X window id is reused by the
    legs that follow on the same display, so a name remembered against an
    id is a label this sampler cannot stand behind — and a diagnostic that
    might be naming the previous leg's window is worse than the 16 execs a
    second it saves (the whole lane measured 270s of legs with the reads
    in place).
    """
    window, why = xdotool(display, "getwindowfocus")
    if window is None:
        # `getwindowfocus` answers nonzero when the focus is PointerRoot
        # or None, which is a display whose leg has exited.
        return f"focus=none ({why})"
    name, name_why = xdotool(display, "getwindowname", window)
    pid, pid_why = xdotool(display, "getwindowpid", window)
    said_name = repr(name) if name else name_why
    return (f"focus=id={window} name={said_name} "
            f"pid={pid if pid else pid_why}")


def sessions():
    """Every session this lane booted, by its own record on disk: a
    wayland slot IS its runtime directory (run-suites.sh's
    wayland_session_boot) and an x11 display IS its socket."""
    found = []
    for runtime in sorted(pathlib.Path("/tmp").glob("xdg-wl-*")):
        slot = runtime.name.rsplit("-", 1)[-1]
        if runtime.is_dir() and slot.isdigit():
            found.append(("wl", slot, runtime))
    for sock in sorted(pathlib.Path("/tmp/.X11-unix").glob("X*")):
        number = sock.name[1:]
        if number.isdigit():
            found.append(("x11", number, None))
    return found


def emit(path, line, last):
    """Only CHANGES, so a quiet session does not write a line a second."""
    if line == last.get(str(path)):
        return
    last[str(path)] = line
    with path.open("a", encoding="utf-8") as fh:
        fh.write(f"at={int(time.time())} {line}\n")
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if len(lines) > RING_LINES:
        keep = lines[len(lines) // 2:]
        path.write_text("\n".join(keep) + "\n", encoding="utf-8")


def sample(ring_dir, seconds):
    ring = pathlib.Path(ring_dir)
    ring.mkdir(parents=True, exist_ok=True)
    (ring / "focus-sampler.pid").write_text(f"{os.getpid()}\n",
                                            encoding="utf-8")
    stop = ring / "focus.stop"
    last = {}
    deadline = time.monotonic() + seconds
    print(f"focus-ring: sampling every {INTERVAL}s into {ring} "
          f"(pid {os.getpid()}, deadline {seconds}s)", flush=True)
    while time.monotonic() < deadline:
        # THE STOP CHANNEL VANISHING IS ALSO A STOP (the windows sampler's
        # rule): the scratch directory goes with the lane's EXIT trap, and
        # a poller waiting for a file in a directory that is gone waits
        # for its whole deadline.
        if stop.exists() or not ring.is_dir():
            break
        for kind, number, runtime in sessions():
            if kind == "wl":
                line = sway_focus(runtime)
                if line is None:
                    continue
                emit(ring / f"focus-wl-{number}.txt", line, last)
            else:
                emit(ring / f"focus-x11-{number}.txt",
                     x11_focus(number), last)
        time.sleep(INTERVAL)
    print("focus-ring: sampler exiting", flush=True)


def cut(ring_file, out, leg, since, until, session):
    """The ring, with THIS leg's own lines first. The head says what the
    ring is, because a reader handed a session-wide file with no range
    cannot tell this leg's lines from the previous leg's."""
    path = pathlib.Path(ring_file)
    if not path.is_file():
        return False
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    mine = []
    for line in lines:
        stamp = line.split(None, 1)[0] if line else ""
        if stamp.startswith("at="):
            try:
                at = int(stamp[3:])
            except ValueError:
                continue
            if since <= at <= until:
                mine.append(line)
    head = [
        f"flightrec: {leg} ran {since}..{until} in epoch seconds on "
        f"{session}.",
        "flightrec: this ring is THAT SESSION's, sampled once a second by "
        "tools/linux/focus-ring.py; the session is reused by the legs that "
        "follow, so the lines outside the range above are other legs'.",
        "flightrec: `focus=` is the compositor's own answer (the sway "
        "tree's focused node on wayland, XGetInputFocus on x11) — NOT "
        "gdk's `gtk_window_is_active`, which reads false all leg on a "
        "green wayland leg (crates/kaya/src/gtk.rs, ClipView::active).",
        "",
        "== this leg ==",
    ]
    if mine:
        head.extend(mine)
    else:
        head.append(
            "flightrec: the focus in this session never changed during this "
            "leg — the sampler writes a line only when its reading moves, so "
            "the last line under `the whole ring` below was the state for "
            "the whole leg")
    head.extend(["", "== the whole ring ==", *lines, ""])
    pathlib.Path(out).write_text("\n".join(head), encoding="utf-8")
    return True


# ------------------------------------------------------------ self-test --

def self_test():
    """The two halves nobody watches otherwise: a tree with a focused
    window is read out of sway's own JSON shape, and a cut names the
    leg's own lines."""
    import tempfile

    findings = 0
    with tempfile.TemporaryDirectory() as tmp:
        ring = pathlib.Path(tmp) / "focus-wl-3.txt"
        ring.write_text(
            "at=100 focus=id=7 app_id='a' pid=1 name='old' | windows: x\n"
            "at=200 focus=nothing | windows: none\n"
            "at=300 focus=id=9 app_id='b' pid=2 name='new' | windows: y\n",
            encoding="utf-8")
        out = pathlib.Path(tmp) / "cut.txt"
        if not cut(str(ring), str(out), "leg-wayland", 150, 250,
                   "wayland slot 3"):
            print("focus-ring: SELF-TEST FAILED — cut refused a real ring")
            findings += 1
        text = out.read_text(encoding="utf-8")
        mine = text.split("== this leg ==")[1].split("== the whole ring ==")[0]
        if "at=200" not in mine or "at=100" in mine or "at=300" in mine:
            print("focus-ring: SELF-TEST FAILED — the cut's own range is not "
                  f"the leg's: {mine!r}")
            findings += 1
        if text.count("at=100") != 1 or text.count("at=300") != 1:
            print("focus-ring: SELF-TEST FAILED — the whole ring is not "
                  "under the cut")
            findings += 1
        empty = pathlib.Path(tmp) / "cut2.txt"
        cut(str(ring), str(empty), "leg-wayland", 1000, 2000,
            "wayland slot 3")
        if "never changed during this leg" not in empty.read_text(
                encoding="utf-8"):
            print("focus-ring: SELF-TEST FAILED — a leg with no line of its "
                  "own got no sentence saying so")
            findings += 1
        if cut(str(pathlib.Path(tmp) / "nothing.txt"), str(empty), "l", 1, 2,
               "s"):
            print("focus-ring: SELF-TEST FAILED — a missing ring answered "
                  "true, so the collect would adopt a stale file")
            findings += 1
    print(f"focus-ring: self-test — 5 clause(s), {findings} finding(s)")
    return findings


def main(argv):
    if argv[:1] == ["--self-test"]:
        return 1 if self_test() else 0
    if argv[:1] == ["sample"]:
        seconds = 7200.0
        if "--seconds" in argv:
            seconds = float(argv[argv.index("--seconds") + 1])
        sample(argv[1], seconds)
        return 0
    if argv[:1] == ["cut"]:
        opts = {}
        rest = argv[3:]
        for i, word in enumerate(rest):
            if word.startswith("--"):
                opts[word[2:]] = rest[i + 1]
        wrote = cut(argv[1], argv[2], opts.get("leg", "?"),
                    int(opts.get("since", 0)), int(opts.get("until", 0)),
                    opts.get("session", "?"))
        return 0 if wrote else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
