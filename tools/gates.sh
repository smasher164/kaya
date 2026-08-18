#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# THE FAST-GATE SWEEP. One entry point, one list, one verdict.
#
#   tools/gates.sh              build what the gates read, then run every
#                               gate and print a per-gate line and a count
#   tools/gates.sh --list       the list as JSON, for the tools that must
#                               agree with it (check-gates, check-keyed)
#   tools/gates.sh --selftest   watch the count refuse: an under-run, a
#                               failing gate and a missing script must all
#                               come back red
#
# WHY THIS FILE EXISTS, in two defects that both printed green.
#
# 1. THE SWEEP THAT UNDER-RAN. A hand-rolled sweep held its gate list in
#    a variable and looped over it with `for g in $list`. Under zsh an
#    unquoted expansion is NOT word-split, so the whole list arrived as
#    ONE argument: 1 gate of 24 ran and the sweep reported a clean run
#    (2026-08-07). The in-session twin is on the record too — the iOS
#    arm's `for u in $(simctl list …)` shut down one "device" whose name
#    was four concatenated UDIDs, and "the proof is the AFTER listing,
#    not the absence of errors" (postmortem F5.6).
#
#    So: the loop is python3 over a literal list, never shell over a
#    variable, and — the clause that actually kills the class — the
#    sweep KNOWS HOW MANY GATES IT DECLARED and refuses to report
#    success unless that many ran and that many passed. A sweep that
#    silently ran zero gates cannot print OK, because 0 != 28. That
#    refusal is watched failing on every run, by --selftest, which
#    check-gates.sh calls.
#
# 2. THE SWEEP THAT VERIFIED BEFORE IT BUILT. Running the gate list
#    without building first red-flagged check-build-id twice in one day
#    for no reason: it read the PREVIOUS run's artifacts and reported
#    them stale, which was true and useless. tools/validate-mac.sh:63-67
#    had already written the rule down — "a gate cannot verify something
#    the lane has not built yet ... Build every artifact, then verify all
#    of them" — and the rule stayed true while the list moved out from
#    under it. Now the list and the build are the same file, in that
#    order, and the build's exit status is load-bearing: unchecked, a
#    swiftc failure once left the PREVIOUS dylib in place and 152 legs
#    false-PASSed against stale code (2026-07-22).
#
# THERE IS DELIBERATELY NO SUBSET FLAG. No --only, no --skip, no --fast
# (KAYA_FAST already does the honest version of that through
# tools/keyed.sh, which skips a gate whose declared inputs have not
# moved since it last PASSED, and says so with its key). A flag that
# runs part of the list and still prints a verdict is the defect above
# with a command-line interface. To run one gate, run that gate: they
# are all standalone.
#
# THE SWEEP IS macOS-SHAPED — it builds libkaya.dylib and the SwiftUI
# interpreter, and three of its gates load them. The other four lanes
# run their own small per-lane subset (check-targets <platform>,
# gen-header, gen-bindings, and on iOS swift-typecheck) rather than this
# list; that asymmetry is deliberate and check-gates.sh does not police
# it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

exec python3 - "$ROOT" "$@" <<'PY'
import itertools
import json
import pathlib
import subprocess
import sys
import time

root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]

