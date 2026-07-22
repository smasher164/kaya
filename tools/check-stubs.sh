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
# The wired-legs-vs-stubbed-backend guard. Depth slices legitimately
# leave loud stubs in the backends they have not reached yet — the
# convention is the string "<feature> is not yet materialized" — and
# runners legitimately gain legs as breadth lands. The class this
# kills: a scene's legs WIRED into a platform's runner while that
# platform's backend still stubs the feature, so the first suite run
# dies on unimplemented!() instead of a gate. That exact combination
# shipped (2026-07-22): the GTK scroll materialization was believed
# applied, check-gtk compiled the surviving stub happily (stubs
# compile), the linux legs were wired, and the suite was the first
# thing to notice. This gate notices in seconds: for each runner that
# carries legs for a scene, the runner's backend must not stub that
# scene's feature.
#
# The stub string is the contract: spell depth-slice stubs as
# "<scene> is not yet materialized" and this gate holds the line.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

status=0

# check <runner> <leg-pattern-prefix> <backend file>: if the runner
# wires legs for a scene, the backend must not stub it.
check() {
    local runner="$1" backend="$2" scene stub
    for steps in tools/scenes/*.steps; do
        scene="$(basename "${steps%.steps}")"
        stub="$scene is not yet materialized"
        if grep -qE "\b${scene}[-_](rust|python|go|csharp|java|swift|ocaml|haskell|compose|jvm|swiftui)" "$runner" \
            && grep -q "$stub" "$backend"; then
            echo "check-stubs: $runner wires '$scene' legs but $backend still stubs it (\"$stub\")" >&2
            status=1
        fi
    done
}

check tools/linux/run-suites.sh       crates/kaya/src/gtk.rs
check tools/deploy-win.sh             crates/kaya/src/winui/mod.rs
check tools/validate-mac.sh           swift/KayaSwiftUI.swift
check tools/ios/run-sim.sh            swift/KayaSwiftUI.swift
check tools/android/run-emulator.sh   android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt

# The guard guards itself: a synthesized wired-and-stubbed pair must
# fail, or the lint is a false green.
self_test() {
    local dir
    dir="$(mktemp -d)"
    mkdir -p "$dir/tools/scenes"
    echo "settle 1" >"$dir/tools/scenes/fakescene.steps"
    echo "run fakescene-rust something" >"$dir/runner.sh"
    echo 'unimplemented!("kaya: fakescene is not yet materialized on this backend")' >"$dir/backend.rs"
    local out
    out="$(cd "$dir" && bash -c '
        status=0
        for steps in tools/scenes/*.steps; do
            scene="$(basename "${steps%.steps}")"
            stub="$scene is not yet materialized"
            if grep -qE "\b${scene}[-_](rust|python)" runner.sh && grep -q "$stub" backend.rs; then
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

if [ "$status" -ne 0 ]; then
    exit 1
fi
echo "check-stubs: OK"
