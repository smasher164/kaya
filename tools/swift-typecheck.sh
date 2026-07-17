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

if SWIFTC="$(xcrun --find swiftc 2>/dev/null)"; then
    SDK_ARGS=()
else
    SWIFTC=/usr/bin/swiftc
    SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
    if [ ! -d "$SDK" ]; then
        echo "swift-typecheck: no swiftc via xcrun and no CommandLineTools SDK" >&2
        exit 1
    fi
    SDK_ARGS=(-sdk "$SDK")
fi

# swiftc requires top-level code to live in a file named main.swift;
# each example program typechecks in its own pass.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for example in guests/swift/milestone2.swift guests/swift/entry.swift guests/swift/gallery.swift guests/swift/todos.swift; do
    cp "$example" "$TMP/main.swift"
    if ! env -u DEVELOPER_DIR "$SWIFTC" "${SDK_ARGS[@]}" -typecheck \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift "$TMP/main.swift"; then
        echo "swift-typecheck: FAIL ($example)"
        exit 1
    fi
done
echo "swift-typecheck: OK"
