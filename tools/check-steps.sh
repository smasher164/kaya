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
    for kind, index in re.findall(r"\b(row|column)#(\d+)\b", line):
        if kind == "column" and index == "0":
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
        echo "check-steps: $f targets a container by creation index — only column#0 (the unique For container) is cross-language stable:" >&2
        echo "$out" >&2
        status=1
    }
done
[ "$status" = 0 ] && echo "check-steps: OK"
exit "$status"
