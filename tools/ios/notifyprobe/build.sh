#!/usr/bin/env bash
# Builds tools/ios/notifyprobe as a minimal simulator .app and prints its path.
# In-toolchain launcher shape, so shell (CLAUDE.md). Driven by hand:
#   APP=$(tools/ios/notifyprobe/build.sh)
#   xcrun simctl install <udid> "$APP"
#   SIMCTL_CHILD_NOTIFYPROBE_PROVISIONAL=1 xcrun simctl launch --console-pty <udid> dev.kaya.notifyprobe
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/target/ios-notifyprobe"
APP="$OUT/NotifyProbe.app"
rm -rf "$APP"
mkdir -p "$APP"
# The dev shell's DEVELOPER_DIR/SDKROOT name a nix apple-sdk with no
# iphonesimulator SDK in it, so the toolchain is resolved the way
# swift-typecheck's ios_xcrun does (docs/HACKING.md, Hand tools).
# shellcheck source=../../lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc
ios_xcrun() {
    if [ -n "${SWIFT_DEVELOPER_DIR:-}" ]; then
        env -u SDKROOT DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR" /usr/bin/xcrun "$@"
    else
        env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcrun "$@"
    fi
}
ios_xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator \
    -framework UIKit -framework UserNotifications \
    -o "$APP/NotifyProbe" "$HERE/main.swift"
cat >"$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>NotifyProbe</string>
  <key>CFBundleIdentifier</key><string>${NOTIFYPROBE_ID:-dev.kaya.notifyprobe}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>NotifyProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>DTPlatformName</key><string>iphonesimulator</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict>
</plist>
PLIST
echo "$APP"
