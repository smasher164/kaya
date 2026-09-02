#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# THE FAST-GATE SWEEP. One entry point, one list, one verdict.
#
#   tools/gates.sh              build what the gates read, then run
#                               every gate and print a per-gate line
#                               and a count
#   tools/gates.sh --list       the list as JSON, for the tools that
#                               must agree with it (check-gates,
#                               check-keyed)
#   tools/gates.sh --selftest   watch the count refuse: an under-run,
#                               a failing gate and a missing script
#                               must all come back red
#
# TWO REFUSALS HOLD THIS UP.
#
# 1. The sweep KNOWS HOW MANY GATES IT DECLARED and will not report
#    success unless that many ran and that many passed. A hand-rolled
#    shell loop over a variable once ran 1 gate of 24 and printed a
#    clean run. --selftest watches the refusal fire.
# 2. The list and the build are the same file, in that order: a gate
#    cannot verify an artifact the run has not built yet, and the
#    build's exit status is load-bearing.
#
# THERE IS DELIBERATELY NO SUBSET FLAG — a flag that runs part of the
# list and still prints a verdict is defect 1 with an interface. To
# run one gate, run that gate; they are all standalone. (KAYA_FAST is
# the honest version, through tools/keyed.sh.)
#
# THE SWEEP IS macOS-SHAPED: it builds libkaya.dylib and the SwiftUI
# interpreter and three gates load them. The other four lanes run
# their own small per-lane subset instead, and check-gates.sh does not
# police that asymmetry.
#
# The census and its EXCLUDED table are importable data since the
# runner conversion (docs/runner-conversion-plan.md §4 item 4); the
# --list JSON stays as the interface the consumers already read.

import itertools
import json
import os
import subprocess
import time

os.chdir(ROOT)

