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

# 6 and 7 read tools/gates.sh's list, NOT a grep over validate-mac.sh.
# The lane delegates its whole sweep now and holds no list of its own, so
# the old grep would have matched nothing and both clauses would have
# passed while checking zero gates — the precise false green this file
# exists to refuse. Hence the vacuity floor inside: a census that finds
# almost nothing is a broken census, not a clean tree.
#
#   6. The gates that read a BUILT ARTIFACT must never be wrapped. Their
#      sources can sit unchanged while target/ holds something else, so
#      an input-keyed skip would report PASS about a library it never
#      looked at.
#   7. Everything that IS wrapped must have an input set, or keyed.sh
#      dies at run time inside a lane instead of here.
keyedcount=$(python3 - <<'PY'
import json
import subprocess
import sys

out = subprocess.run(["tools/gates.sh", "--list"], stdout=subprocess.PIPE,
                     text=True, check=False)
if out.returncode != 0:
    sys.exit("check-keyed: tools/gates.sh --list failed — the wrapped/unwrapped "
             "census could not be read, so nothing was checked")
gates = {g["name"]: g for g in json.loads(out.stdout)["gates"]}
if len(gates) < 10:
    sys.exit(f"check-keyed: only {len(gates)} gates in tools/gates.sh's list — "
             f"the list or its format moved and this census went vacuous")

status = 0
for unwrappable in ("check-abort", "check-wheel", "check-build-id"):
    g = gates.get(unwrappable)
    if g is None:
        print(f"check-keyed: {unwrappable} is not in the sweep at all, so the "
              f"rule that it must never be keyed is checking nothing",
              file=sys.stderr)
        status = 1
    elif g["keyed"]:
        print(f"check-keyed: {unwrappable} is keyed, but its verdict depends on "
              f"target/, not on sources", file=sys.stderr)
        status = 1

wrapped = sorted(n for n, g in gates.items() if g["keyed"])
for name in wrapped:
    if subprocess.run(["tools/build-id.sh", "--gate", name],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                      check=False).returncode != 0:
        print(f"check-keyed: {name} is wrapped by keyed.sh but has no entry in "
              f"build-id.sh's GATES", file=sys.stderr)
        status = 1

# An UNKEYED gate must say why, in the list, beside itself. "Why is this
# one not cached" is the question whose unwritten answer gets a gate
# wrongly cached later.
for name, g in sorted(gates.items()):
    if not g["keyed"] and len(g["unkeyed_because"].strip()) < 20:
        print(f"check-keyed: {name} is not keyed and gives no reason — state it "
              f"in tools/gates.sh's list, next to the gate", file=sys.stderr)
        status = 1

print(len(wrapped))
sys.exit(status)
PY
) || status=1

# A gate that READS a file it does not DECLARE is a false-PASS machine
# under KAYA_FAST, and it misfires exactly when the undeclared file is
# what changed. check-steps was declared ["guests"] from birth, then grew
# a rule reading all four backends; removing a depth-stub declaration —
# the edit that makes its missing legs a real failure — would have
# re-run nothing. Caught by hand once, which is not a mechanism.
if ! python3 tools/lib/keyed-inputs.py; then
    status=1
fi

if [ "$status" = 0 ]; then
    echo "check-keyed: OK ($keyedcount gates keyed)"
else
    echo "check-keyed: FINDINGS ABOVE"
fi
exit "$status"
