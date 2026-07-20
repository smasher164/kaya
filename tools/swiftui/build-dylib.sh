#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Build the SwiftUI backend dylib (macOS): the Swift presentation layer
# plus the kaya_swiftui_run C entry, loadable by any guest-hosted process
# via KAYA_BACKEND=swiftui. Run inside the dev shell.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=tools/lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"

cargo build --lib
tools/gen-header.sh --check

mkdir -p target/swiftui
kaya_swiftc \
    -emit-library \
    -import-objc-header crates/kaya/include/kaya.h \
    swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    -framework AppKit -framework Foundation \
    -o target/swiftui/libkaya_swiftui.dylib
echo "built target/swiftui/libkaya_swiftui.dylib"
