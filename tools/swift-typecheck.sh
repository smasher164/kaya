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
# Typecheck the Swift binding and example against the macOS SDK — the
# fast gate that catches KayaApp.swift/KayaWire.swift breakage without
# booting a simulator.
#
# Toolchain resolution is the point of this script: inside the nix dev
# shell, DEVELOPER_DIR points at a nix apple-sdk where xcrun cannot
# find swiftc, so we fall back to the system toolchain with the
# CommandLineTools SDK explicitly. Encoded once, here, instead of
# re-derived at every call site.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=tools/lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1

# swiftc requires top-level code to live in a file named main.swift;
# each example program typechecks in its own pass.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Globbed, not listed: the hand-maintained list this loop once
# carried had silently skipped align.swift (the forgotten-list class;
# same fix as java-typecheck). Companions ride via $companions below.
for example in guests/swift/*.swift; do
    case "$example" in *+*) continue ;; esac
    cp "$example" "$TMP/main.swift"
    # A guest with generated sum surfaces (kaya-swift-gen) has a
    # checked-in <name>+Kaya.swift companion; compile it alongside.
    companions=$(ls "${example%.swift}"+*.swift 2>/dev/null || true)
    # shellcheck disable=SC2086
    if ! kaya_swiftc -typecheck \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift $companions "$TMP/main.swift"; then
        echo "swift-typecheck: FAIL ($example)"
        exit 1
    fi
done
echo "swift-typecheck: OK"
