#!/usr/bin/env python3
"""THE CLASS AN INSTALLED kaya APP WOULD BE MATCHED BY, READ OFF THE REAL SERVER.

A LEG-level assertion, not a scene's: no harness verb reads a window
class, and tools/scenes/*.steps are shared verbatim by five platforms.
It runs OUTSIDE the leg, because the app has to be alive to be asked.
Why the class needs moving at all, and by which route on each protocol,
is in docs/deferred.md ("The primary window keeps its launcher binary's
`app_id`/`WM_CLASS`").

Five clauses: the SERVER is asked and never kaya's model; EVERY mapped
toplevel of this app carries the declared class; at least TWO of them,
since the auxiliary window is born with the right class for free and a
read satisfied by one may have found that one; the class is the name
declared in guests/assets/identity.toml (docs/app-identity-plan.md
ruling 4); and kaya's own `KAYA_DIAG app identity: class` record names a
route, which is the half the server cannot answer.

A reader that saw no window, or could not read the declaration, fails
HERE rather than agreeing with anything.

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
    # Verbatim, never normalised into the "no class" case: "WM_CLASS: not
    # found" and a class of an unexpected type are different states.
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
    # name into both, so both fields must have moved.
    return len(words) == 2 and words[0] == name and words[1] == name


# ------------------------------------------------------------ WAYLAND ----
# No Wayland client can read another client's app_id, so the read goes
# through sway's IPC — the compositor's own grouping view.
#
# THE PID FILTER IS NOT OPTIONAL. The wayland ring shares ONE headless sway
# across a pool of concurrent legs (KAYA_JOBS wide), so the tree holds other
# legs' windows too. Filtering by class instead would be circular.
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


# A reading that could have come from a LIVE window, per backend: X11's
# class is a pair from realize onward, so a placeholder 1-tuple is the
# destroy race; wayland's app_id is a string, None before/after life.
def settled_x11(words):
    return len(words) == 2


def settled_wayland(words):
    return words[0] is not None


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

    # LINE BY LINE as it arrives, never buffered to the end: this wrapper
    # runs outermost. Kept as well, for the clause about what kaya said.
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
    # THE VERDICT IS ANCHORED ON THE LAST SAMPLE THAT SAW BOTH WINDOWS.
    # The last sample full stop catches the app tearing its windows down
    # and would fail a leg for shutting down. The selector is a COUNT and
    # never the class, and it is REFUSED below if it never happens.
    samples = {"last": None, "polls": 0, "count": 0, "peak": 0}

    def poll():
        while child.poll() is None:
            if backend == "x11":
                found = sample_x11()
            else:
                # Re-derived every sample: the guest is a grandchild behind
                # two wrappers and is not running yet at the first one.
                found = sample_wayland(descendants(child.pid))
            samples["polls"] += 1
            if found:
                samples["count"] += 1
                samples["peak"] = max(samples["peak"], len(found))
                # AND EVERY WINDOW MUST HAVE YIELDED A LIVE READING: a
                # mapped GTK window carries its class from realize
                # onward, so a sample with any placeholder reading is
                # the DESTROY RACE — windows still listed while their
                # properties are already gone (measured under the
                # concurrent matrix, 2026-08-20: the count anchor alone
                # took a both-windows-stripped teardown sample as the
                # verdict and failed a leg for shutting down, the exact
                # state the comment above promises to skip).
                settled = settled_x11 if backend == "x11" else settled_wayland
                if len(found) >= 2 and all(
                    settled(words) for words in found.values()
                ):
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

    # The observation history, passing or failing. THE THREE NUMBERS ARE
    # THREE DIFFERENT FACTS: the reader polls fast until it has the pair
    # and then backs off, so a low "saw a window" count is the backoff and
    # not a near miss.
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
    # THE CLAUSE THE SERVER CANNOT ANSWER: every clause above is satisfied
    # by a class that is right for some other reason, so this one asks kaya
    # what it did and requires it to name a route.
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
