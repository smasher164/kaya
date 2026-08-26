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
# Why: a masked build failure leaves the PREVIOUS artifact in place and
# the lane runs green against code nobody wrote today (docs/traps.md has
# both times it happened).
#
# The id fingerprints INPUTS, not output. Two builds from one id can
# differ byte-for-byte; what it promises is the other direction — a
# DIFFERENT id means different sources, always.
#
# No dev-shell guard: this runs on the host, inside the Linux container,
# and out of build.rs during cross-compiles.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

exec python3 - "$ROOT" "$@" <<'PY'
import hashlib
import os
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
    # The SwiftUI interpreter: separately compiled, goes stale on its
    # own. Its inputs are its own sources plus the INTERFACE it compiles
    # against (kaya.h), not the core's implementation — a gtk.rs edit
    # does not change this dylib.
    "swiftui": ["swift", "crates/kaya/include"],
    # The Compose interpreter. android/kaya/src holds only sources
    # (gradle's outputs are in android/*/build, a SIBLING of src), so the
    # generated marker this id feeds cannot land inside its own inputs.
    "compose": ["android/kaya/src", "bindings/java"],
}

# What each GATE reads BEYOND the implicit set every one of them gets:
# tools/ plus flake.nix/flake.lock — see gate_key. Read by
# tools/keyed.sh.
#
# THE RULE FOR EDITING THIS TABLE: sets are deliberately
# OVER-approximate, whole directories rather than file lists. Naming too
# much costs a re-run nobody notices; naming too little hands back a
# PASS about code that changed since.
#
# Gates whose verdict depends on a BUILT ARTIFACT carry that artifact
# in ARTIFACT_GATES below, and their key mixes in the artifact's ACTUAL
# BYTES (ratified 2026-08-20): an unchanged source tree does not mean
# an unchanged answer, but unchanged sources AND unchanged artifact
# bytes do — the loophole the old never-key rule guarded is closed by
# hashing the real file instead of trusting the sources it claims to
# come from. check-build-id alone stays absent forever: its whole job
# is catching a stale artifact, and any cache of that answer is the
# defect it exists to find.
GATES = {
    "gen-header": ["crates", "Cargo.toml", "Cargo.lock"],
    "gen-bindings": ["crates", "bindings"],
    "gen-guests": ["crates", "bindings", "guests"],
    # The backends are inputs because check-steps stops demanding a
    # runner's legs where that runner's backend declares a depth stub, so
    # REMOVING a declaration is what makes the missing legs a failure.
    "check-steps": ["guests", "crates", "swift", "android"],
    "check-shell": [],
    "check-mirror": ["CLAUDE.md", "AGENTS.md"],
    # AGENTS.md is declared although this gate does not read it, per the
    # over-approximate rule: check-mirror holds the two identical.
    "check-gates": ["CLAUDE.md", "AGENTS.md"],
    "check-ledger": ["docs"],
    # bindings/ and go.mod: the go-android clause cross-builds a
    # single-main fixture against bindings/go, in its own module that
    # resolves dev.kaya through a filesystem replace.
    "check-targets": ["crates", "Cargo.toml", "Cargo.lock", ".cargo",
                      "bindings", "go.mod"],
    # guests/: the SCENE-TIER clause reads guests/*/entry.*.
    "check-sugar-surface": ["crates", "bindings", "guests"],
    "check-universal-props": ["crates", "bindings", "swift", "android"],
    # No binding sits between an authored role and the backends, so the
    # bindings are not inputs here. Same for check-native-undo.
    "check-roles": ["crates", "swift", "android"],
    "check-native-undo": ["crates", "swift", "android"],
    # No binding either: the card is a lowering, and swift/ is out
    # because the mac tier delineates natively and is not in the rule.
    "check-table-card": ["crates", "android"],
    # Every source root the diagnostic census walks: the gate notices a
    # NEW why-not by its name alone, so a key blind to one root would
    # hand back a stale PASS for the file that just grew one.
    "check-diagnostics": ["crates", "swift", "android", "bindings",
                          "guests", "cmd"],
    "check-verbs": ["crates", "bindings", "swift", "android"],
    # tools/checks/ too: its clause B compiles the probe that lives there.
    "check-harness-ceiling": ["crates", "swift", "android", "tools/checks"],
    "check-file-modes": ["crates", "bindings", "swift", "android"],
    "check-go-env": ["bindings", "guests"],
    "check-jni": ["crates", "android/kaya/src", "bindings/java-desktop"],
    # docs/: a depth stub is sanctioned only while docs/deferred.md holds
    # an OPEN entry for it, so STRIKING an entry through must fail.
    "check-stubs": ["crates", "swift", "android", "docs"],
    "check-staging": ["guests"],
    # gradle's :kaya sourceSet reaches ../../bindings/java and nothing
    # else outside android/.
    "check-compose": ["android", "bindings/java"],
    "check-detekt": ["android"],
    "check-pins": ["android"],
    # The INTERFACE, not the implementation: kaya.h and the swift
    # sources, never a backend. Sound because the header's own freshness
    # is gated by gen-header, which IS keyed on all of crates/.
    "swift-typecheck": ["crates/kaya/include", "bindings/swift",
                        "guests/swift", "swift"],
    "java-typecheck": ["bindings/java", "bindings/java-desktop",
                       "guests/java", "guests/java-desktop"],
    # The five ARTIFACT gates (see ARTIFACT_GATES): sources here, the
    # built bytes below, both in the key.
    "check-abort": ["crates", "bindings", "guests"],
    "check-wheel": ["crates", "bindings/python"],
    "check-empty-child": ["crates", "swift", "android"],
    "check-pane-ladder": ["crates", "swift"],
    "check-table-tier": ["crates", "swift"],
    # The fixture tools/check-keyed.sh exercises. A REAL entry on
    # purpose: a self-test stamping under a live gate's name would make
    # the next KAYA_FAST run skip that gate.
    "keyed-selftest": [],
}

