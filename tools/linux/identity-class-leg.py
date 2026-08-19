#!/usr/bin/env python3
"""THE CLASS AN INSTALLED kaya APP WOULD BE MATCHED BY, READ OFF THE REAL SERVER.

WHY THIS EXISTS. A Linux desktop matches a running window to its
installed `.desktop` entry by the window's CLASS — `WM_CLASS` on X11,
`app_id` on Wayland — and that match is what decides the launcher icon,
the dock grouping and the alt-tab entry. kaya's GTK backend builds and
presents its PRIMARY window in `run_core`'s activate handler, before the
app thread's first transaction is drained, so the class of the one window
that matters is sent before any identity can arrive. `g_set_prgname`
cannot move it; `crates/kaya/src/gtk.rs`'s `reclass_toplevels` does, with
`XSetClassHint` on X11 and `xdg_toplevel.set_app_id` on Wayland.

WHAT THIS SCRIPT ASSERTS, and why it is not the scene's job. The class is
not a widget: no harness verb reads it, `tools/scenes/*.steps` are shared
verbatim by five platforms, and this is a Linux-and-display-protocol fact
that no guest language can change. So it is a LEG-level assertion, the
shape `identity-wayland-witness.sh` already set on this lane, and it runs
OUTSIDE the leg — the app has to be alive to be asked.

Each clause is a claim, and each names what it measured:

  1. THE SERVER IS ASKED, not kaya. On X11 that is `xprop WM_CLASS` on the
     xid, the property every other client on that display sees; on Wayland
     it is sway's own tree, which IS the compositor's grouping view and so
     is the thing a shell would match a `.desktop` against. Reading kaya's
     model back would pass with no lowering at all.
  2. EVERY MAPPED TOPLEVEL OF THIS APP CARRIES THE DECLARED CLASS. Not
     "some window does": the auxiliary window is created AFTER the
     declaration and is born with the right class for free, so a read
     satisfied by one window is a read that agrees with the bug. It is the
     PRIMARY this is about, and requiring every mapped toplevel to agree
     is what covers it without this script having to know which is which.
  3. AT LEAST TWO OF THEM, for the same reason from the other side: the
     identity scene holds a primary and an auxiliary, and a sample that
     found one window found the wrong one or found the app mid-startup.
  4. THE CLASS IS THE DECLARED NAME, read out of guests/assets/identity.toml
     rather than typed here (docs/app-identity-plan.md ruling 4: one
     declaration, and every reader gets it from that file).
  5. kaya SAYS IT DID IT. The backend's own `KAYA_DIAG app identity: class`
     record must be present and must name a route. That is the half the
     server cannot tell you: a class that is already right for some other
     reason — a launcher that happened to be named the same thing — would
     satisfy every clause above, and this one fails.

IT REFUSES A VERDICT RATHER THAN AGREEING WITH NOTHING. A reader that saw
no window at all, or could not read the declaration, fails HERE saying so.
A census that reads nothing agrees with everything, and this lane has been
bitten by exactly that twice (docs/traps.md, the wayland seat guard).

Usage: identity-class-leg.py <the leg's command line>
The child's output is passed through unchanged and its exit status is the
script's, unless a clause above fails.
"""

import concurrent.futures
import json
import os
import re
import subprocess
import sys
import threading
import time
import tomllib

# THE POLL INTERVAL, in seconds, and it is TWO numbers because the first
# sample and the hundredth are worth different amounts.
#
# MEASURED, and this is why the fast one exists: at a flat 1.0s an
# identity leg that runs for 3 seconds took exactly ONE usable sample —
# the app's windows appear about 1.2s in, behind a11y-leg.sh's bus wait,
# and the app is gone by 3s. One sample is one scheduling hiccup away from
# zero, and zero is this reader refusing a verdict on a leg that was fine.
# So it polls fast until it has what it needs and then backs off, which
# keeps the cost off the tail of a 34s wayland leg: eight short-lived
# processes per X11 sample, and the wayland ring shares one compositor
# with seven other legs.
INTERVAL_FAST = 0.2
INTERVAL_SETTLED = 1.0


