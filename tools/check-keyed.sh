#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# The gate for the gate cache (tools/keyed.sh): what would make it skip
# something it shouldn't, asked seven ways.
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

# `true`/`false` rather than a real gate: what is under test is the
# wrapper's decision.
run() { KAYA_FAST=1 tools/keyed.sh "$FIXTURE" -- "$@" 2>&1; }

# 1. First run executes; second run skips.
out=$(run true)
case "$out" in *CACHED*) fail "a gate with no stored key was reported CACHED" ;; esac
out=$(run false)
case "$out" in
    *CACHED*) : ;;
    *) fail "an unchanged tree re-ran the gate (no cutoff at all): $out" ;;
esac

# 2. A change INSIDE the input set must re-run it. `false` as the
# command makes a re-run visible as a non-zero exit.
: >"$INSIDE"
if run false >/dev/null; then
    fail "a change under tools/ did not invalidate the key"
fi
rm -f "$INSIDE"

# 3. A change OUTSIDE the input set must NOT re-run it — without this
# the keys are one global dirty bit.
run true >/dev/null
: >"$OUTSIDE"
out=$(run false)
case "$out" in
    *CACHED*) : ;;
    *) fail "a change outside the input set busted the key — no cutoff: $out" ;;
esac
rm -f "$OUTSIDE"

# 4. A FAILING gate must never be stored.
rm -f "$STORE/$FIXTURE"
run false >/dev/null
out=$(run true)
case "$out" in
    *CACHED*) fail "a FAILED gate was cached — the next run would skip it green" ;;
esac
rm -f "$STORE/$FIXTURE"

# 5. Without KAYA_FAST the cache is never CONSULTED. `env -u`, not a
# bare invocation: this gate runs inside lanes that may have exported
# KAYA_FAST=1, and a clause that inherits the variable it claims to have
# unset tests the opposite of what it says.
rm -f "$STORE/$FIXTURE"
KAYA_FAST=1 tools/keyed.sh "$FIXTURE" -- true >/dev/null
out=$(env -u KAYA_FAST tools/keyed.sh "$FIXTURE" -- echo ran 2>&1)
case "$out" in
    ran) : ;;
    *) fail "KAYA_FAST unset still consulted the cache (matrix runs must be clean): $out" ;;
esac

# 5b. ...but an unset run's PASS is RECORDED, so the first fast run
# after a full sweep is warm — and an unset run's FAILURE clears any
# stamp, the never-cache-a-failure rule on the recording path too.
rm -f "$STORE/$FIXTURE"
env -u KAYA_FAST tools/keyed.sh "$FIXTURE" -- true >/dev/null
out=$(KAYA_FAST=1 tools/keyed.sh "$FIXTURE" -- echo ran 2>&1)
case "$out" in
    *CACHED*) : ;;
    *) fail "a full run's pass was not recorded — the first fast run after every full sweep starts cold: $out" ;;
esac
env -u KAYA_FAST tools/keyed.sh "$FIXTURE" -- false >/dev/null 2>&1
out=$(KAYA_FAST=1 tools/keyed.sh "$FIXTURE" -- echo ran 2>&1)
case "$out" in
    ran) : ;;
    *) fail "a full run's FAILURE left a stamp behind — the next fast run would skip a red gate: $out" ;;
esac

# 5c. THE ARTIFACT HALF OF A KEY FOLLOWS THE EMBEDDED BUILD-ID. Two
# staged roots whose artifact carries a DIFFERENT marker must yield
# different keys; the SAME marker with different surrounding bytes must
# yield the same key (that is the point — every relink mints a new
# LC_UUID, and the marker is what says which sources the artifact came
# from); and no marker at all must differ from both. Proven through the
# KAYA_GATE_ARTIFACT_ROOT seam, which exists for exactly this clause.
ART_T="$(mktemp -d)"
mkdir -p "$ART_T/a/target/debug" "$ART_T/b/target/debug"
printf 'xx kaya-build-id:aaaaaaaaaaaaaaaa yy' > "$ART_T/a/target/debug/libkaya.dylib"
printf 'xx kaya-build-id:bbbbbbbbbbbbbbbb yy' > "$ART_T/b/target/debug/libkaya.dylib"
ka=$(KAYA_GATE_ARTIFACT_ROOT="$ART_T/a" tools/build-id.sh --gate check-abort)
kb=$(KAYA_GATE_ARTIFACT_ROOT="$ART_T/b" tools/build-id.sh --gate check-abort)
if [ "$ka" = "$kb" ]; then
    fail "two different embedded build-ids produced ONE key — the artifact half of the key is not being read"
