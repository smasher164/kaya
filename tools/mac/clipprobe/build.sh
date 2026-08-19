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

# Build and run ClipProbe TWICE — bare binary and .app bundle — and
# print both transcripts. A probe, not a lane: questions in main.swift,
# answers in docs/clipboard-plan.md.
#
# BOTH SHAPES ON PURPOSE (Q6): macOS's paste restriction is about which
# APP is reading, and a bare CLI binary has no bundle identity. Where
# they disagree, the bundled answer is the one that describes kaya.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# Inside the dev shell DEVELOPER_DIR/SDKROOT point at a nix apple-sdk
# where xcrun finds no swiftc; this steers back to a real Apple
# toolchain.
# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1
[ -n "${SWIFT_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR"

OUT="$ROOT/target/mac-clipprobe"
APP="$OUT/ClipProbe.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"

kaya_swiftc -O -o "$OUT/clipprobe" "$HERE/main.swift"
cp "$OUT/clipprobe" "$APP/Contents/MacOS/ClipProbe"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClipProbe</string>
  <key>CFBundleIdentifier</key><string>dev.kaya.clipprobe</string>
  <key>CFBundleName</key><string>ClipProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "=== bare binary (no bundle identity) ==="
# `if !` and not an rc capture: set -e would take the script down first.
if ! "$OUT/clipprobe"; then echo "clipprobe: refused to run"; fi

echo
echo "=== bundled app (dev.kaya.clipprobe) ==="
if ! "$APP/Contents/MacOS/ClipProbe"; then echo "ClipProbe: refused to run"; fi
