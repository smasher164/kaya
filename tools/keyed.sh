#!/usr/bin/env bash

# Run a gate, or skip it because nothing it reads has changed since it
# last passed.
#
#   tools/keyed.sh <gate-name> -- <command...>
#
# OFF BY DEFAULT: without KAYA_FAST=1 this execs the command, so the
# matrix never consults a cache. Input sets and why they are
# deliberately over-approximate live in tools/build-id.sh's GATES; a key
# that omits an input would skip a gate whose answer had changed.
# Failures are never stored.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

name="${1:?usage: keyed.sh <gate-name> -- <command...>}"
shift
[ "${1:-}" = "--" ] || { echo "keyed.sh: expected -- before the command" >&2; exit 2; }
shift

key="$("$ROOT/tools/build-id.sh" --gate "$name")" || exit 1
store="$ROOT/target/.kaya-gates"
mkdir -p "$store"
stamp="$store/$name"

if [ "${KAYA_FAST:-0}" != 1 ]; then
    # CONSULTS NOTHING — the matrix's run answers from the gate alone —
    # but a PASS is still recorded, so the first KAYA_FAST run after a
    # full sweep is warm instead of re-running everything the sweep
    # just proved (measured 2026-08-20: a cold fast sweep cost 148s
    # against 46s warm, and a day of full runs had warmed nothing).
    "$@"
    status=$?
    if [ "$status" = 0 ]; then
        printf '%s' "$key" >"$stamp"
    else
        rm -f "$stamp"
    fi
    exit "$status"
fi

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$key" ]; then
    # Every skip says so, with its key: "why didn't that re-run" must be
    # answerable from the log alone.
    echo "$name: CACHED ($key) — inputs unchanged since it last passed"
    exit 0
fi

# Status captured straight off the command — the CLAUDE.md `$?` rule,
# enforced by tools/check-shell.sh.
"$@"
status=$?
if [ "$status" = 0 ]; then
    printf '%s' "$key" >"$stamp"
    exit 0
fi
rm -f "$stamp"
exit "$status"