# The BUILT files each artifact gate reads. The key mixes each one's
# EMBEDDED build-id marker — the fingerprint of the sources it was
# really built from — never the raw bytes: every relink mints a fresh
# LC_UUID, and gen-guests' every-sweep snapshot-restore touches source
# mtimes and triggers exactly such a relink, so a raw-byte key was
# measured never hitting at all (2026-08-20, keys fc2c5a7f ->
# 46f098b5 across one restore-and-noop-rebuild). A file with no marker
# or no file at all keys as that fact, and the gate then runs and
# fails its own checks loudly. KAYA_GATE_ARTIFACT_ROOT is check-keyed's
# self-test seam and nothing else's: it re-roots these paths so the
# negative can prove a marker flip busts the key without rebuilding a
# dylib.
ARTIFACT_GATES = {
    "check-abort": ["target/debug/libkaya.dylib"],
    "check-wheel": ["target/debug/libkaya.dylib"],
    "check-empty-child": ["target/debug/libkaya.dylib"],
    "check-pane-ladder": ["target/debug/libkaya.dylib"],
    "check-table-tier": ["target/debug/libkaya.dylib"],
}


def embedded_ids(p):
    """Every build-id marker in the file, sorted — the artifact's own
    statement of the sources it came from."""
    blob = p.read_bytes()
    found, at = set(), 0
    while (at := blob.find(PREFIX, at)) != -1:
        found.add(bytes(blob[at + len(PREFIX) : at + len(PREFIX) + 16]))
        at += len(PREFIX)
    return sorted(found)

# Anything skipped here is invisible to the id, so the list stays short:
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
    # tools/ rides every gate key: a gate whose own script changed must
    # not report the verdict its old self reached. The flake rides it too
    # — a gate's answer depends on the toolchain the dev shell supplied,
    # and a stamp says nothing about which shell wrote it.
    names = ["tools", "flake.nix", "flake.lock"] + GATES[name]
    paths = git_files(names)
    if paths is None:
        # No git: fall back to the walk. The key differs from git's and
        # includes build output, so the cache stops hitting — slow, never
        # wrong, which is the direction a fallback has to fail in.
        paths = files([n for n in names if (root / n).exists()])
    h = hashlib.sha256(digest(paths).encode())
    # The artifact half: the built file's EMBEDDED build-id — what it
    # was really built from — see ARTIFACT_GATES for why never the raw
    # bytes.
    artifact_root = pathlib.Path(os.environ.get("KAYA_GATE_ARTIFACT_ROOT", root))
    for rel in ARTIFACT_GATES.get(name, []):
        p = artifact_root / rel
        h.update(f"artifact:{rel}\0".encode())
        if not p.is_file():
            h.update(b"absent")
            continue
        ids = embedded_ids(p)
        h.update(b"|".join(ids) if ids else b"unmarked")
    return h.hexdigest()[:16]


PREFIX = b"kaya-build-id:"

if not args:
    sys.exit("usage: build-id.sh <component> | --gate NAME "
             "| --verify [--component NAME] FILE...")

if args[0] == "--gate":
    if len(args) != 2 or args[1] not in GATES:
        sys.exit(f"build-id: --gate wants one of: {', '.join(sorted(GATES))}")
    print(gate_key(args[1]))
    sys.exit(0)

if args[0] == "--gate-artifacts":
    # The census surface for check-keyed's clause 6: which built files
    # ride this gate's key. Empty output means none.
    if len(args) != 2 or args[1] not in GATES:
        sys.exit(f"build-id: --gate-artifacts wants one of: {', '.join(sorted(GATES))}")
    for rel in ARTIFACT_GATES.get(args[1], []):
        print(rel)
    sys.exit(0)

if args[0] != "--verify":
    if args[0] not in COMPONENTS:
        sys.exit(f"build-id: unknown component {args[0]!r} (have: {', '.join(COMPONENTS)})")
    print(build_id(args[0]))
    sys.exit(0)

# --verify: the artifact must carry the marker its builder baked in —
# crates/kaya/build.rs for the core, tools/swiftui/build-dylib.sh for
# the interpreter.
#
# One PREFIX for every component, and --component says which hash to
# expect. Per-component prefixes would let a file carrying the wrong
# component's marker read as "no build id" rather than as a mismatch.
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
    # An apk is a zip and its dex members are compressed, so the marker
    # is invisible in the raw file. Which classes*.dex a string lands in
    # is not stable either, so read them all.
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
        # Before crying STALE, check whether the file belongs to a
        # DIFFERENT component and is current there: a bare --verify
        # defaults to core, so running it on the swiftui dylib can never
        # pass, and the message must say which question to ask instead.
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
