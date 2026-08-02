#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
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
# NOT A LANE. It answers what the harness can see of the iOS document
# picker before the arm is written — see main.swift's header for the
# questions, and docs/traps.md for what it found.
#
# The SIMULATOR is the right host here, unlike tools/ios/scopeprobe:
# these are UIKit questions, not sandbox ones, and the simulator runs
# the same UIKit. Anything whose answer depends on the sandbox DENYING
# something belongs in scopeprobe, on hardware.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# Inside the dev shell DEVELOPER_DIR/SDKROOT point at a nix apple-sdk
# where xcrun finds neither swiftc nor simctl. tools/lib/swift-toolchain.sh
# is the single source of truth for steering back to a real Apple
# toolchain — its own header records that this dance was copy-pasted with
# drift across three scripts before it existed, so this sources it rather
# than being the fourth.
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
    echo "build.sh: no booted kaya-sim-0; run tools/ios/run-sim.sh once" >&2
    exit 1
}

OUT="$ROOT/target/ios-clipprobe"
APP="$OUT/ClipProbe.app"
rm -rf "$APP"
mkdir -p "$APP"

# The iphonesimulator SDK, not the macOS one kaya_swiftc defaults to —
# so this borrows the resolved toolchain's swiftc and overrides -sdk.
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$APP/ClipProbe" \
    "$HERE/main.swift"

# UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace are the two
# keys that decide whether the app's own container is BROWSABLE from the
# picker at all — which is Q2, so the probe declares them and reports
# what it sees rather than assuming either way.
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

# SEEDED FROM OUTSIDE, which is the point: this is the only way the lane
# can put content on the simulator's clipboard, and whether iOS counts
# it as "another app" is Q2.
if [ "${KAYA_CLIPPROBE_MODE:-foreign}" = "own" ]; then
    echo "== mode=own: NOT seeding; the app writes its own content =="
else
    printf 'kaya-seeded-from-the-host' | xcrun simctl pbcopy "$UDID"
    echo "== seeded the clipboard with simctl pbcopy =="
fi

# Console output, not a log stream: the probe prints to stdout and
# simctl hands it back when launched with --console-pty.
echo "== running on $UDID =="
SIMCTL_CHILD_KAYA_CLIPPROBE_MODE="${KAYA_CLIPPROBE_MODE:-foreign}" \
    xcrun simctl launch --console-pty "$UDID" dev.kaya.clipprobe 2>&1 &
launch_pid=$!
sleep 14
# A prompt is a THING ON SCREEN, and the log alone cannot tell a denied
# read from an empty clipboard. Grab the screen so the answer is visible.
xcrun simctl io "$UDID" screenshot "$OUT/screen.png" >/dev/null 2>&1 \
    && echo "== screenshot at $OUT/screen.png =="
kill "$launch_pid" 2>/dev/null || true
xcrun simctl terminate "$UDID" dev.kaya.clipprobe >/dev/null 2>&1 || true
