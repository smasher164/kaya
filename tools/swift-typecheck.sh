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
# THE INTERPRETER ITSELF — the layer this gate did not cover until
# 2026-07-25. swift/KayaSwiftUI.swift is ~4300 lines and is the historic
# miss layer (it re-implements every harness verb and carries private
# copies of the wire constants), yet its only compiler was
# build-dylib.sh inside validate-mac. So a broken interpreter reported
# "swift-typecheck: OK" and only failed minutes later in the heavy lane
# — measured: `NSObject.accessibilityIdentifier` typechecked green here
# while the dylib build rejected it outright.
#
# -warnings-as-errors here as in tools/swiftui/build-dylib.sh, and for
# the same reason: the compiler's only complaint about a DROPPED return
# value is a warning, and this file's clipboard seed threw away
# osascript's exit status and stderr for the whole life of the scene on
# exactly that footing. The interpreter compiles warning-free, so the
# flag costs nothing and turns "someone will notice the warning" into a
# wall. If it fires on something else, fix the warning — do not remove
# the flag.
if ! kaya_swiftc -typecheck -warnings-as-errors \
    -import-objc-header crates/kaya/include/kaya.h \
    swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift; then
    echo "swift-typecheck: FAIL (the SwiftUI interpreter, macOS)"
    exit 1
fi

# AND THE HOST-SIDE iOS DRIVER, which is Swift no other mac-side gate
# compiles. tools/ios/simdrive is the only thing that can read or drive
# the iOS document picker — a remote view controller with nothing
# in-process to talk to — so it is reached for under debugging pressure,
# and until now the first compiler to see an edit was the iOS lane,
# minutes into a run. That is the same shape as the interpreter passes
# below and above this one, for the same reason. It builds with no
# special flags (tools/ios/simdrive/build.sh), so a typecheck is cheap.
if ! kaya_swiftc -typecheck tools/ios/simdrive/main.swift; then
    echo "swift-typecheck: FAIL (tools/ios/simdrive, the iOS lane's driver)"
    exit 1
fi

# AND FOR iOS. One file serves both Apple platforms, so half of it lives
# behind `#if os(macOS)` / `#else` and a host-target typecheck compiles
# only ONE of those halves. The iOS half is therefore invisible to the
# macOS pass — measured 2026-07-25, hours after the interpreter pass was
# added: swift-typecheck reported OK while the iOS lane failed to
# compile `NSObject.accessibilityIdentifier` in the `#else` branch.
#
# The two halves are genuinely different code (UIKit publishes
# accessibility in-process; AppKit does not), so this is not
# belt-and-braces — it is the only compiler the iOS branch sees before
# the simulator.
# The dev shell's xcrun is a shim with no iOS SDK, so this goes through
# the real toolchain the same way kaya_swiftc does (SWIFT_DEVELOPER_DIR,
# resolved above by kaya_resolve_swiftc).
ios_xcrun() {
    if [ -n "${SWIFT_DEVELOPER_DIR:-}" ]; then
        env -u SDKROOT DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR" /usr/bin/xcrun "$@"
    else
        env -u SDKROOT /usr/bin/xcrun "$@"
    fi
}
if ios_xcrun -sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
    if ! ios_xcrun -sdk iphonesimulator swiftc -typecheck \
        -target arm64-apple-ios17.0-simulator \
        -import-objc-header crates/kaya/include/kaya.h \
        swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift; then
        echo "swift-typecheck: FAIL (the SwiftUI interpreter, iOS)"
        exit 1
    fi
    # The lane's foreign clipboard reader, for the same reason simdrive
    # earned its pass: nothing else compiles it until run-sim.sh does,
    # and the emulator must never be the first compiler to see it.
    if ! ios_xcrun -sdk iphonesimulator swiftc -typecheck \
        -target arm64-apple-ios17.0-simulator \
        tools/ios/clipctl/main.swift; then
        echo "swift-typecheck: FAIL (tools/ios/clipctl, the iOS lane's foreign clipboard process)"
        exit 1
    fi
else
    echo "swift-typecheck: note — no iphonesimulator SDK; the iOS half went unchecked" >&2
fi

echo "swift-typecheck: OK"
