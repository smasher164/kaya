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
# Compile-check the Compose interpreter. check-verbs holds its SOURCE
# current by string-matching, but no mac-side gate ever COMPILED
# KayaCompose.kt — the Android emulator run was the first compiler to
# see it, minutes into a suite (caught live 2026-07-22: a missing
# verticalScroll import produced a zero-verdict emulator run). This
# is the swift-typecheck/java-typecheck sibling for the Kotlin layer:
# seconds warm under the gradle daemon.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/android" || exit 1

gradle --console=plain -q :kaya:compileDebugKotlin || {
    echo "check-compose: FAIL (KayaCompose.kt does not compile)" >&2
    exit 1
}
echo "check-compose: OK"