# THE LIST. Order is the order validate-mac.sh ran these in, which is
# roughly cheapest-and-most-likely-to-fail first; check-gates joins the
# doctrine-hygiene cluster right after check-mirror, because the two ask
# the same question about the same file (check-mirror: does AGENTS.md
# still say what CLAUDE.md says; check-gates: does CLAUDE.md still name
# what this file runs).
#
# `keyed` says whether the gate goes through tools/keyed.sh, which under
# KAYA_FAST=1 skips a gate whose declared inputs (build-id.sh's GATES)
# have not moved since it last passed. An UNKEYED gate carries its
# reason here rather than in a comment somewhere else, because "why is
# this one not cached" is the question that gets a gate wrongly cached.
GATES = [
    ("gen-header", ["tools/gen-header.sh", "--check"], True, ""),
    ("gen-bindings", ["tools/gen-bindings.sh", "--check"], True, ""),
    ("gen-guests", ["tools/gen-guests.sh", "--check"], True, ""),
    ("check-steps", ["tools/check-steps.sh"], True, ""),
    # The Python surface's guard and mirror semantics, checked headlessly
    # (records queue; the core is never entered).
    ("kaya-app-checks", ["python3", "bindings/python/kaya_app_checks.py"], False,
     "sub-second and pure python; hashing an input set would cost more than "
     "the run it would skip"),
    ("check-targets", ["tools/check-targets.sh"], True, ""),
    ("check-shell", ["tools/check-shell.sh"], True, ""),
    ("check-mirror", ["tools/check-mirror.sh"], True, ""),
    ("check-gates", ["tools/check-gates.sh"], True, ""),
    # The ledger may not disagree with itself: an unstruck headline over
    # a body that records the work COMPLETE is what sent a survey after
    # a solved problem three weeks after it was solved. Pure prose scan
    # over docs/; its four self-tests run first, inside it.
    ("check-ledger", ["tools/check-ledger.sh"], True, ""),
    # The other half of that failure: a doc citing a path the tree does
    # not have. Same doctrine-hygiene cluster, one question over — the
    # ledger's claims about itself, then every doc's claims about the
    # tree.
    ("check-doc-refs", ["tools/check-doc-refs.sh"], False,
     "its input is the EXISTENCE of every path any doc names, so a rename or "
     "a delete anywhere in the tree is a real input — check-case's shape, and "
     "a key that cheap to invalidate is a cache that never hits"),
    ("check-case", ["tools/check-case.sh"], False,
     "its input is every tracked path plus the directory listings around "
     "them, so any add, delete or rename is a real input; a cache key that "
     "cheap to invalidate is a cache that never hits"),
    ("check-sugar-surface", ["tools/check-sugar-surface.sh"], True, ""),
    ("check-universal-props", ["tools/check-universal-props.sh"], True, ""),
    # The role vocabulary's lowering-side sibling: MENU_ROLES is one line
    # that no generator reads, so a role can ship with the root accepting
    # it and every backend ignoring it. RED BY DESIGN across a fan-out —
    # the role joins the vocabulary first and the four arms follow.
    ("check-roles", ["tools/check-roles.sh"], True, ""),
    # The native undo tier's two guards, which NO shared scene can fail:
    # the ledger-quiet bracket and A1's clear both live inside a SECOND
    # consecutive native walk, and the routing makes that unreachable
    # (compose-undo-arm §3.3/§3.4, watched green with each guard broken).
    # Static pairing is the only wall available.
    ("check-native-undo", ["tools/check-native-undo.sh"], True, ""),
    # A why-not that can print only one sentence prints it for every
    # cause it cannot name, and the reader believes it. Pure source
    # scan; its own two negative tests run first, inside it.
    ("check-diagnostics", ["tools/check-diagnostics.sh"], True, ""),
    ("check-wheel", ["tools/check-wheel.sh"], False,
     "it builds and imports a wheel out of target/, so an unchanged source "
     "tree is not an unchanged answer"),
    ("check-abort", ["tools/check-abort.sh"], False,
     "it links guest probes against the BUILT libkaya, so an unchanged "
     "source tree is not an unchanged answer"),
    ("check-tx-liveness", ["tools/check-tx-liveness.sh"], False,
     "no input set is declared for it in build-id.sh's GATES, so keyed.sh "
     "would refuse at run time; it is a pure source scan and can be keyed "
     "the day someone declares its inputs"),
    ("check-ambient-tx", ["tools/check-ambient-tx.sh"], False,
     "no input set is declared for it in build-id.sh's GATES; same shape as "
     "check-tx-liveness above"),
    # A Go guest reads the HOST's environment, never Go's copy of it: in
    # a c-shared library (Android) os.Getenv is empty forever while C's
    # getenv reads the live one, and an empty KAYA_SELFTEST is not an
    # unknown scene name, it is the default arm. Pure source scan; its
    # four self-tests run first, inside it.
    ("check-go-env", ["tools/check-go-env.sh"], True, ""),
    ("check-build-id", ["tools/check-build-id.sh"], False,
     "it inspects the built libkaya and the built interpreter; this is THE "
     "gate that must never be answered from a cache"),
    ("check-keyed", ["tools/check-keyed.sh"], False,
     "it is the cache's own gate — a cached verdict about the cache is "
     "worth nothing"),
    ("check-pins", ["tools/check-pins.sh"], True, ""),
    # BOTH macOS design generations stay on the mac lane. SwiftUI reads
    # the MAIN EXECUTABLE's sdk stamp, so flake.nix's apple-sdk_26 keeps
    # the kaya-linked legs modern while the vendor-built hosts (python3,
    # dotnet, the zulu JVM) hold the compat side — the side where the
    # Button measurement bug class lives, and the side nobody chose.
    ("check-design-generation", ["tools/check-design-generation.sh"], False,
     "its inputs are the toolchain and the vendor hosts on the machine, not "
     "files in this tree — a source-keyed skip would go quiet exactly when a "
     "nixpkgs or vendor rebuild moved a stamp, which is the move it exists to "
     "catch"),
    ("check-verbs", ["tools/check-verbs.sh"], True, ""),
    # The file-mode numbers against the spec that owns them. Five
    # hand-written sites decode the integer kaya_open_picked takes and
    # nothing held them to the spec's numbering — the same class as
    # check-verbs' private wire constants, one ABI over.
    ("check-file-modes", ["tools/check-file-modes.sh"], True, ""),
    # ONE DECLARED IDENTITY, READ BY A BUILD AND BY A RUNNING APP. Five
    # routes reading five different files is how "one mark on five
    # platforms" breaks quietly: the launcher shows last month's icon,
    # the running window shows this month's, and every test still
    # passes. This holds guests/assets/identity.toml level with every
    # hand-written copy of it, and holds the byte-frozen scene
    # expectation level with the mark's actual pixels.
    ("check-app-identity", ["tools/check-app-identity.sh"], False,
     "one of its clauses walks every path in the tree looking for app-icon "
     "resources, so any add, delete or rename is a real input — check-case's "
     "shape, and a key that cheap to invalidate is a cache that never hits"),
    ("check-jni", ["tools/check-jni.sh"], True, ""),
    ("check-stubs", ["tools/check-stubs.sh"], True, ""),
    ("check-compose", ["tools/check-compose.sh"], True, ""),
    ("check-detekt", ["tools/check-detekt.sh"], True, ""),
    ("swift-typecheck", ["tools/swift-typecheck.sh"], True, ""),
    ("java-typecheck", ["tools/java-typecheck.sh"], True, ""),
]