# THE LIST, roughly cheapest-and-most-likely-to-fail first.
#
# `keyed` says whether the gate goes through tools/keyed.sh. An
# UNKEYED gate carries its reason HERE, beside itself — check-keyed
# enforces that the reason is written.
GATES = [
    ("gen-header", ["tools/gen-header.sh", "--check"], True, ""),
    ("gen-bindings", ["tools/gen-bindings.sh", "--check"], True, ""),
    ("gen-guests", ["tools/gen-guests.sh", "--check"], True, ""),
    ("check-steps", ["tools/check-steps.sh"], True, ""),
    # The Python surface's guard and mirror semantics, headless.
    ("kaya-app-checks", ["python3", "bindings/python/kaya_app_checks.py"], False,
     "sub-second and pure python; hashing an input set would cost more than "
     "the run it would skip"),
    # The JS surface's twin, in a worker (the import surrenders the main
    # thread otherwise; docs/js-plan.md §5).
    ("js-app-checks", ["node", "bindings/js/kaya_app_checks.ts"], False,
     "sub-second; hashing an input set would cost more than the run it "
     "would skip"),
    ("check-targets", ["tools/check-targets.sh"], True, ""),
    ("check-shell", ["tools/check-shell.sh"], True, ""),
    # check-shell's opposite number: the gate bodies are python now
    # (docs/deferred.md's 2026-08-27 ruling), which retires the `$?` class
    # and puts swallowed exceptions, shell=True, implicit encodings and a
    # mid-gate exit(0) in its place. It also runs the prelude's own
    # negatives, so the file every converted gate imports proves its
    # refusals on a path nobody can avoid.
    ("check-python", ["tools/check-python.sh"], True, ""),
    ("check-mirror", ["tools/check-mirror.sh"], True, ""),
    ("check-gates", ["tools/check-gates.sh"], True, ""),
    # The ledger may not disagree with itself — an unstruck headline
    # over a body recording the work COMPLETE sends a survey after a
    # solved problem.
    ("check-ledger", ["tools/check-ledger.sh"], True, ""),
    # The other half: a doc citing a path the tree does not have.
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
    # MENU_ROLES is one line no generator reads, so a role can ship with
    # the root accepting it and every backend ignoring it. RED BY DESIGN
    # across a fan-out.
    ("check-roles", ["tools/check-roles.sh"], True, ""),
    # The native undo tier's two guards, which NO shared scene can
    # reach: static pairing is the only wall available.
    ("check-native-undo", ["tools/check-native-undo.sh"], True, ""),
    # A why-not that can print only one sentence prints it for every
    # cause it cannot name, and the reader believes it.
    ("check-diagnostics", ["tools/check-diagnostics.sh"], True, ""),
    # The harness loses legibly: a step that never returns publishes a
    # verdict and leaves, in all three harnesses. NO SCENE CAN FAIL IT —
    # the wedge would have to happen on every platform at once and would
    # measure nothing else (docs/measurements/choke-*-2026-08-24.txt).
    ("check-harness-ceiling", ["tools/check-harness-ceiling.sh"], True, ""),
    # ONE NODE IS ONE WIDGET, even when its content will not decode: in
    # the declarative backends "render nothing" makes the node LEAVE THE
    # TREE and every positional reader above it reads the wrong child
    # (docs/deferred.md).
    # The five ARTIFACT gates are keyed since 2026-08-20: their keys mix
    # the built libkaya's REAL BYTES (build-id.sh's ARTIFACT_GATES), so
    # "unchanged sources" alone can no longer hand back a stale PASS —
    # unchanged sources AND unchanged artifact bytes can, and that is an
    # unchanged answer.
    ("check-empty-child", ["tools/check-empty-child.sh"], True, ""),
    # The macOS pane ladder: no column minimum ever declared to SwiftUI,
    # and the middle rung — which no shared scene may sample — walked
    # for real in an NSWindow (docs/multicolumn-plan.md).
    ("check-pane-ladder", ["tools/check-pane-ladder.sh"], True, ""),
    # The table tier routing: both tiers present identical bytes, so no
    # device can name the one that drew it (docs/traps.md). The rule is a
    # pure function, driven here through its whole truth table.
    ("check-table-tier", ["tools/check-table-tier.sh"], True, ""),
    # KAYA RASTERIZES, BACKENDS BLIT (docs/canvas-plan.md §1.1): a
    # backend that interpreted an op would draw the same picture, a wrong
    # pixel format survives a symmetric probe point, and a rounded scale
    # is invisible on every lane this project runs.
    ("check-canvas-blit", ["tools/check-canvas-blit.sh"], False,
     "no input set is declared for it in build-id.sh's GATES; same shape as "
     "check-tx-liveness below"),
    # KAYA_APPEARANCE is inert unless asked for, and the backend still
    # reads the platform back when it is — no lane can see either half go
    # wrong, since every lane host is light.
    ("check-appearance", ["tools/check-appearance.sh"], False,
     "no input set is declared for it in build-id.sh's GATES; same shape as "
     "check-tx-liveness below"),
    ("check-wheel", ["tools/check-wheel.sh"], True, ""),
    ("check-abort", ["tools/check-abort.sh"], True, ""),
    ("check-tx-liveness", ["tools/check-tx-liveness.sh"], False,
     "no input set is declared for it in build-id.sh's GATES, so keyed.sh "
     "would refuse at run time; it is a pure source scan and can be keyed "
     "the day someone declares its inputs"),
    ("check-ambient-tx", ["tools/check-ambient-tx.sh"], False,
     "no input set is declared for it in build-id.sh's GATES; same shape as "
     "check-tx-liveness above"),
    # A Go guest reads the HOST's environment, never Go's copy: in a
    # c-shared library os.Getenv is empty forever, and an empty
    # KAYA_SELFTEST is the default arm, not an unknown scene.
    ("check-go-env", ["tools/check-go-env.sh"], True, ""),
    ("check-build-id", ["tools/check-build-id.sh"], False,
     "it inspects the built libkaya and the built interpreter; this is THE "
     "gate that must never be answered from a cache"),
    ("check-keyed", ["tools/check-keyed.sh"], False,
     "it is the cache's own gate — a cached verdict about the cache is "
     "worth nothing"),
    ("check-pins", ["tools/check-pins.sh"], True, ""),
    # BOTH macOS design generations stay on the mac lane: SwiftUI reads
    # the MAIN EXECUTABLE's sdk stamp, so the kaya-linked legs are
    # modern and the vendor-built hosts hold the compat side.
    ("check-design-generation", ["tools/check-design-generation.sh"], False,
     "its inputs are the toolchain and the vendor hosts on the machine, not "
     "files in this tree — a source-keyed skip would go quiet exactly when a "
     "nixpkgs or vendor rebuild moved a stamp, which is the move it exists to "
     "catch"),
    # An SF Symbols name above the OS floor renders BLANK on the floor
    # and resolves fine on every machine the project has — no scene can
    # see it; only Apple's own availability plist can answer.
    ("check-symbols", ["tools/check-symbols.sh"], False,
     "half its input is /System's name_availability.plist, which moves with "
     "the OS rather than the tree — check-design-generation's shape"),
    # ONE symbol vocabulary, SIX files: wire::SYMBOLS is not in the spec
    # hash, so a concept added to five of six sites fails nowhere and
    # renders as a missing glyph on the sixth platform alone.
    ("check-symbol-parity", ["tools/check-symbol-parity.sh"], False,
     "no input set is declared for it in build-id.sh's GATES; same shape as "
     "check-tx-liveness above"),
    # The Windows accent near-no-op: a bare SystemAccentColor write
    # changes the text-selection highlight and nothing else, invisibly
    # to every lane. Fast-sweep sibling of winui::tests' rendered check
    # on the windows guest.
    ("check-accent", ["tools/check-accent.sh"], False,
     "no input set is declared for it in build-id.sh's GATES; same shape as "
     "check-tx-liveness above"),
    # A table bounds its own extent, in all three synthesized tiers. The
    # card is PIXELS: every table observable answers the same with it
    # gone, so no lane can see a backend that lost it.
    ("check-table-card", ["tools/check-table-card.sh"], True, ""),
    ("check-verbs", ["tools/check-verbs.sh"], True, ""),
    # The file-mode numbers against the spec that owns them: five
    # hand-written sites decode the integer kaya_open_picked takes.
    ("check-file-modes", ["tools/check-file-modes.sh"], True, ""),
    # ONE DECLARED IDENTITY, READ BY A BUILD AND BY A RUNNING APP:
    # guests/assets/identity.toml held level with every hand-written
    # copy of it, and the byte-frozen scene expectation level with the
    # mark's actual pixels.
    ("check-app-identity", ["tools/check-app-identity.sh"], False,
     "one of its clauses walks every path in the tree looking for app-icon "
     "resources, so any add, delete or rename is a real input — check-case's "
     "shape, and a key that cheap to invalidate is a cache that never hits"),
    # THE ASSET ROOT'S DRIFT GATE (docs/assets-plan.md A6): nothing else
    # resolves an asset for itself, and every lane that carries the root
    # carries all of it. Neither is checkable from inside the core.
    ("check-assets", ["tools/check-assets.sh"], False,
     "one of its clauses walks every source root looking for a second "
     "resolver and another walks the asset root itself, so any add, delete "
     "or rename anywhere is a real input — check-app-identity's shape, and a "
     "key that cheap to invalidate is a cache that never hits"),
    ("check-jni", ["tools/check-jni.sh"], True, ""),
    ("check-stubs", ["tools/check-stubs.sh"], True, ""),
    ("check-staging", ["tools/check-staging.sh"], True, ""),
    # The C floor has no allocator, and scene.rs's two maps make a
    # widget/node id collision legal at the core — so it renders
    # correctly and no lane can see it. All eight guests overlapped
    # until 2026-08-25.
    ("check-c-ids", ["tools/check-c-ids.sh"], True, ""),
    # The C floor refuses past its cap instead of smashing past it. Every
    # in-tree guest sizes its buffers right, so the wire bytes are the
    # same either way and no lane, scene or capture can see the check at
    # all — the unchecked memcpy shipped from milestone 0 under green.
    ("check-c-bounds", ["tools/check-c-bounds.sh"], True, ""),
    ("check-compose", ["tools/check-compose.sh"], True, ""),
    ("check-detekt", ["tools/check-detekt.sh"], True, ""),
    ("check-compose-state", ["tools/check-compose-state.sh"], True, ""),
    ("swift-typecheck", ["tools/swift-typecheck.sh"], True, ""),
    ("java-typecheck", ["tools/java-typecheck.sh"], True, ""),
    ("js-typecheck", ["tools/js-typecheck.sh"], True, ""),
]

