#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
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
# every hand-written Kotlin source. tools/detekt.yml is the WHOLE
# config, not an overlay on detekt's defaults.
#
# The Kotlin compiler cannot serve here: K2 moved the UNUSED_*
# diagnostics into IDE inspections (KT-69698, docs/traps.md), so a
# computed-and-never-applied local compiles clean.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

CONFIG="$ROOT/tools/detekt.yml"
# Deliberately NOT `android`: that would sweep the gradle build
# directories, where generated sources would decide this gate's verdict.
SOURCES=(
    android/kaya/src/main/kotlin
    android/milestone2/src/main/kotlin
    android/milestone2kt/src/main/kotlin
    android/milestone2go/src/main/kotlin
)

for src in "${SOURCES[@]}"; do
    [ -d "$src" ] || { echo "check-detekt: no such source tree: $src"; exit 1; }
done

# WHAT UnusedImports DOES NOT COVER, stated here because the self-test
# below passes for it and would otherwise read as a guarantee. The rule
# is a TEXT heuristic — it has no type resolution, so an import counts
# as used if its short name appears anywhere in the file, whoever owns
# that name. Measured 2026-07-27: the Compose split arm stopped calling
# `Modifier.width()`, the `androidx.compose.foundation.layout.width`
# import went dead, and this gate stayed green because the file is full
# of unrelated `bitmap.width` / `root.width` property reads. A
# word-boundary check written here would miss it for the same reason;
# only running detekt with --classpath (the full Android + Compose
# classpath, which this deliberately standalone gate does not have)
# distinguishes the extension from the property. So: dead imports whose
# name is unique DO fail here, and dead imports whose name collides
# with any identifier in the file DO NOT. Reach for the import list by
# hand when a call site is removed.
#
# Self-test: a sample carrying one instance of each rule's defect must
# make ALL of them fire — a renamed rule in a detekt bump would
# otherwise turn a curated config green forever.
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
