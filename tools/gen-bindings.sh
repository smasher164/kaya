#!/usr/bin/env bash
# Regenerate bindings/<lang> from kaya::spec (kaya-bindgen). The one
# spelling of the invocation, so nobody reruns it ad hoc with swallowed
# stderr or an unchecked exit code — a generator that fails to compile
# must never read as "nothing changed".
#
# Usage: tools/gen-bindings.sh [--check]
# --check regenerates in memory and fails if the checked-in files are
# out of date, touching nothing (the gen-header.sh pattern). The
# validation scripts run this so stale or ungeneratable bindings fail
# loudly at the gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/tools/kaya-bindgen"

# Exit codes propagate through set -e; compile errors stay on stderr.
cargo run --quiet -- "$ROOT" "$@"