# Gate scripts that exist on disk and are deliberately NOT in the sweep.
# The reason is required and check-gates.sh reads it: an exclusion with
# no stated reason is how four gates went unnamed for two milestones.
EXCLUDED = {
    "tools/check-gtk.sh":
        "needs docker — it compile-checks the GTK backend, which "
        "check-targets structurally cannot (gtk-sys wants the distro's "
        "pkg-config world). Run it by hand after any gtk.rs change",
}

# What the gates READ and must therefore be built from current sources
# BEFORE any of them runs. Order matters inside this list too: the
# interpreter build compiles against libkaya's header and loads the
# library at run time.
BUILD = [
    ("libkaya", ["cargo", "build", "--locked", "--lib"]),
    ("libkaya id", ["tools/build-id.sh", "--verify", "target/debug/libkaya.dylib"]),
    ("SwiftUI interpreter", ["tools/swiftui/build-dylib.sh"]),
]


class Truncated(list):
    """A list that reports its full length but stops iterating early.

    That is the shape of every under-run — the declaration says N, the
    loop delivers fewer — and it is how --selftest watches the count
    refuse WITHOUT a hook in the production path. There is no
    `stop_after` parameter on sweep() to get wrong: the real list is a
    plain list and the loop is the same loop.
    """

    def __init__(self, items, after):
        super().__init__(items)
        self.after = after

    def __iter__(self):
        return itertools.islice(list.__iter__(self), self.after)


def preflight(gates):
    """Everything that must be true before a single gate runs.

    A missing script is not a gate that fails, it is a LIST that lies,
    and the two want different messages: one says fix the code, the
    other says fix this file.
    """
    problems = []
    names = [g[0] for g in gates]
    for name in sorted(set(n for n in names if names.count(n) > 1)):
        problems.append(f"{name} is listed more than once")
    for name, cmd, _keyed, _why in gates:
        # Every PATH-SHAPED word in the command must be in the tree. That
        # is one rule for both spellings a gate takes — `tools/x.sh` and
        # `python3 bindings/…/y.py` — and it leaves an interpreter or a
        # bare builtin to the PATH, where it belongs.
        for word in cmd:
            if "/" in word and not (root / word).is_file():
                problems.append(f"{name}: {word} does not exist")
    return problems