fi
printf 'DIFFERENT BYTES kaya-build-id:aaaaaaaaaaaaaaaa other tail' > "$ART_T/b/target/debug/libkaya.dylib"
kb=$(KAYA_GATE_ARTIFACT_ROOT="$ART_T/b" tools/build-id.sh --gate check-abort)
if [ "$ka" != "$kb" ]; then
    fail "one embedded build-id produced two keys — the key is hashing relink noise and will never hit"
fi
printf 'no marker here at all' > "$ART_T/b/target/debug/libkaya.dylib"
kb=$(KAYA_GATE_ARTIFACT_ROOT="$ART_T/b" tools/build-id.sh --gate check-abort)
if [ "$ka" = "$kb" ]; then
    fail "an artifact with NO build-id marker keyed like a marked one"
fi
rm -rf "$ART_T"

# 6 and 7 read tools/gates.sh's list, with a vacuity floor inside — a
# census that finds almost nothing is a broken census, not a clean tree.
#
#   6. The gates that read a BUILT ARTIFACT must be keyed WITH that
#      artifact's bytes in their key (build-id.sh's ARTIFACT_GATES;
#      ratified 2026-08-20) — sources can sit unchanged while target/
#      holds something else, and the bytes are what close that gap.
#      check-build-id alone stays unkeyed forever: caching the
#      staleness gate's answer is the defect it exists to find.
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
artifact_gates = ("check-abort", "check-wheel", "check-empty-child",
                  "check-pane-ladder", "check-table-tier")
for name in artifact_gates:
    g = gates.get(name)
    if g is None:
        print(f"check-keyed: {name} is not in the sweep at all, so the "
              f"artifact-key rule is checking nothing", file=sys.stderr)
        status = 1
        continue
    if not g["keyed"]:
        print(f"check-keyed: {name} reads a built artifact and is not keyed — "
              f"key it on its sources plus the artifact's bytes "
              f"(build-id.sh's ARTIFACT_GATES)", file=sys.stderr)
        status = 1
    if subprocess.run(["tools/build-id.sh", "--gate-artifacts", name],
                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                      check=False, text=True).stdout.strip() == "":
        print(f"check-keyed: {name} has no ARTIFACT_GATES entry in "
              f"build-id.sh — its key would be sources alone, which is the "
              f"stale-PASS loophole the artifact half exists to close",
              file=sys.stderr)
        status = 1
g = gates.get("check-build-id")
if g is None:
    print("check-keyed: check-build-id is not in the sweep at all",
          file=sys.stderr)
    status = 1
elif g["keyed"]:
    print("check-keyed: check-build-id is keyed — caching the staleness "
          "gate's answer is the defect it exists to find", file=sys.stderr)
    status = 1

wrapped = sorted(n for n, g in gates.items() if g["keyed"])
for name in wrapped:
    if subprocess.run(["tools/build-id.sh", "--gate", name],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                      check=False).returncode != 0:
        print(f"check-keyed: {name} is wrapped by keyed.sh but has no entry in "
              f"build-id.sh's GATES", file=sys.stderr)
        status = 1

# An UNKEYED gate must say why, in the list, beside itself.
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
# what changed.
if ! python3 tools/lib/keyed-inputs.py; then
    status=1
fi

if [ "$status" = 0 ]; then
    echo "check-keyed: OK ($keyedcount gates keyed)"
else
    echo "check-keyed: FINDINGS ABOVE"
fi
exit "$status"