def fail(*words):
    print("identity-class-leg: " + " ".join(words), file=sys.stderr)
    sys.exit(1)


def declared_name():
    """The app's declared name, from the ONE file that declares it."""
    path = os.environ.get("KAYA_IDENTITY_MANIFEST", "/work/guests/assets/identity.toml")
    try:
        with open(path, "rb") as handle:
            name = tomllib.load(handle).get("name", "")
    except OSError as why:
        fail(
            f"cannot read the identity manifest {path} ({why}), so it does not know",
            "what class to expect — refusing rather than guessing.",
        )
    if not name:
        name = ""
    if not name.strip():
        fail(
            f"{path} declares no non-empty name, so this reader would accept any",
            "class at all — refusing.",
        )
    return name


def run(argv):
    """One short-lived tool, or None if it could not be run at all."""
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout


# ---------------------------------------------------------------- X11 ----
# The read is `xprop -id <xid> WM_CLASS` — the server's own copy of the
# property, which is what every other client on the display sees.
#
# THE XIDS COME FROM A SEARCH of the root's children rather than from
# `_NET_CLIENT_LIST`, because that is a window manager's property and this
# lane runs no window manager on X11 (one would resize windows and break
# every expect_window_size leg). Each X11 leg owns its own Xvfb, so the
# root's children are this process's windows and nobody else's.
#
# AND `Map State: IsViewable` IS THE DISCRIMINATOR, measured rather than
# assumed: an identity leg's root has FIVE children for TWO kaya windows.
# GDK keeps a 1x1 leader window that carries the launcher's WM_CLASS and is
# never mapped, a second unnamed 1x1, and xvfb contributes a 10x10 with no
# class at all. None of those is a window a desktop would ever group, and
# demanding the declared class on every root child would fail every run.
WINDOW_ID = re.compile(r"^\s+(0x[0-9a-f]+)\b")
WM_CLASS = re.compile(r'^WM_CLASS\(STRING\)\s*=\s*"(.*)",\s*"(.*)"\s*$')


def read_x11_window(xid):
    """One window: its class, or None if it is not a mapped toplevel."""
    stats = run(["xwininfo", "-id", xid, "-stats"])
    if stats is None or "IsViewable" not in stats:
        return None
    prop = run(["xprop", "-id", xid, "WM_CLASS"])
    if prop is None:
        return None
    text = prop.strip()
    pair = WM_CLASS.match(text)
    if pair:
        return (pair.group(1), pair.group(2))
    # Printed verbatim, never normalised into the "no class" case: "WM_CLASS:
    # not found" and a class of an unexpected type are different states of
    # the world and the reader chases whichever one is named.
    return ("<" + text + ">",)


def sample_x11():
    """Every MAPPED toplevel on this display, as {xid: class-as-read}.

    THE PER-WINDOW PROBES RUN CONCURRENTLY, and that is not a micro-
    optimisation — it is what makes the reader able to answer at all.
    MEASURED: a serial sample is eight short-lived processes deep, takes
    most of a second in this container, and an identity leg lives for
    three, so the reader came back with ONE usable sample and was a
    scheduling hiccup away from none — which is this script REFUSING a
    verdict on a leg that was fine. Two spawn latencies instead of eight
    buys the margin, and neither the tools nor what they are asked
    changes.
    """
    children = run(["xwininfo", "-root", "-children"])
    if children is None:
        return None
    xids = [hit.group(1) for hit in map(WINDOW_ID.match, children.splitlines()) if hit]
    if not xids:
        return {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(xids)) as pool:
        read = list(pool.map(read_x11_window, xids))
    return {xid: words for xid, words in zip(xids, read) if words is not None}


def describe_x11(found):
    return "; ".join(
        f"{xid} WM_CLASS = " + ", ".join(f'"{word}"' for word in words)
        for xid, words in sorted(found.items())
    )


def matches_x11(words, name):
    # WM_CLASS is a PAIR — instance and class — and GDK writes the program
    # name into both, so the primary is only indistinguishable from a window
    # created after the declaration if both fields moved.
    return len(words) == 2 and words[0] == name and words[1] == name