def sweep(gates, label="gates"):
    """Run every gate; return True only if every declared one passed.

    COUNT IN, COUNT OUT. `declared` comes from the list itself and `ran`
    is incremented inside the loop, so the two disagree exactly when the
    loop did not deliver the whole list — which is the failure this
    whole file exists for. Nothing below prints OK without them equal.
    """
    declared = len(gates)
    problems = preflight(gates)
    if problems:
        for p in problems:
            print(f"{label}: PRE-FLIGHT {p}", file=sys.stderr)
        print(f"{label}: declared {declared}, ran 0, passed 0 — FAIL "
              f"(the list names something that is not there)", file=sys.stderr)
        return False

    ran = 0
    failed = []
    for name, cmd, keyed, _why in gates:
        argv = ["tools/keyed.sh", name, "--"] + cmd if keyed else list(cmd)
        print(f"[{ran + 1:02d}/{declared:02d}] {name}", flush=True)
        t0 = time.monotonic()
        rc = subprocess.call(argv, cwd=root)
        dt = time.monotonic() - t0
        ran += 1
        if rc == 0:
            print(f"        OK   {dt:5.1f}s", flush=True)
        else:
            failed.append(name)
            print(f"        FAIL rc={rc} {dt:5.1f}s", flush=True)

    passed = ran - len(failed)
    print(f"{label}: declared {declared}, ran {ran}, passed {passed}", flush=True)
    if ran != declared:
        print(f"{label}: THE SWEEP DID NOT RUN EVERY GATE IT DECLARED "
              f"({ran} of {declared}). A run that under-runs is not a pass — "
              f"that is what the count is for.", file=sys.stderr)
        return False
    if failed:
        print(f"{label}: FAILED: {' '.join(failed)}", file=sys.stderr)
        return False
    print(f"{label}: OK — {passed}/{declared}", flush=True)
    return True


def build():
    """Build what the gates read, before any of them reads it."""
    for what, cmd in BUILD:
        print(f"build: {what} ({' '.join(cmd)})", flush=True)
        if subprocess.call(cmd, cwd=root) != 0:
            print(f"gates: BUILD FAILED at {what} — no gate ran. A gate cannot "
                  f"verify something that was never built, and a lane that "
                  f"continued here would be reporting on the PREVIOUS run's "
                  f"artifacts.", file=sys.stderr)
            return False
    return True


def selftest():
    """Watch the refusals fire. Three properties, all of them the
    difference between a sweep and a sweep-shaped no-op:

      A. an all-green list reports OK with the counts equal
      B. ONE failing gate makes the whole verdict red
      C. a loop that delivers fewer gates than the list declares is red,
         and says so, even though every gate it did run passed
      D. a list naming a script that is not there never runs anything

    The commands are `true`/`false` rather than real gates: what is
    under test is this driver's arithmetic, and a hermetic command makes
    a wrong verdict unambiguous.
    """
    ok = True
    green = [("a", ["true"], False, "x"), ("b", ["true"], False, "x"),
             ("c", ["true"], False, "x")]
    red = [("a", ["true"], False, "x"), ("b", ["false"], False, "x"),
           ("c", ["true"], False, "x")]
    missing = [("a", ["true"], False, "x"),
               ("b", ["tools/check-there-is-no-such-gate.sh"], False, "x")]

    if not sweep(green, "selftest-A"):
        print("gates: SELF-TEST FAIL — an all-green list did not report OK",
              file=sys.stderr)
        ok = False
    if sweep(red, "selftest-B"):
        print("gates: SELF-TEST FAIL — a list with one FAILING gate reported OK; "
              "the sweep can false-green", file=sys.stderr)
        ok = False
    if sweep(Truncated(green, 1), "selftest-C"):
        print("gates: SELF-TEST FAIL — a loop that ran 1 of 3 declared gates "
              "reported OK; the count is decorative", file=sys.stderr)
        ok = False
    if sweep(missing, "selftest-D"):
        print("gates: SELF-TEST FAIL — a list naming a script that does not "
              "exist reported OK", file=sys.stderr)
        ok = False

    if ok:
        print("gates: SELF-TEST OK — the count refused an under-run (1 of 3), "
              "a failing gate and a missing script")
    return ok


if args == ["--list"]:
    print(json.dumps({
        "gates": [{"name": n, "cmd": c, "keyed": k, "unkeyed_because": w}
                  for n, c, k, w in GATES],
        "excluded": EXCLUDED,
    }, indent=2))
    sys.exit(0)

if args == ["--selftest"]:
    sys.exit(0 if selftest() else 1)

if args:
    sys.exit(f"gates.sh: unknown argument {args[0]!r} — "
             f"usage: gates.sh [--list | --selftest]")

print(f"gates: {len(GATES)} declared — building what they read first", flush=True)
if not build():
    sys.exit(1)
sys.exit(0 if sweep(GATES) else 1)
PY