# Gate scripts on disk that are deliberately NOT in the sweep. The
# reason is required and check-gates.sh reads it.
EXCLUDED = {
    "tools/check-gtk.sh":
        "needs docker — it compile-checks the GTK backend, which "
        "check-targets structurally cannot (gtk-sys wants the distro's "
        "pkg-config world). Run it by hand after any gtk.rs change",
}

# What the gates READ, built from current sources BEFORE any of them
# runs. Order matters: the interpreter compiles against libkaya's
# header and loads the library at run time.
BUILD = [
    # Derived, never committed (maintainer 2026-08-24): the market data
    # regenerates only when its generator's bytes move; check-assets
    # holds the stamp honest.
    ("market data", ["python3", "tools/gen-market.py", "--ensure"]),
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
        # Every PATH-SHAPED word must be in the tree; an interpreter
        # or a bare builtin is left to the PATH.
        for word in cmd:
            if "/" in word and not (ROOT / word).is_file():
                problems.append(f"{name}: {word} does not exist")
    return problems


def sweep(gates, label="gates"):
    """Run every gate; return True only if every declared one passed.

    COUNT IN, COUNT OUT. `declared` comes from the list itself and
    `ran` is incremented inside the loop, so the two disagree exactly
    when the loop did not deliver the whole list — which is the
    failure this whole file exists for. Nothing below prints OK
    without them equal.
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
        rc = subprocess.call(argv, cwd=ROOT)
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
        if subprocess.call(cmd, cwd=ROOT) != 0:
            print(f"gates: BUILD FAILED at {what} — no gate ran. A gate cannot "
                  f"verify something that was never built, and a lane that "
                  f"continued here would be reporting on the PREVIOUS run's "
                  f"artifacts.", file=sys.stderr)
            return False
    return True


def selftest():
    """Watch the refusals fire. Four properties, all of them the
    difference between a sweep and a sweep-shaped no-op:

      A. an all-green list reports OK with the counts equal
      B. ONE failing gate makes the whole verdict red
      C. a loop that delivers fewer gates than the list declares is
         red, and says so, even though every gate it did run passed
      D. a list naming a script that is not there never runs anything

    The commands are `true`/`false` rather than real gates: what is
    under test is this driver's arithmetic, and a hermetic command
    makes a wrong verdict unambiguous.
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


def fingerprint():
    """One hash over every keyed gate's key, in name order: the token
    validate-all hands the mac lane after running this sweep itself.
    The keyed keys' input sets jointly cover every source root a gate
    reads (tools/ and the flake ride each one), so any edit between
    the sweep and the mac lane's start changes this value and the lane
    re-runs the gates instead of skipping them."""
    import hashlib
    h = hashlib.sha256()
    for n, _c, k, _w in sorted(GATES):
        if not k:
            continue
        key = subprocess.run(
            ["tools/build-id.sh", "--gate", n],
            stdout=subprocess.PIPE, text=True, check=False)
        if key.returncode != 0:
            print(f"gates.sh: --fingerprint could not key {n}",
                  file=sys.stderr)
            return None
        h.update(f"{n}={key.stdout.strip()}\n".encode())
    return h.hexdigest()[:16]


def main(args):
    if args == ["--list"]:
        print(json.dumps({
            "gates": [{"name": n, "cmd": c, "keyed": k, "unkeyed_because": w}
                      for n, c, k, w in GATES],
            "excluded": EXCLUDED,
        }, indent=2))
        return 0

    if args == ["--selftest"]:
        return 0 if selftest() else 1

    if args == ["--build"]:
        # validate-all's t0: the keyed keys carry the artifacts' REAL
        # bytes, so the token is taken only after the same builds the
        # sweep itself starts with.
        return 0 if build() else 1
    if args == ["--fingerprint"]:
        fp = fingerprint()
        if fp is None:
            return 1
        print(fp)
        return 0

    if args:
        print(f"gates.sh: unknown argument {args[0]!r} — "
              f"usage: gates.sh [--list | --selftest | --fingerprint | --build]",
              file=sys.stderr)
        return 1

    print(f"gates: {len(GATES)} declared — building what they read first",
          flush=True)
    if not build():
        return 1
    return 0 if sweep(GATES) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
