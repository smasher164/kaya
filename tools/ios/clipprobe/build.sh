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

# Build, install and run ClipProbe on a booted SIMULATOR.
# Usage: tools/ios/clipprobe/build.sh [udid]
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

OUT="$ROOT/target/ios-clipprobe"
APP="$OUT/ClipProbe.app"
rm -rf "$APP"
mkdir -p "$APP"

# The iphonesimulator SDK, not the macOS one kaya_swiftc defaults to.
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$APP/ClipProbe" \
    "$HERE/main.swift"

# UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace decide
# whether the app's own container is BROWSABLE from the picker at all.
cat >"$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClipProbe</string>
    <key>CFBundleIdentifier</key><string>dev.kaya.clipprobe</string>
    <key>CFBundleName</key><string>ClipProbe</string>
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

xcrun simctl terminate "$UDID" dev.kaya.clipprobe >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" dev.kaya.clipprobe >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

# SEEDED FROM OUTSIDE: simctl pbcopy is the only way the lane can put
# content on the simulator's clipboard.
if [ "${KAYA_CLIPPROBE_MODE:-foreign}" = "own" ]; then
    echo "== mode=own: NOT seeding; the app writes its own content =="
else
    printf 'kaya-seeded-from-the-host' | xcrun simctl pbcopy "$UDID"
    echo "== seeded the clipboard with simctl pbcopy =="
fi

# --console-pty hands the probe's stdout back here.
echo "== running on $UDID =="
SIMCTL_CHILD_KAYA_CLIPPROBE_MODE="${KAYA_CLIPPROBE_MODE:-foreign}" \
    xcrun simctl launch --console-pty "$UDID" dev.kaya.clipprobe 2>&1 &
launch_pid=$!
sleep 14
# A prompt is a THING ON SCREEN: the log cannot tell a denied read from
# an empty clipboard.
xcrun simctl io "$UDID" screenshot "$OUT/screen.png" >/dev/null 2>&1 \
    && echo "== screenshot at $OUT/screen.png =="
kill "$launch_pid" 2>/dev/null || true
xcrun simctl terminate "$UDID" dev.kaya.clipprobe >/dev/null 2>&1 || true
