#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# Build, install and run UndoProbe on a booted SIMULATOR.
# Usage: tools/ios/undoprobe/build.sh [udid]
# A throwaway probe, not a lane: see main.swift's header and
# docs/undo-plan.md §0. It UNINSTALLS itself at the end — the simulators
# are shared with the lane.
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
    echo "build.sh: no kaya-sim-0; run tools/ios/run-sim.sh once" >&2
    exit 1
}

OUT="$ROOT/target/ios-undoprobe"
APP="$OUT/UndoProbe.app"
rm -rf "$APP"
mkdir -p "$APP"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$APP/UndoProbe" \
    "$HERE/main.swift"

cat >"$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>UndoProbe</string>
    <key>CFBundleIdentifier</key><string>dev.kaya.undoprobe</string>
    <key>CFBundleName</key><string>UndoProbe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchScreen</key><dict/>
</dict>
</plist>
PLIST

xcrun simctl terminate "$UDID" dev.kaya.undoprobe >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" dev.kaya.undoprobe >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

echo "== running on $UDID =="
xcrun simctl launch --console-pty "$UDID" dev.kaya.undoprobe 2>&1 &
launch_pid=$!
# The probe holds for 12s at the shake so the screen can be captured:
# an alert is a thing ON SCREEN, and no in-process boolean proves that.
sleep 55
xcrun simctl io "$UDID" screenshot "$OUT/shake.png" >/dev/null 2>&1 \
    && echo "== screenshot at $OUT/shake.png =="
sleep 12
kill "$launch_pid" 2>/dev/null || true

xcrun simctl terminate "$UDID" dev.kaya.undoprobe >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" dev.kaya.undoprobe >/dev/null 2>&1 || true
echo "== uninstalled dev.kaya.undoprobe from $UDID =="
