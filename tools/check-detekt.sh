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
# The dead-code gate for the Kotlin layer: detekt's unused family over
# every hand-written Kotlin source (tools/detekt.yml is the curated
# config; it is the whole config, not an overlay on detekt's defaults).
#
# WHY A SECOND TOOL AT ALL. The Compose interpreter is already
# compiled by check-compose.sh, but the Kotlin COMPILER cannot see this
# failure class: K2 moved the UNUSED_* diagnostics out of the compiler
# into IDE inspections (KT-69698), so a computed-and-never-used local
# raises nothing, and -Werror/allWarningsAsErrors would be a gate that
# looks like it covers the class while the defect walks straight
# through. Measured 2026-07-25 on the real defect: the accessibility
# lowering was written as `val a11y = …` and applied to no widget; the
# compiler's only complaint about that file was an unrelated
# menuAnchor deprecation.
#
# This is the interpreter-backend blind spot generally: KayaCompose.kt
# is a hand-written re-implementation of the harness verbs, so anything
# that lets code LOOK applied while being dead ships a false green
# through every string-matching gate (check-verbs, check-sugar-surface).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

CONFIG="$ROOT/tools/detekt.yml"
# The hand-written Kotlin, module by module. Deliberately NOT `android`:
# that would sweep the gradle build directories, where generated sources
# nobody wrote would decide this gate's verdict.
SOURCES=(
    android/kaya/src/main/kotlin
    android/milestone2/src/main/kotlin
    android/milestone2kt/src/main/kotlin
)

for src in "${SOURCES[@]}"; do
    [ -d "$src" ] || { echo "check-detekt: no such source tree: $src"; exit 1; }
done

# The built-in negative test (the check-sugar-surface fake-kind
# pattern): a sample carrying one instance of each rule's defect must
# make ALL of them fire. A curated config is exactly the shape that
# rots silently — a renamed rule in a detekt bump would otherwise turn
# this gate green forever, which is worse than not having it.
SELFTEST_DIR="$(mktemp -d)"
trap 'rm -rf "$SELFTEST_DIR"' EXIT
cat >"$SELFTEST_DIR/KayaDetektSelftest.kt" <<'EOF'
package sample

import java.util.ArrayList

private class NeverUsed

class Selftest {
    private fun neverCalled() = 1

    // The real defect this gate exists for: computed, then applied
    // nowhere.
    fun render(flag: Boolean, neverRead: Int): String {
        val a11y = if (flag) "id" else ""
        return "rendered"
    }
}
EOF
selftest_out="$(detekt --config "$CONFIG" --input "$SELFTEST_DIR" 2>&1)"
missing=()
for rule in UnusedImports UnusedParameter UnusedPrivateClass \
    UnusedPrivateMember UnusedPrivateProperty; do
    grep -q "\[$rule\]" <<<"$selftest_out" || missing+=("$rule")
done
if [ ${#missing[@]} -ne 0 ]; then
    echo "check-detekt: self-test failed — these rules did not fire on a" \
        "sample that violates every one of them: ${missing[*]}"
    echo "$selftest_out"
    exit 1
fi

if ! out="$(detekt --config "$CONFIG" --input "$(IFS=,; echo "${SOURCES[*]}")" 2>&1)"; then
    echo "$out"
    echo "check-detekt: FAIL (dead code in the Kotlin sources)"
    exit 1
fi
echo "check-detekt: OK"
