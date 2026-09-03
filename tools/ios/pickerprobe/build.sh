#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# Build, install and run PickerProbe on a booted SIMULATOR.
# Usage: tools/ios/pickerprobe/build.sh [udid]
#
# NOT A LANE. Questions in main.swift's header, findings in
# docs/traps.md. The SIMULATOR is the right host because these are UIKit
# questions; anything whose answer depends on the sandbox DENYING
# something belongs in tools/ios/scopeprobe, on hardware.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1
[ -n "${SWIFT_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR"
xcrun simctl help >/dev/null 2>&1 || {
    echo "build.sh: no full Xcode (simctl missing)" >&2
    exit 1
}

UDID="${1:-}"
if [ -z "$UDID" ]; then
    UDID=$(xcrun simctl list devices 2>/dev/null | grep -m1 "kaya-sim-0 (" \
        | grep -oE '[0-9A-F-]{36}') || true
fi
[ -n "$UDID" ] || {
    echo "build.sh: no booted kaya-sim-0; run tools/ios/run-sim.py once" >&2
    exit 1
}

OUT="$ROOT/target/ios-pickerprobe"
APP="$OUT/PickerProbe.app"
rm -rf "$APP"
mkdir -p "$APP"

# The iphonesimulator SDK, not the macOS one kaya_swiftc defaults to.
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$APP/PickerProbe" \
    "$HERE/main.swift"

# UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace decide
# whether the app's own container is BROWSABLE from the picker at all.
cat >"$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PickerProbe</string>
    <key>CFBundleIdentifier</key><string>dev.kaya.pickerprobe</string>
    <key>CFBundleName</key><string>PickerProbe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIFileSharingEnabled</key><true/>
    <key>LSSupportsOpeningDocumentsInPlace</key><true/>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchScreen</key><dict/>
</dict>
</plist>
PLIST

xcrun simctl terminate "$UDID" dev.kaya.pickerprobe >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" dev.kaya.pickerprobe >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

# --console-pty hands the probe's stdout back here.
echo "== running on $UDID =="
xcrun simctl launch --console-pty "$UDID" dev.kaya.pickerprobe 2>&1 &
launch_pid=$!
sleep 12
kill "$launch_pid" 2>/dev/null || true
xcrun simctl terminate "$UDID" dev.kaya.pickerprobe >/dev/null 2>&1 || true
