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
# Lint the shared .steps scripts: container-kind targets index widgets
# by CREATION order, which legitimately differs per language
# (statement-shaped construction is parent-first, expression trees are
# children-first — argument evaluation forces it). Leaf kinds are safe
# (body order is screen order everywhere); containers are targetable
# only through the blessed pattern — column#0, the For container that
# the root-is-a-row convention keeps unique. Anything else would name
# different widgets on different platforms, so it dies here, not in
# one platform's leg.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

lint() {
    # $1: a steps file (or - for stdin). Prints offenders, returns 1 on any.
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []
for lineno, line in enumerate(text.splitlines(), 1):
    if line.lstrip().startswith("#"):
        continue
    for kind, index in re.findall(r"\b(row|column|scroll)#(\d+)\b", line):
        # Index 0 of a container kind is the blessed pattern, on one
        # convention: the scene keeps exactly one widget of that
        # kind, so creation order cannot enter. column#0 is the For
        # container in milestone2 (root-is-a-row keeps it unique);
        # row#0 carries the horizontal grow contract in the grow
        # scene; scroll#0 the one scroll viewport in the scroll scene.
        if index == "0":
            continue
        bad.append(f"{path}:{lineno}: {kind}#{index}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself: a known-bad sample must fail, or the lint
# is a false green.
if printf 'click row#1\nexpect column#2 "x"\n' | lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (bad sample passed)" >&2
    exit 1
fi

status=0
for f in tools/scenes/*.steps; do
    out="$(lint "$f")" || {
        echo "check-steps: $f targets a container by creation index — only column#0/row#0 (unique-by-convention containers) are cross-language stable:" >&2
        echo "$out" >&2
        status=1
    }
done

# The opening lint: a script must OPEN with an observation. Expects
# are bounded retries (harness.rs POLL_DEADLINE), and the FIRST one
# doubles as the scene-ready wait — a script that opens with an
# action races the mount on every platform at once (scripted settles
# are gone; retries replaced them, 2026-07-22).
opening_lint() {
    python3 -c '
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
for line in text.splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    first = stripped.split(";")[0].split()
    verb = first[0] if first else ""
    if verb.startswith("expect"):
        sys.exit(0)
    print(f"{path}: opens with {verb!r} — the first step must be an "
          "expect (its bounded retry is the scene-ready wait)")
    sys.exit(1)
sys.exit(0)
' "$1"
}

# The guard guards itself.
if printf 'click button#0\nexpect label#0 "x"\n' | opening_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (action-first script passed)" >&2
    exit 1
fi

for f in tools/scenes/*.steps; do
    out="$(opening_lint "$f")" || {
        echo "check-steps: $f must open with an expect (the retry is the scene-ready wait):" >&2
        echo "$out" >&2
        status=1
    }
done

# Every scene script must be reachable by name from harness::script.
# That match ends in a catch-all returning the milestone2 script, so an
# unregistered scene does not fail — it silently runs a DIFFERENT
# script, and a leg that passes then proves nothing about the scene it
# claims to be. Registration is easy to forget precisely because
# nothing downstream complains.
registered() {
    python3 -c '
import glob
import os
import re
import sys

source = open("crates/kaya/src/harness.rs").read()
# The arms look like:  "grow" => Some(include_str!(".../grow.steps")),
arms = set(re.findall(r"\"([a-z0-9_]+)\"\s*=>\s*Some\(include_str!", source))
missing = [
    name
    for name in sorted(
        os.path.splitext(os.path.basename(p))[0] for p in glob.glob("tools/scenes/*.steps")
    )
    # milestone2 is the catch-all arm itself, reached as "1" and as any
    # unknown name; it is registered by being the default.
    if name not in arms and name != "milestone2"
]
print("\n".join(missing))
sys.exit(1 if missing else 0)
'
}

if out="$(registered)"; then
    :
else
    echo "check-steps: scene script(s) not registered in harness::script — KAYA_SELFTEST=<name> would silently run the milestone2 script instead of failing:" >&2
    echo "$out" >&2
    status=1
fi

# Every scene must be WIRED into every platform runner, not merely
# registered: a scene can exist, parse, and be registered, yet run
# nowhere on a platform — the layout scene shipped exactly that way
# (functionally green on mac, absent from every suite), and the iOS
# SwiftUI suite later missed the grow/layout legs the same silent way.
# A file-level name check cannot see a per-suite gap inside one runner,
# but it holds the coarse class: no scene vanishes from a PLATFORM
# without this failing.
wired() {
    local runner scene status=0
    for scene in tools/scenes/*.steps; do
        scene="$(basename "${scene%.steps}")"
        for runner in tools/validate-mac.sh tools/linux/run-suites.sh \
            tools/deploy-win.sh tools/ios/run-sim.sh tools/android/run-emulator.sh; do
            if ! grep -q "$scene" "$runner"; then
                echo "check-steps: scene \"$scene\" is not wired into $runner" >&2
                status=1
            fi
        done
    done
    return "$status"
}
wired || status=1

[ "$status" = 0 ] && echo "check-steps: OK"
exit "$status"
