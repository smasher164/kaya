#!/usr/bin/env bash

# The identity of a build's INPUTS — a hash over every source file that
# feeds an artifact, and a way to ask a built file which sources it came
# from. Two modes, one implementation:
#
#   tools/build-id.sh core             prints the id; crates/kaya/build.rs
#                                      bakes it into the library
#   tools/build-id.sh --verify FILE…   each file must CARRY the current
#                                      id, or the build that produced it
#                                      never happened
#
# Why: a masked build failure leaves the PREVIOUS artifact in place, and
# the lane then runs green against code nobody wrote today. That has
# happened twice — the build piped through `tail` (whose exit status the
# pipeline adopted) and the gradle build filtered through `grep -E
# "^e:"`, both in docs/traps.md — and both times the run looked fine. A
# convention ("always check the exit status") only holds while everyone
# remembers it. This turns "did this artifact come from my tree?" into a
# question with an answer.
#
# The id is a fingerprint of INPUTS, not a claim of bit-identical
# OUTPUT. Two builds from one id can still differ byte-for-byte (build
# paths, timestamps, codegen nondeterminism); what the id promises is
# the direction that matters here — a DIFFERENT id means different
# sources, always.
#
# No dev-shell guard here: this runs on the host, inside the Linux
# container, and out of build.rs during cross-compiles. It is a pure
# function of the tree, and a guard that refuses in two of those three
# places would just push callers into hand-rolling the hash.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

exec python3 - "$ROOT" "$@" <<'PY'
import hashlib
import pathlib
import zipfile
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]

# What each artifact is BUILT FROM. Cargo.lock is an input, not an
# output: the resolved dependency graph is compiled into the library, so
# a lockfile change is a source change.
COMPONENTS = {
    "core": ["crates", "Cargo.toml", "Cargo.lock"],
    # The SwiftUI interpreter: a SEPARATELY COMPILED artifact that both
    # Apple lanes load, and one that goes stale on its own — swiftc
    # failing leaves the previous dylib exactly where the previous
    # cargo failure left the previous libkaya. Its inputs are its own
    # sources plus the INTERFACE it compiles against (kaya.h), not the
    # core's implementation: a gtk.rs edit does not change this dylib.
    "swiftui": ["swift", "crates/kaya/include"],
    # The Compose interpreter, the Android sibling of the above.
    # android/kaya/src holds only sources — gradle's outputs are in
    # android/*/build, a SIBLING of src — so the generated marker file
    # this id feeds cannot end up inside its own inputs.
    "compose": ["android/kaya/src", "bindings/java"],
}

