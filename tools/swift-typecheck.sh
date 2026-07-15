#!/usr/bin/env bash
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
cd "$ROOT"

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

# swiftc requires top-level code to live in a file named main.swift.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp tools/ios/milestone2.swift "$TMP/main.swift"

if env -u DEVELOPER_DIR "$SWIFTC" "${SDK_ARGS[@]}" -typecheck \
    -import-objc-header crates/kaya/include/kaya.h \
    bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift "$TMP/main.swift"; then
    echo "swift-typecheck: OK"
else
    echo "swift-typecheck: FAIL"
    exit 1
fi
