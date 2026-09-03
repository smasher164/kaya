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

# Build and install DragProbe on a booted SIMULATOR — it does NOT launch
# it (tools/ios/dragprobe/drive.py does, beside the driver).
# Usage: tools/ios/dragprobe/build.sh <udid>
#
# NOT A LANE. The question is docs/dnd-plan.md §2 probe 5; main.swift's
# header carries the Q-labels the log lines use.
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
[ -n "$UDID" ] || {
    echo "build.sh: usage: build.sh <udid>" >&2
    exit 1
}

OUT="$ROOT/target/ios-dragprobe"
APP="$OUT/DragProbe.app"
rm -rf "$APP"
mkdir -p "$APP"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$APP/DragProbe" \
    "$HERE/main.swift"

# UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace put this app's
# Documents in the stock Files app, which is the FOREIGN drag source.
# UIDeviceFamily 2 is the whole point: cross-app drag needs an iPad.
# UTExportedTypeDeclarations declares dev.kaya/note so the MIME-shaped id
# has an owner on the device (docs/dnd-plan.md §2 probe 3 asks the mac
# twin of this question).
cat >"$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DragProbe</string>
    <key>CFBundleIdentifier</key><string>dev.kaya.dragprobe</string>
    <key>CFBundleName</key><string>DragProbe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIFileSharingEnabled</key><true/>
    <key>LSSupportsOpeningDocumentsInPlace</key><true/>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchScreen</key><dict/>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key><true/>
    </dict>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>dev.kaya/note</string>
            <key>UTTypeDescription</key><string>kaya note</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key><dict/>
        </dict>
    </array>
</dict>
</plist>
PLIST

xcrun simctl terminate "$UDID" dev.kaya.dragprobe >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" dev.kaya.dragprobe >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
echo "installed dev.kaya.dragprobe on $UDID"

# The FOREIGN source: a second bundle, therefore a second principal, whose
# drag registers kaya's own vocabulary (the stock Files app cannot).
SRCAPP="$OUT/NoteSource.app"
rm -rf "$SRCAPP"
mkdir -p "$SRCAPP"
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$SRCAPP/NoteSource" \
    "$HERE/notesource.swift"
cat >"$SRCAPP/Info.plist" <<'PLIST2'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>NoteSource</string>
    <key>CFBundleIdentifier</key><string>dev.kaya.notesource</string>
    <key>CFBundleName</key><string>NoteSource</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchScreen</key><dict/>
</dict>
</plist>
PLIST2
xcrun simctl terminate "$UDID" dev.kaya.notesource >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" dev.kaya.notesource >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$SRCAPP"
echo "installed dev.kaya.notesource on $UDID"
