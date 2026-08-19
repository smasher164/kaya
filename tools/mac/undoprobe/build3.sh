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

# ONE MODE PER INVOCATION: only the first launch of a run becomes the
# active app, so back-to-back modes differ by launch order.
#   tools/mac/undoprobe/build3.sh [nohook|hook]
# Throwaway probe, not a lane. See main3.swift's header.
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
# `if !` and not an rc capture: set -e would take the script down first.
if ! KAYA_UNDOPROBE_MODE="$MODE" "$APP/Contents/MacOS/UndoProbe3"; then
    echo "UndoProbe3: exited nonzero in mode=$MODE"
fi
