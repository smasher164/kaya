#!/usr/bin/env bash

# Run a gate, or skip it because nothing it reads has changed since it
# last passed.
#
#   tools/keyed.sh <gate-name> -- <command...>
#
# OFF BY DEFAULT. Without KAYA_FAST=1 this is a transparent wrapper that
# execs the command, so the matrix — the run whose verdict goes on the
# record — never consults a cache and cannot be wrong because of one.
# The cache exists for the inner loop, where re-running the Kotlin gates
# after editing gtk.rs is pure waiting.
#
# The mechanism is a verifying trace: hash the gate's declared inputs
# (tools/build-id.sh --gate, which holds the input sets and the argument
# for why they are deliberately over-approximate), and skip only when
# the stored key from the last PASS matches. Failures are never stored,
# so a red gate stays red until it is actually fixed.
#
# What this buys beyond speed is early cutoff, and it comes from the
# input sets rather than from any cleverness here: the guest languages
# depend on kaya's INTERFACE (the generated header and bindings), not on
# libkaya's binary, so a change inside a backend moves the core's build
# id and leaves every language gate's key untouched.
#
# THE HAZARD, stated because it is the reason for every conservative
# choice above: a key that omits an input skips a gate whose answer
# would have changed — a real defect reported as PASS. That is strictly
# worse than a stale artifact, which is why the sets name directories
# rather than files, why tools/ rides every key, and why the matrix does
# not participate.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

name="${1:?usage: keyed.sh <gate-name> -- <command...>}"
shift
[ "${1:-}" = "--" ] || { echo "keyed.sh: expected -- before the command" >&2; exit 2; }
shift

# The plain path: no cache, no key computed, nothing consulted.
if [ "${KAYA_FAST:-0}" != 1 ]; then
    exec "$@"
fi

key="$("$ROOT/tools/build-id.sh" --gate "$name")" || exit 1
store="$ROOT/target/.kaya-gates"
mkdir -p "$store"
stamp="$store/$name"

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$key" ]; then
    # Every skip says so, with its key. "Why didn't that re-run" has to
    # be answerable from the log alone, or the cache becomes the first
    # place to suspect and the last place anyone can check.
    echo "$name: CACHED ($key) — inputs unchanged since it last passed"
    exit 0
fi

# Status captured straight off the command. NOT `if "$@"; then …; fi;
# status=$?` — an `if` with no else branch that takes neither leaves $?
# at 0, so that spelling swallows the gate's failure and reports a pass.
# It was written that way first, and tools/check-keyed.sh caught it.
"$@"
status=$?
if [ "$status" = 0 ]; then
    printf '%s' "$key" >"$stamp"
    exit 0
fi
# A failed gate leaves no stamp; an earlier stamp is now a lie about a
# tree that no longer passes, so it goes.
rm -f "$stamp"
exit "$status"