# ------------------------------------------------------------ WAYLAND ----
# No Wayland client can read another client's app_id: the compositor is the
# only holder of it. So the read goes through sway's IPC, which is not a
# workaround but the closest thing to the real question — that tree IS what
# a wlroots shell groups and matches by.
#
# THE PID FILTER IS NOT OPTIONAL. The wayland ring shares ONE headless sway
# across a pool of concurrent legs (KAYA_JOBS wide), so the tree holds other
# legs' windows too. Nodes are kept only if their pid is this script's own
# descendant, which is exact where a class-name filter would be circular —
# selecting windows by the very class under test.
def descendants(root):
    """Every live pid below `root`, inclusive, from /proc."""
    parents = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat", "rb") as handle:
                stat = handle.read().decode("utf-8", "replace")
        except OSError:
            continue
        # The comm field is parenthesised and may itself contain spaces and
        # parentheses, so the fields after it are found from the LAST ')'.
        tail = stat[stat.rfind(")") + 1 :].split()
        if len(tail) < 2:
            continue
        parents[int(entry)] = int(tail[1])
    seen = {root}
    changed = True
    while changed:
        changed = False
        for pid, parent in parents.items():
            if parent in seen and pid not in seen:
                seen.add(pid)
                changed = True
    return seen


def sample_wayland(pids):
    """Every toplevel of this leg's process tree, as {node-id: app_id}."""
    tree = run(["swaymsg", "-t", "get_tree"])
    if tree is None:
        return None
    try:
        root = json.loads(tree)
    except ValueError:
        return None
    found = {}

    def walk(node):
        if node.get("pid") in pids and node.get("shell"):
            found[str(node.get("id"))] = (node.get("app_id"),)
        for key in ("nodes", "floating_nodes"):
            for child in node.get(key, []):
                walk(child)

    walk(root)
    return found


def describe_wayland(found):
    return "; ".join(
        f"sway node {node} app_id = {words[0]!r}" for node, words in sorted(found.items())
    )


def matches_wayland(words, name):
    return words[0] == name


