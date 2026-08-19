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
# The wired-legs-vs-stubbed-backend guard: for each runner that carries
# legs for a scene, the runner's backend must not stub that scene's
# feature. Stubs COMPILE, so nothing else sees the combination.
#
# THE STUB IS A CALL, NOT A SENTENCE: `depth_stub("<scene>")` in Rust,
# `depthStub("<scene>")` in Kotlin, `kayaDepthStub(_:on:)` in Swift. A
# backend that refuses in its own words is invisible here, which is what
# the vacuity guard below is for.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

status=0

# Matched on the SUFFIX of the name, because each language keeps its own
# casing and prefix. check-steps greps the same way.
stubbed() {
    grep -qF -e "epth_stub(\"$1\")" -e "epthStub(\"$1\", on: \"$3\")" \
        -e "epthStub(\"$1\")" "$2"
}

# check <runner> <leg-pattern-prefix> <backend file>: if the runner
# wires legs for a scene, the backend must not stub it.
check() {
    local runner="$1" backend="$2" platform="${3:-}" scene stub
    for steps in tools/scenes/*.steps; do
        scene="$(basename "${steps%.steps}")"
        stub="depth_stub(\"$scene\")"
        if grep -qE "\b${scene}[-_](rust|python|go|csharp|java|swift|ocaml|haskell|compose|jvm|swiftui)" "$runner" \
            && stubbed "$scene" "$backend" "$platform"; then
            echo "check-stubs: $runner wires '$scene' legs but $backend still stubs it ($stub)" >&2
            status=1
        fi
    done
}

check tools/linux/run-suites.sh       crates/kaya/src/gtk.rs
check tools/deploy-win.sh             crates/kaya/src/winui/mod.rs
check tools/validate-mac.sh           swift/KayaSwiftUI.swift macos
check tools/ios/run-sim.sh            swift/KayaSwiftUI.swift ios
check tools/android/run-emulator.sh   android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt

# The guard guards itself: a synthesized wired-and-stubbed pair must fail.
self_test() {
    local dir
    dir="$(mktemp -d)"
    mkdir -p "$dir/tools/scenes"
    echo "settle 1" >"$dir/tools/scenes/fakescene.steps"
    echo "run fakescene-rust something" >"$dir/runner.sh"
    echo 'crate::depth_stub("fakescene");' >"$dir/backend.rs"
    local out
    out="$(cd "$dir" && bash -c '
        status=0
        for steps in tools/scenes/*.steps; do
            scene="$(basename "${steps%.steps}")"
            if grep -qE "\b${scene}[-_](rust|python)" runner.sh \
                && grep -qF "depth_stub(\"$scene\")" backend.rs; then
                status=1
            fi
        done
        echo $status
    ')"
    rm -rf "$dir"
    if [ "$out" != 1 ]; then
        echo "check-stubs: SELF-TEST FAIL (bad sample passed)" >&2
        exit 1
    fi
}
self_test

# THE VACUITY GUARD: any not-implemented refusal in a backend must go
# through the helper, or the rule above cannot see it.
if ! python3 tools/lib/hand-rolled-stubs.py; then
    status=1
fi

# STUB IMPLIES LEDGER. A depth stub is SILENT — it holds a scene's legs
# off a runner and both rules above read green — so every declaration
# must have an OPEN entry in docs/deferred.md naming the scene and the
# backend. Struck-through entries do not count: a closed entry says the
# hole was filled, and a backend still refusing contradicts it.
if ! python3 tools/lib/stub-ledger.py; then
    status=1
fi

if [ "$status" -ne 0 ]; then
    exit 1
fi
echo "check-stubs: OK"
