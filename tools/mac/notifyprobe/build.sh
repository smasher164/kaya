#!/usr/bin/env bash
# Builds tools/mac/notifyprobe as a minimal .app (the shape the S3 lane wrapper
# takes: Info.plist with a CFBundleIdentifier, LSUIElement) and prints its
# executable path. In-toolchain launcher shape, so shell (CLAUDE.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"
OUT="$ROOT/target/notifyprobe"
APP="$OUT/NotifyProbe.app"
mkdir -p "$APP/Contents/MacOS"
kaya_swiftc -O -o "$OUT/notifyprobe" "$HERE/main.swift"
cp "$OUT/notifyprobe" "$APP/Contents/MacOS/NotifyProbe"
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>NotifyProbe</string>
  <key>CFBundleIdentifier</key><string>${NOTIFYPROBE_ID:-dev.kaya.notifyprobe}</string>
  <key>CFBundleName</key><string>NotifyProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP/Contents/MacOS/NotifyProbe"
