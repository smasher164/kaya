#!/usr/bin/env bash
# Builds the rich-text iOS probe as a minimal simulator .app and prints its path.
# The notifyprobe shape (tools/ios/notifyprobe/build.sh), outside the repo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT=/Users/akhilindurti/Projects/kaya
OUT="$HERE/build"
APP="$OUT/RichTextProbe.app"
rm -rf "$APP"
mkdir -p "$APP"
# shellcheck source=/dev/null
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
    -framework UIKit \
    -o "$APP/RichTextProbe" "$HERE/main.swift"
cat >"$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>RichTextProbe</string>
  <key>CFBundleIdentifier</key><string>dev.kaya.richtextprobe</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>RichTextProbe</string>
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
