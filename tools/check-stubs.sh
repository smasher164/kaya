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
# THE STUB IS A CALL, NOT A SENTENCE: `depth_stub("<scene>")` in Rust,
# `depthStub("<scene>")` in Kotlin. It was a free-form string for four
# milestones and NOT ONE BACKEND EVER SPELLED IT — so this gate could
# only ever pass, and the filedialog depth slice sailed straight through
# it with three backends refusing loudly in three different sentences. A
# gate satisfiable without exercising the real thing is a bug in the gate
# (CLAUDE.md, invariant 4). hand_rolled() below is what keeps it honest:
# a stub the gate cannot see is now itself a failure.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

status=0

# Does this backend declare a depth stub for this scene? Matched on the
# SUFFIX of the name, because each language keeps its own casing and
# prefix: `depth_stub` in Rust, `depthStub` in Kotlin, `kayaDepthStub`
# in Swift (whose file-scope functions are all kaya-prefixed to keep
# them out of the host's symbol space). check-steps greps the same way.
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

# The guard guards itself: a synthesized wired-and-stubbed pair must
# fail, or the lint is a false green.
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

# THE VACUITY GUARD. The rule above only sees stubs spelled as the call,
# so a backend that refuses in its own words is invisible to it — which
# is exactly what all three filedialog arms did. Any not-implemented
# refusal in a backend must go through the helper.
if ! python3 tools/lib/hand-rolled-stubs.py; then
    status=1
fi

# STUB IMPLIES LEDGER. The two rules above make a depth stub SILENT: it
# holds a scene's legs off a runner and both gates read green. That is
# the right behavior and it is also a place to leave work forever —
# forgetting a stub costs nothing, because nothing anywhere says it is
# there. The Compose undo stub sat across five entry points for a whole
# milestone with no entry in docs/deferred.md, and it took an agent
# reading the backend source to find it (2026-08-05).
#
# So the silence has a price: every declaration must have an OPEN entry
# in docs/deferred.md naming the scene and the backend. Struck-through
# entries do not count — a closed entry says the hole was filled, and a
# backend still refusing is then a contradiction rather than a carve-out.
# `git log -S 'depth_stub(' -- docs/deferred.md` was EMPTY before this
# rule: not one stub in the project's history was ever tracked.
if ! python3 tools/lib/stub-ledger.py; then
    status=1
fi

if [ "$status" -ne 0 ]; then
    exit 1
fi
echo "check-stubs: OK"
