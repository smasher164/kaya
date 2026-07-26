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

# The gate for the gate cache (tools/keyed.sh). A cache that skips work
# is only ever as trustworthy as the answer to "what would make it skip
# something it shouldn't", so this asks that question five ways.
#
# The fifth clause is the one that matters most: the gates whose verdict
# depends on a BUILT ARTIFACT must never be wrapped. Their sources can
# sit unchanged while target/ holds something else entirely, so an
# input-keyed skip would report PASS about a library it never looked at.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FIXTURE=keyed-selftest
STORE="$ROOT/target/.kaya-gates"
INSIDE="$ROOT/tools/.keyed-probe"   # tools/ rides every gate key
OUTSIDE="$ROOT/crates/.keyed-probe" # crates/ is NOT in the fixture's set

cleanup() { rm -f "$INSIDE" "$OUTSIDE" "$STORE/$FIXTURE"; }
trap cleanup EXIT
cleanup

status=0
fail() {
    echo "check-keyed: $1" >&2
    status=1
}

# The command is `true`/`false` rather than a real gate: what is under
# test is the wrapper's decision, and a hermetic command makes a wrong
# decision unambiguous.
run() { KAYA_FAST=1 tools/keyed.sh "$FIXTURE" -- "$@" 2>&1; }

# 1. First run executes; second run skips. The baseline the rest leans on.
out=$(run true)
case "$out" in *CACHED*) fail "a gate with no stored key was reported CACHED" ;; esac
out=$(run false)
case "$out" in
    *CACHED*) : ;;
    *) fail "an unchanged tree re-ran the gate (no cutoff at all): $out" ;;
esac

# 2. A change INSIDE the input set must re-run it. `false` as the
# command means a re-run is visible as a non-zero exit.
: >"$INSIDE"
if run false >/dev/null; then
    fail "a change under tools/ did not invalidate the key"
fi
rm -f "$INSIDE"

# 3. A change OUTSIDE the input set must NOT re-run it. This is the
# early-cutoff property itself — without it the keys are not
# discriminating and the whole exercise is one global dirty bit.
run true >/dev/null
: >"$OUTSIDE"
out=$(run false)
case "$out" in
    *CACHED*) : ;;
    *) fail "a change outside the input set busted the key — no cutoff: $out" ;;
esac
rm -f "$OUTSIDE"

# 4. A FAILING gate must never be stored. Otherwise one red run poisons
# the cache into reporting the failure as a pass forever after.
rm -f "$STORE/$FIXTURE"
run false >/dev/null
out=$(run true)
case "$out" in
    *CACHED*) fail "a FAILED gate was cached — the next run would skip it green" ;;
esac
rm -f "$STORE/$FIXTURE"

# 5. Without KAYA_FAST there is no cache at all: the matrix path must be
# incapable of consulting one.
#
# `env -u`, not a bare invocation: this gate itself runs inside lanes
# that may have exported KAYA_FAST=1, and a clause that INHERITS the
# variable it claims to have unset is testing the opposite of what it
# says. It shipped that way and failed on the first fast lane — which
# is the gate working, but the lesson is that a self-test has to
# construct its environment rather than assume one.
rm -f "$STORE/$FIXTURE"
KAYA_FAST=1 tools/keyed.sh "$FIXTURE" -- true >/dev/null
out=$(env -u KAYA_FAST tools/keyed.sh "$FIXTURE" -- echo ran 2>&1)
case "$out" in
    ran) : ;;
    *) fail "KAYA_FAST unset still consulted the cache (matrix runs must be clean): $out" ;;
esac

# 6. The gates that read a built artifact must not be wrapped, ever.
for unwrappable in check-abort check-wheel check-build-id; do
    if grep -q "keyed.sh $unwrappable " tools/validate-mac.sh; then
        fail "$unwrappable is keyed, but its verdict depends on target/, not on sources"
    fi
done

# 7. Everything that IS wrapped must have an input set, or keyed.sh dies
# at run time inside a lane instead of here.
wrapped=$(grep -oE "keyed\.sh [a-z-]+ " tools/validate-mac.sh | cut -d' ' -f2 | sort -u)
for name in $wrapped; do
    if ! tools/build-id.sh --gate "$name" >/dev/null 2>&1; then
        fail "$name is wrapped by keyed.sh but has no entry in build-id.sh's GATES"
    fi
done

if [ "$status" = 0 ]; then
    echo "check-keyed: OK ($(echo "$wrapped" | wc -w | tr -d ' ') gates keyed)"
else
    echo "check-keyed: FINDINGS ABOVE"
fi
exit "$status"
