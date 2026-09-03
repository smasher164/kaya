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

# Round 2 of the iOS undo probe: main2.swift (routing + gestures).
# Usage: tools/ios/undoprobe/build2.sh [udid]
#
# NOT A LANE, THROWAWAY. Questions in main2.swift's header; what it
# decides is docs/undo-plan.md §0.
#
# It UNINSTALLS itself at the end: the simulators are shared with the
# lane and a probe must leave no fixture behind.
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
    echo "build.sh: no kaya-sim-0; run tools/ios/run-sim.py once" >&2
    exit 1
}

OUT="$ROOT/target/ios-undoprobe2"
APP="$OUT/UndoProbe2.app"
rm -rf "$APP"
mkdir -p "$APP"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$APP/UndoProbe2" \
    "$HERE/main2.swift"

cat >"$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>UndoProbe2</string>
    <key>CFBundleIdentifier</key><string>dev.kaya.undoprobe2</string>
    <key>CFBundleName</key><string>UndoProbe2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchScreen</key><dict/>
</dict>
</plist>
PLIST

xcrun simctl terminate "$UDID" dev.kaya.undoprobe2 >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" dev.kaya.undoprobe2 >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

echo "== running on $UDID =="
xcrun simctl launch --console-pty "$UDID" dev.kaya.undoprobe2 2>&1 &
launch_pid=$!
# The probe holds 12s at the shake so the screen can be captured: an
# alert is a THING ON SCREEN, and no in-process boolean proves it.
sleep 45
xcrun simctl io "$UDID" screenshot "$OUT/shake2.png" >/dev/null 2>&1 \
    && echo "== screenshot at $OUT/shake.png =="
sleep 12
kill "$launch_pid" 2>/dev/null || true

# NO FIXTURE LEFT BEHIND. The simulators are shared with the lane.
xcrun simctl terminate "$UDID" dev.kaya.undoprobe2 >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" dev.kaya.undoprobe2 >/dev/null 2>&1 || true
echo "== uninstalled dev.kaya.undoprobe2 from $UDID =="
