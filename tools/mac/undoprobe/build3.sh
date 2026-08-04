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

# Round 3: ONE MODE PER INVOCATION, because rounds 1-2 ran the modes back
# to back and every difference tracked launch order (only the first
# launch became the active app). Usage:
#   tools/mac/undoprobe/build3.sh [nohook|hook]
# THROWAWAY, not a lane. See main3.swift's header.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1
[ -n "${SWIFT_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR"

MODE="${1:-nohook}"
OUT="$ROOT/target/mac-undoprobe3"
APP="$OUT/UndoProbe3.app"
mkdir -p "$APP/Contents/MacOS"

kaya_swiftc -O -o "$OUT/undoprobe3" "$HERE/main3.swift"
cp "$OUT/undoprobe3" "$APP/Contents/MacOS/UndoProbe3"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UndoProbe3</string>
  <key>CFBundleIdentifier</key><string>dev.kaya.undoprobe3</string>
  <key>CFBundleName</key><string>UndoProbe3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST

echo "=== mode=$MODE ==="
# `if !` and not an rc capture: set -e is on, so the failing command
# would take the script down before anything could read $?.
if ! KAYA_UNDOPROBE_MODE="$MODE" "$APP/Contents/MacOS/UndoProbe3"; then
    echo "UndoProbe3: exited nonzero in mode=$MODE"
fi