def main():
    if len(sys.argv) < 2:
        fail("needs the leg's command line")
    name = declared_name()

    backend = os.environ.get("GDK_BACKEND", "")
    if backend == "x11":
        describe, matches = describe_x11, matches_x11
    elif backend == "wayland":
        describe, matches = describe_wayland, matches_wayland
    else:
        fail(
            f"GDK_BACKEND is {backend!r}, which is neither x11 nor wayland, so this",
            "reader does not know which server holds the class — refusing rather",
            "than reading nothing and passing.",
        )

    # The leg's own output is passed through LINE BY LINE as it arrives,
    # never held back to the end: a wrapper that buffered it would make
    # every failure underneath it unreadable, and this one runs outermost.
    # It is also kept, because clause 5 is a question about what kaya said.
    child = subprocess.Popen(
        sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    said = []

    def relay():
        for line in child.stdout:
            said.append(line)
            sys.stdout.write(line)
            sys.stdout.flush()

    history = []
    # THE VERDICT IS ANCHORED ON THE LAST SAMPLE THAT SAW BOTH WINDOWS,
    # and the choice is between two races rather than a preference. The
    # last sample FULL STOP catches the app tearing its windows down — a
    # sample taken while the process is alive can still find one window or
    # none, and this reader would then fail a leg for shutting down. The
    # last sample that saw the app's two toplevels has neither problem,
    # and it is not the assertion selecting the answer it wants: the
    # selector is a COUNT, the count it demands is stated below and
    # REFUSED if it never happens, and the class is never looked at.
    samples = {"last": None, "polls": 0, "count": 0, "peak": 0}

    def poll():
        while child.poll() is None:
            if backend == "x11":
                found = sample_x11()
            else:
                # Re-derived every sample rather than accumulated: the guest
                # is a grandchild behind two wrappers and is not running yet
                # at the first sample, and a pid that has exited must leave
                # the set with it.
                found = sample_wayland(descendants(child.pid))
            samples["polls"] += 1
            if found:
                samples["count"] += 1
                samples["peak"] = max(samples["peak"], len(found))
                if len(found) >= 2:
                    samples["last"] = found
                shape = describe(found)
                if not history or history[-1] != shape:
                    history.append(shape)
            time.sleep(INTERVAL_FAST if samples["last"] is None else INTERVAL_SETTLED)

    relaying = threading.Thread(target=relay, daemon=True)
    relaying.start()
    watcher = threading.Thread(target=poll, daemon=True)
    watcher.start()
    rc = child.wait()
    relaying.join(timeout=INTERVAL_SETTLED * 5)
    watcher.join(timeout=INTERVAL_SETTLED * 3)

    # The observation history, always, passing or failing: it is the record
    # of what this display held while the leg ran, and on a failure it is
    # the first thing a reader wants.
    # THE THREE NUMBERS ARE THREE DIFFERENT FACTS and are printed as
    # three, because one of them read alone is misleading: a leg that
    # polled twenty times, saw a window in one of them and both windows in
    # that one is a HEALTHY read on a three-second leg — the reader polls
    # fast until it has the pair and then backs off, so a low "with a
    # window" count is the backoff and not a near miss.
    print(
        f"identity-class-leg: {backend}: {samples['polls']} polls, "
        f"{samples['count']} saw a window, most seen at once {samples['peak']}, "
        f"{len(history)} distinct readings:"
    )
    for shape in history:
        print(f"identity-class-leg:   {shape}")

    if samples["peak"] == 0:
        fail(
            f"this reader never saw a single toplevel of the leg on {backend} in",
            f"{samples['polls']} polls, so it has nothing to assert and would agree",
            "with any class at all — refusing. Either the guest never opened a",
            f"window (leg exit {rc}) or the reader is pointed at the wrong server.",
        )
    if samples["last"] is None:
        fail(
            f"this reader never saw more than {samples['peak']} toplevel of the leg at",
            f"once in {samples['polls']} polls ({samples['count']} of which saw a",
            "window), and the identity scene holds two — a",
            "primary and an auxiliary. The auxiliary is created AFTER the declaration",
            "and carries the declared class for free, so a read that found one window",
            "may have found the one this assertion is not about. Refusing rather than",
            "passing on the easy half.",
        )

    found = samples["last"]
    wrong = {xid: words for xid, words in found.items() if not matches(words, name)}
    if wrong:
        fail(
            f'the app declared the name "{name}", so every one of its mapped',
            f"toplevels should carry that class — {len(wrong)} of {len(found)} does",
            f"not: {describe(wrong)}. The whole read was: {describe(found)}. A window",
            "keeping its launcher binary's class is the primary window whose class",
            "was sent before the identity arrived (crates/kaya/src/gtk.rs,",
            "reclass_toplevels), and no .desktop entry can match it.",
        )
    # CLAUSE 5, and it is the one the server cannot answer. Every clause
    # above is satisfied by a class that is right for some OTHER reason — a
    # launcher binary that happened to be named the same thing would pass
    # them all with the lowering deleted. This one asks kaya what it did,
    # and it names a route, so "the class moved" and "the class never had
    # to move" stay two different verdicts.
    record = [line for line in said if "KAYA_DIAG app identity: class -> " in line]
    if not record:
        fail(
            "the server holds the right class but this process never reported",
            "moving one: no `KAYA_DIAG app identity: class` line in the leg's",
            "output. Either the identity never reached the GTK backend, or the",
            "re-class was skipped and the class read above is right for some",
            "other reason — a launcher binary that happens to share the declared",
            "name would satisfy every clause but this one.",
        )
    routes = ("XSetClassHint", "xdg_toplevel.set_app_id")
    if not any(route in line for line in record for route in routes):
        fail(
            "kaya reported a class lowering that names no route:",
            "".join(record).strip(),
            f"— on {backend} that means no window's class was actually moved, and",
            "the class the server holds came from somewhere else.",
        )
    print(
        f"identity-class-leg: all {len(found)} mapped toplevels carry the declared "
        f'class "{name}" on {backend} — {describe(found)}; kaya reported: '
        + " ".join(line.strip() for line in record)
    )
    sys.exit(rc)


if __name__ == "__main__":
    main()