# What each GATE reads BEYOND the implicit set every one of them gets:
# tools/ (the gates and runners themselves) plus flake.nix/flake.lock
# (the toolchain that produced the verdict) — see gate_key. Used by
# tools/keyed.sh to skip a gate whose world has not moved since it last
# passed.
#
# These sets are deliberately OVER-approximate — whole directories, not
# file lists. The asymmetry is the whole safety argument: naming too
# much costs a re-run nobody notices, and naming too little hands back a
# PASS about code that changed since. A precise key is a key that can be
# wrong, so precision is not the goal here; more KEYS is (each gate
# separately keyed is what stops a gtk.rs edit from re-running the
# Kotlin gates).
#
# Gates whose verdict depends on a BUILT ARTIFACT are absent on purpose
# and must stay absent: check-abort, check-wheel and check-build-id all
# load or inspect target/, so an unchanged source tree does not mean an
# unchanged answer.
GATES = {
    "gen-header": ["crates", "Cargo.toml", "Cargo.lock"],
    "gen-bindings": ["crates", "bindings"],
    "gen-guests": ["crates", "bindings", "guests"],
    # The backends are inputs because check-steps stops demanding a
    # runner's legs where that runner's backend declares a depth stub —
    # so REMOVING a declaration is what makes the missing legs a failure,
    # and a key that did not read the backends would hand back the stale
    # PASS exactly then.
    #
    # The verb-feature cross-check (2026-08-05) reads three more things
    # and NONE of them widens this set, which is worth writing down so
    # the next reader does not re-derive it: tools/scenes and the five
    # runners are under tools/, which rides every gate key; and
    # ROLE_FEATURE is pinned against MENU_ROLES in
    # crates/kaya/src/scene.rs, which is already inside crates/.
    "check-steps": ["guests", "crates", "swift", "android"],
    "check-shell": [],
    "check-mirror": ["CLAUDE.md", "AGENTS.md"],
    "check-targets": ["crates", "Cargo.toml", "Cargo.lock", ".cargo"],
    # guests/ joined this set when the gate grew its SCENE-TIER clause
    # (the example scenes must USE the sugar, not only the bindings
    # OFFER it): the clause reads guests/*/entry.*, so a key blind to
    # guests/ would hand back a stale PASS for exactly the edit the
    # clause exists to catch.
    "check-sugar-surface": ["crates", "bindings", "guests"],
    "check-universal-props": ["crates", "bindings", "swift", "android"],
    # The role vocabulary (crates/kaya/src/scene.rs) against the four
    # backends that must know it. Same set as check-verbs minus the
    # bindings: an authored role reaches the backends through the wire,
    # so no binding sits between them.
    "check-roles": ["crates", "swift", "android"],
    # The native-undo pairing, over the same four backend files as
    # check-roles and for the same reason: the property is entirely
    # backend-side, and no binding sits between the core seam and the
    # arm that calls it.
    "check-native-undo": ["crates", "swift", "android"],
    "check-verbs": ["crates", "bindings", "swift", "android"],
    # The JNI registration cross-check reads the two rust registration
    # modules, the Kotlin classes and the desktop Java class.
    "check-jni": ["crates", "android/kaya/src", "bindings/java-desktop"],
    # docs/ joined this set when the gate grew the STUB-IMPLIES-LEDGER
    # clause (2026-08-05): a depth stub is sanctioned only while
    # docs/deferred.md holds an OPEN entry for it, so STRIKING an entry
    # through is now a change that must fail the gate. A key blind to the
    # ledger would hand back a stale PASS for exactly that edit — the
    # same shape as the guests/ widening on check-sugar-surface. The
    # whole directory rather than the one file, following this table's
    # own rule: over-approximating costs a re-run nobody notices, and it
    # survives the ledger ever splitting in two.
    "check-stubs": ["crates", "swift", "android", "docs"],
    # gradle's :kaya sourceSet reaches ../../bindings/java and nothing
    # else outside android/.
    "check-compose": ["android", "bindings/java"],
    "check-detekt": ["android"],
    "check-pins": ["android"],
    # The INTERFACE, not the implementation: this reads kaya.h and the
    # swift sources, never a backend. That is the early cutoff — a
    # gtk.rs edit stops re-running it — and it is sound because the
    # header is a checked-in artifact whose own freshness is gated by
    # gen-header, which IS keyed on all of crates/. A stale header can
    # never reach this gate looking current.
    "swift-typecheck": ["crates/kaya/include", "bindings/swift",
                        "guests/swift", "swift"],
    "java-typecheck": ["bindings/java", "bindings/java-desktop",
                       "guests/java", "guests/java-desktop"],
    # The fixture tools/check-keyed.sh exercises. It is a REAL entry
    # rather than a doctored copy of a real gate's name on purpose:
    # a self-test that wrote a stamp under "check-mirror" would make
    # the next KAYA_FAST run skip the actual gate, which is the very
    # false PASS this whole mechanism exists to avoid.
    "keyed-selftest": [],
}

# Build outputs and editor debris under a source root. Anything skipped
# here is invisible to the id, so the list stays short and boring —
# over-skipping is how an id starts lying.
SKIP_DIRS = {"target", "target-linux", "__pycache__", ".git"}


def git_files(names):
    """The tracked and not-ignored files under `names`, or None if git
    cannot answer. Preferred over walking for GATE keys, whose roots
    (tools/, android/, guests/) hold build directories that a hand-kept
    denylist would have to chase forever — tools/ alone walks to 53k
    files and 213 tracked ones. Letting .gitignore decide means a source
    directory can never be hidden by a name that happens to look like an
    output (`bin/`, `build/`).

    safe.directory: inside the container the repo is mounted with a
    foreign owner, and git refuses to operate on it otherwise."""
    cmd = ["git", "-c", "safe.directory=*", "ls-files", "-z", "-c", "-o",
           "--exclude-standard", "--", *names]
    try:
        out = subprocess.run(cmd, cwd=root, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=False)
    except OSError:
        return None
    if out.returncode != 0:
        return None
    # `-c` reports index entries whose worktree file is gone; a deletion
    # changes the digest by its bytes leaving, so dropping them here is
    # right.
    return sorted(p for p in (root / n for n in out.stdout.decode().split("\0") if n)
                  if p.is_file())


def files(names):
    out = []
    for name in names:
        p = root / name
        if p.is_file():
            out.append(p)
        elif p.is_dir():
            for f in p.rglob("*"):
                if f.is_file() and not (SKIP_DIRS & set(f.relative_to(root).parts)):
                    out.append(f)
        else:
            sys.exit(f"build-id: {name} is neither file nor directory under {root}")
    # Sorted by path so the id does not depend on directory order.
    return sorted(out)


def digest(paths):
    h = hashlib.sha256()
    for f in paths:
        rel = str(f.relative_to(root)).replace("\\", "/")
        body = f.read_bytes()
        # Length-delimited: a rename or a byte moving across a file
        # boundary has to change the digest.
        h.update(f"{rel}\0{len(body)}\0".encode())
        h.update(body)
    return h.hexdigest()[:16]


