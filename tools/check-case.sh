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
# EVERY TRACKED PATH MUST MATCH THE FILESYSTEM'S CASE EXACTLY.
#
# THE DEFECT THIS EXISTS FOR (2026-07-28, the background-work sweep).
# A Haskell guest was created as `Background.hs` while its cabal stanza
# said `main-is: background.hs`. macOS's filesystem is case-INSENSITIVE,
# so the local build found it, the scene ran, and validate-mac went
# green. Linux is case-SENSITIVE and would have failed — after a full
# matrix run, on the lane furthest from the change.
#
# The class is general and nastier than one typo: every build manifest
# in this repo names files as strings — cabal `main-is`, dune `modules`,
# Cargo `path`, csproj globs, gradle sources, the Makefile's SCENES. Any
# of them can disagree with the filesystem in case alone and no macOS
# tool will say so. A case-only RENAME is worse still: git records the
# old name and `mv` is a no-op, so the mismatch survives a fix that
# looks like it worked (the rename must go through a temp path).
#
# Cheap to check because git already stores the exact bytes of every
# tracked path: compare them against what the directory actually
# contains, case-sensitively, in python rather than the shell.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

lint() {
    # $1: a newline-separated list of paths (or - for stdin). Prints
    # offenders, returns 1 on any.
    python3 -c '
import os
import sys

paths = sys.stdin.read().split("\n") if sys.argv[1] == "-" else open(sys.argv[1]).read().split("\n")
bad = []
# One listing per directory, reused: a repo-wide walk otherwise costs a
# stat per path per component.
listings = {}
for path in paths:
    if not path:
        continue
    parent, name = os.path.split(path)
    key = parent or "."
    if key not in listings:
        try:
            listings[key] = set(os.listdir(key))
        except OSError:
            listings[key] = set()
    entries = listings[key]
    if name in entries:
        continue
    # Present only under a different case is THE defect; absent
    # entirely is someone else`s problem (a deleted file mid-rebase).
    lower = {e.lower(): e for e in entries}
    actual = lower.get(name.lower())
    if actual is not None:
        bad.append(f"{path}: git says {name!r}, the filesystem says {actual!r}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself, both directions: a case-only mismatch must be
# caught, and an exact match must NOT be.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/case"
touch "$T/case/background.hs"
if printf '%s\n' "$T/case/Background.hs" | lint - >/dev/null; then
    echo "check-case: SELF-TEST FAIL (a case-only mismatch passed)" >&2
    exit 1
fi
if ! printf '%s\n' "$T/case/background.hs" | lint - >/dev/null; then
    echo "check-case: SELF-TEST FAIL (an exact match was rejected)" >&2
    exit 1
fi

if ! git ls-files -z | tr '\0' '\n' | lint -; then
    echo "check-case: a tracked path disagrees with the filesystem in CASE." >&2
    echo "check-case: macOS will not notice; Linux will fail the lane. Rename" >&2
    echo "check-case: THROUGH A TEMP PATH — a case-only mv is a no-op here." >&2
    exit 1
fi
echo "check-case: OK"
