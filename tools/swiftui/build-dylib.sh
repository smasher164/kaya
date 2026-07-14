#!/usr/bin/env bash
# Build the SwiftUI backend dylib (macOS): the Swift presentation layer
# plus the kaya_swiftui_run C entry, loadable by any guest-hosted process
# via KAYA_BACKEND=swiftui. Run inside the dev shell.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    for app in /Applications/Xcode.app /Applications/Xcode-*.app; do
        if [ -d "$app/Contents/Developer" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            break
        fi
    done
fi

cargo build --lib
tools/gen-header.sh --check

mkdir -p target/swiftui
SDKROOT_MAC=$(/usr/bin/xcrun -sdk macosx --show-sdk-path)
/usr/bin/xcrun swiftc \
    -sdk "$SDKROOT_MAC" \
    -emit-library \
    -import-objc-header crates/kaya/include/kaya.h \
    swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    -framework AppKit -framework Foundation \
    -o target/swiftui/libkaya_swiftui.dylib
echo "built target/swiftui/libkaya_swiftui.dylib"