def build_id(component):
    return digest(files(COMPONENTS[component]))


def gate_key(name):
    # tools/ rides every gate key: the gates ARE tools/, and a gate whose
    # own script changed must not report the verdict its old self reached.
    #
    # The flake rides it too, and for a subtler reason: a gate's answer
    # depends on the TOOLCHAIN that produced it — gradle, swiftc, javac,
    # detekt all come from the dev shell — and none of that is under
    # tools/. Every gate already refuses to run outside the shell, but
    # that check happens at invocation and says nothing about a stamp
    # written by an earlier shell. Without these two files a toolchain
    # bump would leave every stored verdict standing.
    names = ["tools", "flake.nix", "flake.lock"] + GATES[name]
    paths = git_files(names)
    if paths is None:
        # No git (or a refusal): fall back to the walk. The key will
        # differ from git's and include build output, so the cache simply
        # stops hitting — slow, never wrong, which is the direction a
        # fallback has to fail in.
        paths = files([n for n in names if (root / n).exists()])
    return digest(paths)


PREFIX = b"kaya-build-id:"

if not args:
    sys.exit("usage: build-id.sh <component> | --gate NAME "
             "| --verify [--component NAME] FILE...")

if args[0] == "--gate":
    if len(args) != 2 or args[1] not in GATES:
        sys.exit(f"build-id: --gate wants one of: {', '.join(sorted(GATES))}")
    print(gate_key(args[1]))
    sys.exit(0)

if args[0] != "--verify":
    if args[0] not in COMPONENTS:
        sys.exit(f"build-id: unknown component {args[0]!r} (have: {', '.join(COMPONENTS)})")
    print(build_id(args[0]))
    sys.exit(0)

# --verify: the artifact must carry the marker its builder baked in —
# crates/kaya/build.rs for the core, tools/swiftui/build-dylib.sh for
# the interpreter. Absent means the file predates the marker or was
# never built from this component at all; wrong means it is a leftover
# from an earlier tree, which is the whole point of looking.
#
# One PREFIX for every component, and --component says which hash to
# expect. Per-component prefixes would let a file carrying the wrong
# component's marker read as "no build id" rather than as the mismatch
# it is.
component = "core"
if len(args) > 2 and args[1] == "--component":
    component = args[2]
    if component not in COMPONENTS:
        sys.exit(f"build-id: unknown component {component!r} "
                 f"(have: {', '.join(COMPONENTS)})")
    args = args[:1] + args[3:]
want = build_id(component).encode()
status = 0
for name in args[1:]:
    p = pathlib.Path(name)
    if not p.is_file():
        print(f"build-id: {name}: MISSING — the build that produces it did not run", file=sys.stderr)
        status = 1
        continue
    # An apk is a zip, and its dex members are compressed — the marker
    # is not visible in the raw file. Which classes*.dex a string lands
    # in is not stable either (this apk is multidex and dev.kaya's
    # strings are in classes3.dex), so read them all.
    if zipfile.is_zipfile(p):
        with zipfile.ZipFile(p) as z:
            blob = b"".join(z.read(n) for n in z.namelist() if n.endswith(".dex"))
    else:
        blob = p.read_bytes()
    found, at = set(), 0
    while (at := blob.find(PREFIX, at)) != -1:
        found.add(blob[at + len(PREFIX) : at + len(PREFIX) + 16])
        at += len(PREFIX)
    if want in found:
        continue
    status = 1
    if not found:
        print(f"build-id: {name}: NO build id — nothing here was built "
              f"from {component}", file=sys.stderr)
    else:
        # Before crying STALE, check whether the file simply belongs to a
        # DIFFERENT component and is current there. A bare --verify
        # defaults to core, and running it on the swiftui dylib can never
        # pass — it compares the swiftui id against the core's. Two
        # separate agents hit exactly that, and each spent time
        # "fixing" an artifact that was already current (the haskell
        # fan-out arm's deviation 1, then the fresh-key depth arm's F2).
        # The verifier knows every component's current id, so it can say
        # which question the caller should have asked.
        others = [c for c in COMPONENTS if c != component
                  and build_id(c).encode() in found]
        carried = ", ".join(sorted(f.decode("ascii", "replace") for f in found))
        print(
            f"build-id: {name}: STALE — carries {carried}, but {component} "
            f"in this tree is {want.decode()}",
            file=sys.stderr,
        )
        if others:
            print(
                f"  BUT that is {others[0]}'s CURRENT id — this file looks "
                f"like the {others[0]} component; did you mean "
                f"--component {others[0]}?",
                file=sys.stderr,
            )
        else:
            print(
                "  the build step that should have refreshed it did not run, "
                "or failed with its exit status masked",
                file=sys.stderr,
            )
sys.exit(status)
PY
