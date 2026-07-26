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
import sys

root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]

# What each artifact is BUILT FROM. Cargo.lock is an input, not an
# output: the resolved dependency graph is compiled into the library, so
# a lockfile change is a source change.
COMPONENTS = {
    "core": ["crates", "Cargo.toml", "Cargo.lock"],
}

# Build outputs and editor debris under a source root. Anything skipped
# here is invisible to the id, so the list stays short and boring —
# over-skipping is how an id starts lying.
SKIP_DIRS = {"target", "target-linux", "__pycache__", ".git"}


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


def build_id(component):
    h = hashlib.sha256()
    for f in files(COMPONENTS[component]):
        rel = str(f.relative_to(root)).replace("\\", "/")
        body = f.read_bytes()
        # Length-delimited: a rename or a byte moving across a file
        # boundary has to change the digest.
        h.update(f"{rel}\0{len(body)}\0".encode())
        h.update(body)
    return h.hexdigest()[:16]


PREFIX = b"kaya-build-id:"

if not args:
    sys.exit("usage: build-id.sh <component> | --verify FILE...")

if args[0] != "--verify":
    if args[0] not in COMPONENTS:
        sys.exit(f"build-id: unknown component {args[0]!r} (have: {', '.join(COMPONENTS)})")
    print(build_id(args[0]))
    sys.exit(0)

# --verify: the artifact must carry the marker crates/kaya/build.rs
# baked in. Absent means the file predates the marker or was never
# linked against the core; wrong means it is a leftover from an earlier
# tree, which is the whole point of looking.
want = build_id("core").encode()
status = 0
for name in args[1:]:
    p = pathlib.Path(name)
    if not p.is_file():
        print(f"build-id: {name}: MISSING — the build that produces it did not run", file=sys.stderr)
        status = 1
        continue
    blob = p.read_bytes()
    found, at = set(), 0
    while (at := blob.find(PREFIX, at)) != -1:
        found.add(blob[at + len(PREFIX) : at + len(PREFIX) + 16])
        at += len(PREFIX)
    if want in found:
        continue
    status = 1
    if not found:
        print(f"build-id: {name}: NO build id — not linked against the kaya core", file=sys.stderr)
    else:
        carried = ", ".join(sorted(f.decode("ascii", "replace") for f in found))
        print(
            f"build-id: {name}: STALE — built from {carried}, this tree is {want.decode()}",
            file=sys.stderr,
        )
        print(
            "  the build step that should have refreshed it did not run, or "
            "failed with its exit status masked",
            file=sys.stderr,
        )
sys.exit(status)
PY
